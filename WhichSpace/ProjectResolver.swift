import Foundation

// MARK: - ProjectResolver

/// Resolves editor window titles to project folders on disk.
///
/// VSCode-family titles look like `"● file.swift — grc-cloud-2"` (optionally
/// with more " — "-separated segments such as the app name or profile). The
/// resolver splits out the candidate segments and matches them against an
/// index of known project names built from the editors' own state files plus
/// user-configured project roots, so no editor configuration is required.
///
/// Pure logic apart from the two state-file reads; every input is injectable
/// for tests.
enum ProjectResolver {
    /// The em-dash separator VSCode-family editors use in window titles.
    private static let titleSeparator = " — "
    /// The unsaved-changes marker prefixed to titles.
    private static let dirtyMarker = "●"

    // MARK: - Title Parsing

    /// The candidate project-name segments of a window title, cleaned of the
    /// dirty marker, in trailing-first order (the folder name conventionally
    /// follows the file name).
    static func titleSegments(_ title: String) -> [String] {
        title
            .components(separatedBy: titleSeparator)
            .map { segment in
                segment
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: dirtyMarker))
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .reversed()
    }

    /// Resolves a window title to a project folder using an index of known
    /// project names. Later segments win ("file.swift — grc-cloud-2 — Code"
    /// matches `grc-cloud-2`, not a project that happens to be called
    /// `file.swift`).
    static func project(forTitle title: String, in knownProjects: [String: URL]) -> URL? {
        for segment in titleSegments(title) {
            if let url = knownProjects[segment] {
                return url
            }
        }
        return nil
    }

    // MARK: - Known Project Index

    /// Builds the name → folder index the title matcher works against.
    ///
    /// Sources, later entries losing to earlier ones on name collisions:
    /// 1. VSCode-family window state (`storage.json`), which lists the folder
    ///    of every open window - authoritative for anything currently open.
    /// 2. User-configured project roots, scanned one level deep for
    ///    directories containing `.git`.
    static func knownProjects(
        stateFiles: [URL] = defaultStateFiles,
        projectRoots: [URL] = []
    ) -> [String: URL] {
        var index: [String: URL] = [:]

        for root in projectRoots {
            for folder in gitFolders(under: root) {
                index[folder.lastPathComponent] = folder
            }
        }

        // Editor state wins: it names the folders actually open right now
        for stateFile in stateFiles {
            for folder in openedFolders(inStateFile: stateFile) {
                index[folder.lastPathComponent] = folder
            }
        }

        return index
    }

    /// The window-state files of the supported VSCode-family editors.
    static var defaultStateFiles: [URL] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return ["Code", "Code - Insiders", "Cursor", "VSCodium"].map {
            appSupport.appendingPathComponent("\($0)/User/globalStorage/storage.json")
        }
    }

    /// Folder URLs of all windows recorded in a VSCode `storage.json`.
    static func openedFolders(inStateFile url: URL) -> [URL] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windowsState = root["windowsState"] as? [String: Any]
        else {
            return []
        }

        var windows = windowsState["openedWindows"] as? [[String: Any]] ?? []
        if let lastActive = windowsState["lastActiveWindow"] as? [String: Any] {
            windows.append(lastActive)
        }

        return windows.compactMap { window in
            guard let folder = window["folder"] as? String,
                  let folderURL = URL(string: folder),
                  folderURL.isFileURL
            else {
                return nil
            }
            return URL(fileURLWithPath: folderURL.path)
        }
    }

    /// Immediate subdirectories of `root` that contain a `.git` entry,
    /// including `root` itself when it is a repository.
    static func gitFolders(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        var folders: [URL] = []
        if fileManager.fileExists(atPath: root.appendingPathComponent(".git").path) {
            folders.append(root)
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  fileManager.fileExists(atPath: child.appendingPathComponent(".git").path)
            else {
                continue
            }
            folders.append(child)
        }
        return folders
    }

    // MARK: - Repo Root

    /// Walks up from `path` to the nearest directory containing `.git`, so an
    /// agent session's working directory (often a subfolder) attributes to
    /// the same project as the editor window above it.
    static func repoRoot(for path: URL) -> URL? {
        var current = path.standardizedFileURL
        let fileManager = FileManager.default
        while current.pathComponents.count > 1 {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }
}
