import Cocoa
import os.log

// MARK: - SpaceProject

/// A project folder resolved onto a Space: which repo the editor window on
/// that Space has open, and its current git branch.
struct SpaceProject: Equatable {
    let spaceID: Int
    let path: URL
    let name: String
    let branch: String?
}

// MARK: - EditorWindowProvider

/// One editor window as discovered via Accessibility.
struct EditorWindow: Equatable {
    let pid: pid_t
    let title: String
    let windowID: UInt32
}

/// Abstracts editor-window discovery so tests inject fixed windows instead
/// of touching the AX API (mirrors `DisplaySpaceProvider`).
protocol EditorWindowProvider: Sendable {
    func editorWindows(bundleIDs: [String]) -> [EditorWindow]
}

// MARK: - AXEditorWindowProvider

/// Discovers editor windows through the Accessibility API. Returns nothing
/// when AX permission is missing - every consumer degrades to today's
/// behaviour in that case.
struct AXEditorWindowProvider: EditorWindowProvider {
    func editorWindows(bundleIDs: [String]) -> [EditorWindow] {
        guard AXIsProcessTrusted() else {
            return []
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let bundleID = $0.bundleIdentifier else {
                return false
            }
            return bundleIDs.contains(bundleID)
        }
        var windows: [EditorWindow] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement]
            else {
                continue
            }
            for axWindow in axWindows {
                var titleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    axWindow, kAXTitleAttribute as CFString, &titleValue
                ) == .success,
                    let title = titleValue as? String, !title.isEmpty
                else {
                    continue
                }
                var windowID: UInt32 = 0
                guard _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 else {
                    continue
                }
                windows.append(EditorWindow(pid: app.processIdentifier, title: title, windowID: windowID))
            }
        }
        return windows
    }
}

// MARK: - SpaceProjectIndex

/// Maintains the Space → project/branch mapping that drives auto-labels and
/// agent-status attribution.
///
/// Refresh pipeline (all reads, no side effects outside this class):
/// editor windows via AX → window Space via CGS → window title → project
/// folder via `ProjectResolver` → branch via `GitBranch`.
///
/// Triggers are coalesced through a short debounce: editor app lifecycle,
/// AX title changes are *not* individually observed - instead the callers
/// route Space snapshot changes here, `.git` directories of resolved
/// projects are watched for branch flips, and a backstop poll catches title
/// edits (file switches rename windows constantly, so per-title AX
/// observers would fire far more often than the poll).
@MainActor
@Observable
final class SpaceProjectIndex {
    private static let logger = Logger(subsystem: "io.gechr.WhichSpace", category: "SpaceProjectIndex")

    /// Debounce for burst triggers (Space switches, git directory writes).
    private static let refreshDebounce: Duration = .milliseconds(300)
    /// Backstop poll for changes with no push signal (window title edits).
    private static let pollInterval: Duration = .seconds(15)

    /// Resolved projects keyed by CGS Space ID.
    private(set) var projects: [Int: SpaceProject] = [:]

    /// Called after `projects` changes, so the status bar can re-render.
    @ObservationIgnored var onProjectsChanged: (() -> Void)?

    @ObservationIgnored private let displaySpaceProvider: DisplaySpaceProvider
    @ObservationIgnored private let editorWindowProvider: EditorWindowProvider
    @ObservationIgnored private let store: DefaultsStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var branchWatchTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false

    init(
        displaySpaceProvider: DisplaySpaceProvider,
        editorWindowProvider: EditorWindowProvider = AXEditorWindowProvider(),
        store: DefaultsStore
    ) {
        self.displaySpaceProvider = displaySpaceProvider
        self.editorWindowProvider = editorWindowProvider
        self.store = store
    }

