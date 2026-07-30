import Foundation
import os.log

// MARK: - ClaudeCodeHooks

/// Installs and removes the Claude Code hooks that report session state to
/// WhichSpace.
///
/// Each hook pipes its stdin payload (which already carries `session_id`,
/// `cwd`, and `hook_event_name`) into `~/.whichspace/agents/<PPID>.json`
/// via a temp file + `mv`, so `AgentStatusStore` never reads a partial
/// write and needs no helper binary installed.
///
/// `settings.json` is edited as generic JSON: unrelated user configuration
/// round-trips untouched, WhichSpace's own entries are identified by their
/// command string, and the previous file is backed up beside the original
/// before every write.
enum ClaudeCodeHooks {
    private static let logger = Logger(subsystem: "io.gechr.WhichSpace", category: "ClaudeCodeHooks")

    /// The events WhichSpace consumes, mirrored by `AgentState(hookEventName:)`.
    static let hookEvents = [
        "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd",
    ]

    /// The shell command each hook runs. The `whichspace` marker in the
    /// target path doubles as the ownership marker for uninstall.
    static let hookCommand = #"""
    d="$HOME/.whichspace/agents"; mkdir -p "$d" && cat > "$d/$PPID.json.tmp" && mv "$d/$PPID.json.tmp" "$d/$PPID.json"
    """#

    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    enum InstallState: Equatable {
        case installed
        case notInstalled
        /// Some of the events are hooked, e.g. after a version change
        case partial
    }

    // MARK: - Inspection

    static func installState(settingsURL: URL = defaultSettingsURL) -> InstallState {
        let hooks = (try? readSettings(at: settingsURL))?["hooks"] as? [String: Any] ?? [:]
        let installedEvents = hookEvents.filter { event in
            matchers(inHooks: hooks, event: event).contains { containsOwnCommand($0) }
        }
        switch installedEvents.count {
        case 0:
            return .notInstalled
        case hookEvents.count:
            return .installed
        default:
            return .partial
        }
    }

    // MARK: - Install / Remove

    /// Adds WhichSpace's hook to every consumed event, leaving all other
    /// configuration untouched. Idempotent.
    static func install(settingsURL: URL = defaultSettingsURL) throws {
        var settings = try readSettings(at: settingsURL)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in hookEvents {
            var eventMatchers = matchers(inHooks: hooks, event: event)
            guard !eventMatchers.contains(where: { containsOwnCommand($0) }) else {
                continue
            }
            eventMatchers.append([
                "hooks": [["type": "command", "command": hookCommand]],
            ])
            hooks[event] = eventMatchers
        }

        settings["hooks"] = hooks
        try writeSettings(settings, to: settingsURL)
    }

    /// Removes every hook entry carrying WhichSpace's command. Matchers left
    /// empty by the removal are dropped; other hooks in the same matcher stay.
    static func remove(settingsURL: URL = defaultSettingsURL) throws {
        var settings = try readSettings(at: settingsURL)
        guard var hooks = settings["hooks"] as? [String: Any] else {
            return
        }

        for event in hooks.keys {
            let eventMatchers = matchers(inHooks: hooks, event: event)
            let cleaned = eventMatchers.compactMap { matcher -> [String: Any]? in
                var matcher = matcher
                let entries = (matcher["hooks"] as? [[String: Any]] ?? [])
                    .filter { !isOwnCommand($0) }
                guard !entries.isEmpty else {
                    return nil
                }
                matcher["hooks"] = entries
                return matcher
            }
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings, to: settingsURL)
    }

    // MARK: - JSON Plumbing

    private static func matchers(inHooks hooks: [String: Any], event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    private static func containsOwnCommand(_ matcher: [String: Any]) -> Bool {
        (matcher["hooks"] as? [[String: Any]] ?? []).contains { isOwnCommand($0) }
    }

    private static func isOwnCommand(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(".whichspace/agents") == true
    }

    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return [:]
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    /// Writes atomically after backing up the current file, so a failed
    /// write or an unwanted install is always recoverable.
    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: url.path) {
            let backup = url.deletingPathExtension().appendingPathExtension("json.whichspace-backup")
            _ = try? fileManager.removeItem(at: backup)
            try? fileManager.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
