import Foundation
import Testing
@testable import WhichSpace

struct GitBranchTests {
    // MARK: - HEAD Parsing

    @Test("parses a branch ref")
    func parsesBranchRef() {
        #expect(GitBranch.parseHead("ref: refs/heads/main\n") == "main")
    }

    @Test("parses a nested branch ref")
    func parsesNestedBranchRef() {
        #expect(GitBranch.parseHead("ref: refs/heads/task/DEV-8585/bu\n") == "task/DEV-8585/bu")
    }

    @Test("detached HEAD becomes a short SHA")
    func parsesDetachedHead() {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        #expect(GitBranch.parseHead(sha + "\n") == "0123456")
    }

    @Test("SHA-256 detached HEAD becomes a short SHA")
    func parsesSHA256DetachedHead() {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        #expect(GitBranch.parseHead(sha) == "0123456")
    }

    @Test("garbage HEAD yields nil")
    func rejectsGarbage() {
        #expect(GitBranch.parseHead("not a head file") == nil)
        #expect(GitBranch.parseHead("") == nil)
        #expect(GitBranch.parseHead("ref: refs/heads/") == nil)
        // Right shape, wrong ref namespace
        #expect(GitBranch.parseHead("ref: refs/tags/v1.0") == nil)
    }

    // MARK: - gitdir Pointer Parsing

    @Test("parses a worktree pointer file")
    func parsesGitDirPointer() {
        let contents = "gitdir: /repos/main/.git/worktrees/feature\n"
        #expect(GitBranch.parseGitDirPointer(contents) == "/repos/main/.git/worktrees/feature")
    }

    @Test("parses a relative pointer")
    func parsesRelativePointer() {
        #expect(GitBranch.parseGitDirPointer("gitdir: ../.git/modules/sub") == "../.git/modules/sub")
    }

    @Test("non-pointer content yields nil")
    func rejectsNonPointer() {
        #expect(GitBranch.parseGitDirPointer("random") == nil)
        #expect(GitBranch.parseGitDirPointer("gitdir:") == nil)
    }

    // MARK: - On-Disk Resolution

    /// Builds a throwaway repository shape and reads the branch back.
    @Test("reads the branch of a regular checkout")
    func readsRegularCheckout() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDirectory = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try "ref: refs/heads/task/DEV-1/x\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )

        #expect(GitBranch.branch(forRepository: root) == "task/DEV-1/x")
    }

    @Test("follows a worktree pointer to its HEAD")
    func readsWorktreeCheckout() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        // The real git directory, holding the worktree's HEAD
        let realGitDirectory = base.appendingPathComponent("main/.git/worktrees/wt")
        try FileManager.default.createDirectory(at: realGitDirectory, withIntermediateDirectories: true)
        try "ref: refs/heads/feature\n".write(
            to: realGitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )
        // The worktree checkout, whose .git is a pointer file
        let worktree = base.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(realGitDirectory.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        #expect(GitBranch.branch(forRepository: worktree) == "feature")
    }

    @Test("a folder without .git yields nil")
    func nonRepositoryYieldsNil() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(GitBranch.branch(forRepository: root) == nil)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBranchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
