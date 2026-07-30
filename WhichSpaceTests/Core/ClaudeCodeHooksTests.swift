import Foundation
import Testing
@testable import WhichSpace

struct ClaudeCodeHooksTests {
    // MARK: - Helpers

    private func makeSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeHooksTests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Install

    @Test("install creates hooks for every consumed event")
    func installCreatesHooks() throws {
        let url = makeSettingsURL()
        defer { cleanup(url) }

        try ClaudeCodeHooks.install(settingsURL: url)

        let hooks = try read(url)["hooks"] as? [String: Any] ?? [:]
        #expect(Set(hooks.keys) == Set(ClaudeCodeHooks.hookEvents))
        #expect(ClaudeCodeHooks.installState(settingsURL: url) == .installed)
    }

    @Test("install preserves unrelated configuration")
    func installPreservesUnrelatedConfig() throws {
        let url = makeSettingsURL()
        defer { cleanup(url) }
        try write([
            "model": "opus",
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "echo hi"]]],
                ],
            ],
        ], to: url)

        try ClaudeCodeHooks.install(settingsURL: url)

        let settings = try read(url)
        #expect(settings["model"] as? String == "opus")
        #expect((settings["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls:*)"])
        // The pre-existing PreToolUse hook survives beside the new one
        let preToolUse = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        #expect(preToolUse.count == 2)
        let commands = preToolUse
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("echo hi"))
    }

    @Test("install is idempotent")
    func installIsIdempotent() throws {
        let url = makeSettingsURL()
        defer { cleanup(url) }

        try ClaudeCodeHooks.install(settingsURL: url)
        let first = try read(url)
        try ClaudeCodeHooks.install(settingsURL: url)
        let second = try read(url)

        #expect(NSDictionary(dictionary: first) == NSDictionary(dictionary: second))
    }

    // MARK: - Remove

    @Test("remove restores a previously clean file shape")
    func removeIsClean() throws {
        let url = makeSettingsURL()
        defer { cleanup(url) }
        try write(["model": "opus"], to: url)

        try ClaudeCodeHooks.install(settingsURL: url)
        try ClaudeCodeHooks.remove(settingsURL: url)

        let settings = try read(url)
        #expect(settings["hooks"] == nil)
        #expect(settings["model"] as? String == "opus")
        #expect(ClaudeCodeHooks.installState(settingsURL: url) == .notInstalled)
    }

    @Test("remove keeps foreign hooks in shared events")
    func removeKeepsForeignHooks() throws {
        let url = makeSettingsURL()
        defer { cleanup(url) }
        try write([
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "say done"]]],
                ],
            ],
        ], to: url)

        try ClaudeCodeHooks.install(settingsURL: url)
        try ClaudeCodeHooks.remove(settingsURL: url)

        let hooks = try read(url)["hooks"] as? [String: Any] ?? [:]
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        let commands = stop
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands == ["say done"])
    }

    // MARK: - Inspection

    @Test("a missing file reads as not installed")
    func missingFileNotInstalled() {
        let url = makeSettingsURL()
        #expect(ClaudeCodeHooks.installState(settingsURL: url) == .notInstalled)
    }

    @Test("a subset of events reads as partial")
    func subsetIsPartial() throws {
        let url = makeSettingsURL()
        defer { cleanup(url) }
        try write([
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": ClaudeCodeHooks.hookCommand]]],
                ],
            ],
        ], to: url)

        #expect(ClaudeCodeHooks.installState(settingsURL: url) == .partial)
    }

    @Test("install writes a backup beside the original")
    func installWritesBackup() throws {
        let url = makeSettingsURL()
        defer { cleanup(url) }
        try write(["model": "opus"], to: url)

        try ClaudeCodeHooks.install(settingsURL: url)

        let backup = url.deletingPathExtension().appendingPathExtension("json.whichspace-backup")
        let backedUp = try read(backup)
        #expect(backedUp["model"] as? String == "opus")
        #expect(backedUp["hooks"] == nil)
    }
}