    deinit {
        MainActor.assumeIsolated {
            refreshTask?.cancel()
            pollTask?.cancel()
            for task in branchWatchTasks.values {
                task.cancel()
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts the backstop poll and performs the initial resolution. Idempotent;
    /// a no-op until a feature that needs the index is enabled.
    func start() {
        guard !started else {
            return
        }
        started = true
        scheduleRefresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
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
        pollTask?.cancel()
        pollTask = nil
        for task in branchWatchTasks.values {
            task.cancel()
        }
        branchWatchTasks = [:]
        if !projects.isEmpty {
            projects = [:]
            onProjectsChanged?()
        }
    }

    /// Requests a refresh, coalescing bursts. Safe to call from any trigger.
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
            await self?.refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        let editorWindowProvider = editorWindowProvider
        let displaySpaceProvider = displaySpaceProvider
        let bundleIDs = store.editorBundleIDs
        let projectRoots = store.projectRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let previous = projects

        // The AX walk, CGS queries, and disk reads all happen off the main
        // actor; only the final dictionary swap comes back
        let resolved = await Task.detached(priority: .utility) { () -> [Int: SpaceProject] in
            // Topology: which Spaces still exist, and which are visible
            // (the active Space of each display)
            var allSpaceIDs = Set<Int>()
            var visibleSpaceIDs = Set<Int>()
            for display in displaySpaceProvider.copyManagedDisplaySpaces() ?? [] {
                for space in display["Spaces"] as? [[String: Any]] ?? [] {
                    if let spaceID = space["ManagedSpaceID"] as? Int {
                        allSpaceIDs.insert(spaceID)
                    }
                }
                if let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int {
                    visibleSpaceIDs.insert(current)
                }
            }

            let windows = editorWindowProvider.editorWindows(bundleIDs: bundleIDs)
            let spacesByWindow = windows.isEmpty
                ? [:]
                : displaySpaceProvider.spaces(forWindowIDs: windows.map(\.windowID))
            let knownProjects = ProjectResolver.knownProjects(projectRoots: projectRoots)

            var fresh: [Int: SpaceProject] = [:]
            for window in windows {
                guard let spaceID = spacesByWindow[window.windowID],
                      let folder = ProjectResolver.project(forTitle: window.title, in: knownProjects),
                      // First window wins: front-most editor per Space
                      fresh[spaceID] == nil
                else {
                    continue
                }
                fresh[spaceID] = SpaceProject(
                    spaceID: spaceID,
                    path: folder,
                    name: folder.lastPathComponent,
                    branch: GitBranch.branch(forRepository: folder)
                )
            }
            return Self.merge(
                previous: previous,
                fresh: fresh,
                allSpaceIDs: allSpaceIDs,
                visibleSpaceIDs: visibleSpaceIDs
            )
        }.value

        guard started else {
            return
        }
        syncBranchWatchers(with: resolved)
        if resolved != projects {
            projects = resolved
            onProjectsChanged?()
        }
    }

    /// Folds one resolution pass into the previous mapping.
    ///
    /// The Accessibility API only reports windows on the currently visible
    /// Spaces, so a pass never sees the whole picture - replacing the map
    /// outright would forget every background Space the moment the user
    /// switches away (and with it the agent dots those Spaces exist to show).
    /// Instead, background entries persist until there is positive evidence
    /// they are gone:
    /// - the Space itself closed (not in `allSpaceIDs`)
    /// - the Space is visible, so AX *can* see its windows, and no project
    ///   resolved on it
    /// - the project resolved onto a different Space (the window moved)
    ///
    /// Retained entries re-read their branch so a background `git switch`
    /// still updates the label.
    nonisolated static func merge(
        previous: [Int: SpaceProject],
        fresh: [Int: SpaceProject],
        allSpaceIDs: Set<Int>,
        visibleSpaceIDs: Set<Int>,
        branchReader: (URL) -> String? = { GitBranch.branch(forRepository: $0) }
    ) -> [Int: SpaceProject] {
        let freshPaths = Set(fresh.values.map(\.path))
        var merged: [Int: SpaceProject] = [:]
        for (spaceID, project) in previous {
            guard allSpaceIDs.contains(spaceID),
                  !visibleSpaceIDs.contains(spaceID),
                  !freshPaths.contains(project.path)
            else {
                continue
            }
            merged[spaceID] = SpaceProject(
                spaceID: project.spaceID,
                path: project.path,
                name: project.name,
                branch: branchReader(project.path)
            )
        }
        for (spaceID, project) in fresh {
            merged[spaceID] = project
        }
        return merged
    }

    /// Keeps one git-directory watcher alive per resolved project, so a
    /// branch switch re-resolves within the debounce rather than the poll.
    private func syncBranchWatchers(with resolved: [Int: SpaceProject]) {
        let wantedRoots = Set(resolved.values.map(\.path))
        for (root, task) in branchWatchTasks where !wantedRoots.contains(root) {
            task.cancel()
            branchWatchTasks.removeValue(forKey: root)
        }
        for root in wantedRoots where branchWatchTasks[root] == nil {
            guard let gitDirectory = GitBranch.gitDirectory(forRepository: root) else {
                continue
            }
            branchWatchTasks[root] = Task { [weak self] in
                let watcher = GitBranchWatcher(gitDirectory: gitDirectory)
                let changes = await watcher.changes()
                for await _ in changes {
                    self?.scheduleRefresh()
                }
            }
        }
    }
}
