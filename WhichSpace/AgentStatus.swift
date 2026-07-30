import AppKit
import Defaults
import os.log

// MARK: - AgentState

/// The lifecycle state of a coding-agent session, as reported by its hooks.
enum AgentState: String, Comparable {
    /// The agent is executing (prompt submitted or tool running)
    case working
    /// The agent is blocked on the user (permission prompt or idle wait)
    case waiting
    /// The agent finished responding
    case done

    /// Urgency order for aggregating several sessions on one Space:
    /// waiting > working > done.
    private var urgency: Int {
        switch self {
        case .waiting: 2
        case .working: 1
        case .done: 0
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.urgency < rhs.urgency
    }

    /// Maps a hook event name to the state it implies, or nil for events
    /// that carry no state change (e.g. `SessionStart`).
    /// `SessionEnd` maps to nil too - the session file is pruned instead.
    init?(hookEventName: String) {
        switch hookEventName {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            self = .working
        case "Notification", "PermissionRequest":
            self = .waiting
        case "Stop", "SubagentStop":
            self = .done
        default:
            return nil
        }
    }

    /// The indicator dot color. Chosen to read at 5pt: blue = running,
    /// orange = needs you, green = finished.
    var indicatorColor: NSColor {
        switch self {
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .done: .systemGreen
        }
    }
}

// MARK: - AgentIndicatorStyle

/// How agent session state is rendered in the status bar. String-backed so
/// richer styles (e.g. tinting the whole icon) can be added without a key
/// migration; an absent key resolves to `.dot`.
enum AgentIndicatorStyle: String, CaseIterable, Defaults.Serializable {
    /// No indicator
    case off
    /// A small colored dot on the Space icon
    case dot
}

// MARK: - AgentSession

/// One agent session as decoded from a status file. The file is the raw
/// stdin payload Claude Code passes to its hooks, so field names follow the
/// hook contract (`session_id`, `cwd`, `hook_event_name`).
struct AgentSession: Equatable {
    let sessionID: String
    let cwd: URL
    let state: AgentState
    /// The hook writer's shell PID (from the file name), used for liveness
    let pid: pid_t?
    let updatedAt: Date

    /// What a status file's JSON turned out to contain.
    enum FileContent: Equatable {
        /// A live session in a known state
        case session(AgentSession)
        /// The session reported its own end - the file can be deleted
        case ended
        /// Malformed, partial, or an event with no state meaning - leave the
        /// file for the next tick
        case undecodable
    }

    /// Decodes a status file tolerantly. The payload is the raw stdin JSON
    /// Claude Code passes to its hooks.
    static func parse(statusFileData data: Data, pid: pid_t?, updatedAt: Date) -> FileContent {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = payload["session_id"] as? String,
              let cwdPath = payload["cwd"] as? String,
              let eventName = payload["hook_event_name"] as? String
        else {
            return .undecodable
        }
        if eventName == "SessionEnd" {
            return .ended
        }
        guard let state = AgentState(hookEventName: eventName) else {
            return .undecodable
        }
        return .session(AgentSession(
            sessionID: sessionID,
            cwd: URL(fileURLWithPath: cwdPath),
            state: state,
            pid: pid,
            updatedAt: updatedAt
        ))
    }
}

// MARK: - AgentStatusStore

/// Watches the agent status directory (`~/.whichspace/agents`) written by
/// Claude Code hooks and aggregates the sessions into a per-Space state via
/// the project index.
///
/// A hook only reports transitions, so a session that dies mid-flight would
/// stay `working` forever - pruning covers that: sessions whose writing
/// shell is gone, plus a staleness cutoff as a backstop for PID reuse.
@MainActor
@Observable
final class AgentStatusStore {
    private static let logger = Logger(subsystem: "io.gechr.WhichSpace", category: "AgentStatusStore")

