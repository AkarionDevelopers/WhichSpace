import Foundation
import Testing
@testable import WhichSpace

struct LabelTemplateTokenTests {
    private let context = LabelContext(space: 3, branch: "task/DEV-8585/bu", project: "grc-cloud-2")

    // MARK: - Token Resolution

    @Test("{branch} resolves to the full branch")
    func branchToken() {
        #expect(LabelTemplate.resolve("{branch}", context: context) == "task/DEV-8585/bu")
    }

    @Test("{branch:last} resolves to the last segment")
    func branchLastToken() {
        #expect(LabelTemplate.resolve("{branch:last}", context: context) == "bu")
    }

    @Test("{branch:last} of a segmentless branch is the branch")
    func branchLastOfPlainBranch() {
        let plain = LabelContext(space: 1, branch: "main", project: nil)
        #expect(LabelTemplate.resolve("{branch:last}", context: plain) == "main")
    }

    @Test("{ticket} extracts the issue key")
    func ticketToken() {
        #expect(LabelTemplate.resolve("{ticket}", context: context) == "DEV-8585")
    }

    @Test("{ticket} on a branch without an issue key resolves to nothing")
    func ticketTokenWithoutKey() {
        let plain = LabelContext(space: 1, branch: "main", project: nil)
        #expect(LabelTemplate.resolve("{ticket}", context: plain).isEmpty)
    }

    @Test("{project} resolves to the folder name")
    func projectToken() {
        #expect(LabelTemplate.resolve("{project}", context: context) == "grc-cloud-2")
    }

    @Test("tokens compose with literals and {#}")
    func composedTemplate() {
        #expect(LabelTemplate.resolve("{#}: {ticket}", context: context) == "3: DEV-8585")
    }

    @Test("absent context resolves branch tokens to nothing")
    func absentContext() {
        let bare = LabelContext(space: 2)
        #expect(LabelTemplate.resolve("{branch}{branch:last}{ticket}{project}", context: bare).isEmpty)
        #expect(LabelTemplate.resolve("{#}", context: bare) == "2")
    }

    @Test("the space-only wrapper still resolves")
    func spaceOnlyWrapper() {
        #expect(LabelTemplate.resolve("S{#}", space: 7) == "S7")
    }

    // MARK: - Ticket Extraction

    @Test("issue keys are found anywhere in the branch")
    func ticketAnywhere() {
        #expect(LabelTemplate.ticket(inBranch: "ABC-123") == "ABC-123")
        #expect(LabelTemplate.ticket(inBranch: "feature/AB2-9/x") == "AB2-9")
        #expect(LabelTemplate.ticket(inBranch: "fix-DEV-42") == "DEV-42")
        #expect(LabelTemplate.ticket(inBranch: "main") == nil)
        // Lowercase codes are not issue keys
        #expect(LabelTemplate.ticket(inBranch: "abc-123") == nil)
    }

    // MARK: - Content Length

    @Test("all tokens are zero-width for the authoring limit")
    func tokensAreZeroWidth() {
        #expect(LabelTemplate.contentLength("{branch}{branch:last}{ticket}{project}{#}{number}") == 0)
        #expect(LabelTemplate.contentLength("ab{ticket}cd") == 4)
    }

    // MARK: - Resolved Truncation

    @Test("resolved labels are capped with an ellipsis")
    func resolvedTruncation() {
        let long = String(repeating: "x", count: 40)
        let truncated = LabelTemplate.truncateResolved(long)
        #expect(truncated.count == LabelTemplate.maxResolvedLength)
        #expect(truncated.hasSuffix("…"))
    }

    @Test("short resolved labels pass through unchanged")
    func shortResolvedUntouched() {
        #expect(LabelTemplate.truncateResolved("DEV-8585") == "DEV-8585")
    }
}
