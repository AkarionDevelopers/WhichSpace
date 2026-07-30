import Foundation
import Testing
@testable import WhichSpace

struct ProjectResolverTests {
    private let known: [String: URL] = [
        "grc-cloud": URL(fileURLWithPath: "/p/grc-cloud"),
        "grc-cloud-2": URL(fileURLWithPath: "/p/grc-cloud-2"),
    ]

    // MARK: - Title Parsing

    @Test("matches the folder segment of a typical title")
    func matchesFolderSegment() {
        let url = ProjectResolver.project(forTitle: "main.ts — grc-cloud-2", in: known)
        #expect(url?.path == "/p/grc-cloud-2")
    }

    @Test("strips the dirty marker")
    func stripsDirtyMarker() {
        let url = ProjectResolver.project(forTitle: "● main.ts — grc-cloud", in: known)
        #expect(url?.path == "/p/grc-cloud")
    }

    @Test("trailing segments win over earlier ones")
    func trailingSegmentsWin() {
        // A file that happens to share a project's name must not shadow the
        // window's actual folder
        let shadowing = known.merging(["main.ts": URL(fileURLWithPath: "/p/decoy")]) { a, _ in a }
        let url = ProjectResolver.project(forTitle: "main.ts — grc-cloud-2", in: shadowing)
        #expect(url?.path == "/p/grc-cloud-2")
    }

    @Test("titles with extra segments still match")
    func extraSegmentsStillMatch() {
        let url = ProjectResolver.project(
            forTitle: "● index.vue — grc-cloud-2 — Visual Studio Code", in: known
        )
        #expect(url?.path == "/p/grc-cloud-2")
    }

    @Test("a title matching nothing yields nil")
    func unknownTitleYieldsNil() {
        #expect(ProjectResolver.project(forTitle: "Untitled", in: known) == nil)
        #expect(ProjectResolver.project(forTitle: "", in: known) == nil)
    }

    @Test("a folder-only title matches")
    func folderOnlyTitleMatches() {
        let url = ProjectResolver.project(forTitle: "grc-cloud", in: known)
        #expect(url?.path == "/p/grc-cloud")
    }

    // MARK: - State File Parsing

    @Test("reads opened folders from a VSCode storage.json")
    func readsOpenedFolders() throws {
        let stateFile = try writeTemp(json: [
            "windowsState": [
                "lastActiveWindow": ["folder": "file:///Users/x/Projects/alpha"],
                "openedWindows": [
                    ["folder": "file:///Users/x/Projects/beta"],
                    ["backupPath": "/nofolder"],
                ],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: stateFile) }

        let folders = ProjectResolver.openedFolders(inStateFile: stateFile)

        #expect(Set(folders.map(\.path)) == ["/Users/x/Projects/alpha", "/Users/x/Projects/beta"])
    }

    @Test("a missing or malformed state file yields nothing")
    func missingStateFileYieldsNothing() {
        let missing = URL(fileURLWithPath: "/nonexistent/storage.json")
        #expect(ProjectResolver.openedFolders(inStateFile: missing).isEmpty)
    }

    // MARK: - Known Project Index

    @Test("editor state wins over project roots on name collision")
    func editorStateWinsCollisions() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A local repo folder named "alpha"
        let localAlpha = root.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(
            at: localAlpha.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        // Editor state points "alpha" somewhere else
        let stateFile = try writeTemp(json: [
            "windowsState": [
                "openedWindows": [["folder": "file:///elsewhere/alpha"]],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: stateFile) }

        let index = ProjectResolver.knownProjects(stateFiles: [stateFile], projectRoots: [root])

        #expect(index["alpha"]?.path == "/elsewhere/alpha")
    }

    @Test("scans project roots one level deep for repositories")
    func scansProjectRoots() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        // A plain folder without .git must not be indexed
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-repo"), withIntermediateDirectories: true
        )

        let index = ProjectResolver.knownProjects(stateFiles: [], projectRoots: [root])

        // contentsOfDirectory canonicalizes /var to /private/var; compare resolved
        #expect(index["repo"]?.resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path)
        #expect(index["not-a-repo"] == nil)
    }

    // MARK: - Repo Root

    @Test("walks up from a subdirectory to the repository root")
    func walksUpToRepoRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        let nested = root.appendingPathComponent("src/deep/dir")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(ProjectResolver.repoRoot(for: nested)?.path == root.path)
    }

    @Test("a path outside any repository yields nil")
    func outsideRepositoryYieldsNil() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ProjectResolver.repoRoot(for: root) == nil)
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // /var is a symlink to /private/var; resolve so path comparisons match
        return url.resolvingSymlinksInPath()
    }

    private func writeTemp(json object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectResolverTests-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
        return url
    }
}
