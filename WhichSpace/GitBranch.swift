import Foundation
import os.log

// MARK: - GitBranch

/// Reads the checked-out branch of a repository from `.git/HEAD` directly -
/// no `git` invocation, so reads are cheap enough to run on every refresh.
enum GitBranch {
    private static let logger = Logger(subsystem: "io.gechr.WhichSpace", category: "GitBranch")

    /// The directory holding a repository's `HEAD`, resolving the two shapes
    /// `.git` takes: a directory (regular checkout) or a `gitdir: <path>`
    /// pointer file (worktrees and submodules). Relative pointer paths are
    /// anchored at the repository root.
    static func gitDirectory(forRepository root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return dotGit
        }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let pointer = parseGitDirPointer(contents)
        else {
            return nil
        }
        let resolved = pointer.hasPrefix("/")
            ? URL(fileURLWithPath: pointer)
            : root.appendingPathComponent(pointer)
        return resolved.standardizedFileURL
    }

    /// The current branch name, or a 7-character short SHA when HEAD is
    /// detached, or nil when the repository state is unreadable.
    static func branch(forRepository root: URL) -> String? {
        guard let gitDirectory = gitDirectory(forRepository: root),
              let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
        else {
            return nil
        }
        return parseHead(head)
    }

    // MARK: - Parsing

    /// Parses `HEAD` content: `ref: refs/heads/X` yields the branch name,
    /// a bare commit hash yields its short form, anything else nil.
    static func parseHead(_ contents: String) -> String? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        if trimmed.hasPrefix(refPrefix) {
            let branch = String(trimmed.dropFirst(refPrefix.count))
            return branch.isEmpty ? nil : branch
        }
        // Detached HEAD: a 40-hex (SHA-1) or 64-hex (SHA-256) commit ID
        if [40, 64].contains(trimmed.count), trimmed.allSatisfy(\.isHexDigit) {
            return String(trimmed.prefix(7))
        }
        return nil
    }

    /// Extracts the target path from a `.git` pointer file's contents.
    static func parseGitDirPointer(_ contents: String) -> String? {
        let prefix = "gitdir:"
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            return nil
        }
        let path = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }
}

// MARK: - GitBranchWatcher

/// Watches a repository's git directory and ticks when HEAD may have
/// changed. The directory (not the HEAD file) is watched because git
/// replaces HEAD atomically, which a file-level watch reads as a one-shot
/// delete; directory-level write events survive any number of replacements.
/// Follows `SpaceMonitor`'s reopen-retry discipline for the same reason -
/// the watched node can briefly not exist mid-operation.
actor GitBranchWatcher {
    private static let logger = Logger(subsystem: "io.gechr.WhichSpace", category: "GitBranchWatcher")

    private let gitDirectory: URL
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var continuation: AsyncStream<Void>.Continuation?
    private var retryTask: Task<Void, Never>?

    init(gitDirectory: URL) {
        self.gitDirectory = gitDirectory
    }

    /// Creates an async stream that ticks on every git-directory change.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        setContinuation(continuation)
        return stream
    }

    private func setContinuation(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
        startMonitoring()

        continuation.onTermination = { @Sendable _ in
            Task {
                await self.handleTermination()
            }
        }
    }

    private func handleTermination() {
        continuation = nil
        stopMonitoring()
    }

    private func restartMonitoring() {
        stopMonitoring()
        startMonitoring(emitAfterOpening: true)
    }

    private func startMonitoring(retryAttempt: Int = 0, emitAfterOpening: Bool = false) {
        guard let cPath = gitDirectory.path.cString(using: .utf8) else {
            Self.logger.error("Failed to get C string path for: \(self.gitDirectory.path)")
            return
        }

        let fildes = open(cPath, O_EVTONLY)
        if fildes == -1 {
            guard continuation != nil else {
                return
            }
            let retryDelay = SpaceMonitor.retryDelay(forAttempt: retryAttempt)
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: retryDelay)
                guard !Task.isCancelled else {
                    return
                }
                await self?.retryMonitoring(
                    retryAttempt: min(retryAttempt + 1, 5),
                    emitAfterOpening: emitAfterOpening
                )
            }
            return
        }
        retryTask = nil

        let queue = DispatchQueue.global(qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fildes,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            let flags = source.data
            guard let self else {
                return
            }
            Task { [self] in
                if flags.contains(.delete) || flags.contains(.rename) {
                    // The directory node itself went away (e.g. re-clone);
                    // reopen and emit so consumers re-read the new state
                    await restartMonitoring()
                } else {
                    await emit()
                }
            }
        }

        source.setCancelHandler {
            close(fildes)
        }

        source.resume()
        fileMonitor = source
        if emitAfterOpening {
            continuation?.yield()
        }
    }

    private func emit() {
        continuation?.yield()
    }

    private func retryMonitoring(retryAttempt: Int, emitAfterOpening: Bool) {
        guard continuation != nil, fileMonitor == nil else {
            return
        }
        retryTask = nil
        startMonitoring(retryAttempt: retryAttempt, emitAfterOpening: emitAfterOpening)
    }

    private func stopMonitoring() {
        retryTask?.cancel()
        retryTask = nil
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    deinit {
        retryTask?.cancel()
        fileMonitor?.cancel()
    }
}