    /// Debounce for hook write bursts (every tool call writes a file).
    private static let refreshDebounce: Duration = .milliseconds(200)
    /// A `working` session untouched this long is presumed dead.
    static let staleWorkingCutoff: TimeInterval = 15 * 60
    /// A `done`/`waiting` session untouched this long is pruned from disk.
    static let staleFileCutoff: TimeInterval = 24 * 60 * 60

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".whichspace/agents", isDirectory: true)
    }

    /// The aggregated state per CGS Space ID.
    private(set) var statesBySpace: [Int: AgentState] = [:]

    /// Called after `statesBySpace` changes, so the status bar re-renders.
    @ObservationIgnored var onStatesChanged: (() -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let projectIndex: SpaceProjectIndex
    @ObservationIgnored private let isProcessAlive: (pid_t) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(
        directory: URL = AgentStatusStore.defaultDirectory,
        projectIndex: SpaceProjectIndex,
        isProcessAlive: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.projectIndex = projectIndex
        self.isProcessAlive = isProcessAlive
        self.now = now
    }

    deinit {
        MainActor.assumeIsolated {
            refreshTask?.cancel()
            watchTask?.cancel()
        }
    }

    // MARK: - Lifecycle

    /// Creates the status directory (hooks write into it blindly) and starts
    /// watching it. Idempotent.
    func start() {
        guard !started else {
            return
        }
        started = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scheduleRefresh()
        let directory = directory
        watchTask = Task { [weak self] in
            let watcher = GitBranchWatcher(gitDirectory: directory)
            let changes = await watcher.changes()
            for await _ in changes {
                self?.scheduleRefresh()
            }
        }
    }

    func stop() {
        guard started else {
            return
        }
        started = false
        refreshTask?.cancel()
        refreshTask = nil
        watchTask?.cancel()
        watchTask = nil
        if !statesBySpace.isEmpty {
            statesBySpace = [:]
            onStatesChanged?()
        }
    }

    func scheduleRefresh() {
        guard started else {
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDebounce)
            guard !Task.isCancelled else {
                return
            }
            self?.refresh()
        }
    }

    // MARK: - Refresh

    /// Re-reads every status file, prunes dead sessions, and aggregates the
    /// survivors onto Spaces through the project index.
    func refresh() {
        let sessions = loadSessions()
        let aggregated = Self.aggregate(
            sessions: sessions,
            projectsBySpace: projectIndex.projects
        )
        if aggregated != statesBySpace {
            statesBySpace = aggregated
            onStatesChanged?()
        }
    }

    /// Reads and prunes the status directory. Files that fail to decode are
    /// left alone (they may be mid-write); dead or stale sessions are removed
    /// so the directory cannot grow without bound.
    private func loadSessions() -> [AgentSession] {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var sessions: [String: AgentSession] = [:]
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now()
            let pid = pid_t(file.deletingPathExtension().lastPathComponent)
            let data = (try? Data(contentsOf: file)) ?? Data()

            switch AgentSession.parse(statusFileData: data, pid: pid, updatedAt: modified) {
            case .ended:
                try? fileManager.removeItem(at: file)
            case .undecodable:
                // Undecodable and old means abandoned, not mid-write
                if now().timeIntervalSince(modified) > Self.staleFileCutoff {
                    try? fileManager.removeItem(at: file)
                }
            case let .session(session):
                if isSessionDead(session) {
                    try? fileManager.removeItem(at: file)
                    continue
                }
                // The same session can appear under several PPIDs (shell
                // restarts); the newest write wins
                if let existing = sessions[session.sessionID], existing.updatedAt > session.updatedAt {
                    continue
                }
                sessions[session.sessionID] = session
            }
        }
        return Array(sessions.values)
    }

    private func isSessionDead(_ session: AgentSession) -> Bool {
        let age = now().timeIntervalSince(session.updatedAt)
        if session.state == .working, age > Self.staleWorkingCutoff {
            return true
        }
        if age > Self.staleFileCutoff {
            return true
        }
        if let pid = session.pid, !isProcessAlive(pid) {
            return true
        }
        return false
    }

    // MARK: - Aggregation

    /// Attributes each session to the Space whose project contains its
    /// working directory, keeping the most urgent state per Space. Nonisolated
    /// and injected-input only, so tests can drive it directly.
    nonisolated static func aggregate(
        sessions: [AgentSession],
        projectsBySpace: [Int: SpaceProject]
    ) -> [Int: AgentState] {
        guard !sessions.isEmpty, !projectsBySpace.isEmpty else {
            return [:]
        }
        var states: [Int: AgentState] = [:]
        for session in sessions {
            let sessionPath = session.cwd.standardizedFileURL.path
            for (spaceID, project) in projectsBySpace {
                let projectPath = project.path.standardizedFileURL.path
                guard sessionPath == projectPath
                    || sessionPath.hasPrefix(projectPath + "/")
                else {
                    continue
                }
                if let existing = states[spaceID], existing >= session.state {
                    continue
                }
                states[spaceID] = session.state
            }
        }
        return states
    }
}
