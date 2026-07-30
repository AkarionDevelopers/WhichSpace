import Foundation
import Testing
@testable import WhichSpace

struct AgentStatusTests {
    // MARK: - Event Mapping

    @Test("hook events map to their states")
    func hookEventMapping() {
        #expect(AgentState(hookEventName: "UserPromptSubmit") == .working)
        #expect(AgentState(hookEventName: "PreToolUse") == .working)
        #expect(AgentState(hookEventName: "PostToolUse") == .working)
        #expect(AgentState(hookEventName: "Notification") == .waiting)
        #expect(AgentState(hookEventName: "Stop") == .done)
        #expect(AgentState(hookEventName: "SubagentStop") == .done)
        #expect(AgentState(hookEventName: "SessionStart") == nil)
        #expect(AgentState(hookEventName: "Bogus") == nil)
    }

    @Test("urgency orders waiting above working above done")
    func urgencyOrdering() {
        #expect(AgentState.done < AgentState.working)
        #expect(AgentState.working < AgentState.waiting)
    }

    // MARK: - Status File Decoding

    private func payload(event: String, cwd: String = "/p/repo") -> Data {
        let object: [String: Any] = [
            "session_id": "abc",
            "cwd": cwd,
            "hook_event_name": event,
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("decodes a session from a hook payload")
    func decodesSession() {
        let content = AgentSession.parse(
            statusFileData: payload(event: "PreToolUse"), pid: 42, updatedAt: Date(timeIntervalSince1970: 5)
        )
        guard case let .session(session) = content else {
            Issue.record("expected a session, got \(content)")
            return
        }
        #expect(session.sessionID == "abc")
        #expect(session.cwd.path == "/p/repo")
        #expect(session.state == .working)
        #expect(session.pid == 42)
    }

    @Test("SessionEnd is recognized for pruning")
    func recognizesSessionEnd() {
        let content = AgentSession.parse(
            statusFileData: payload(event: "SessionEnd"), pid: nil, updatedAt: Date()
        )
        #expect(content == .ended)
    }

    @Test("partial or malformed payloads are undecodable, not fatal")
    func toleratesPartialWrites() {
        for data in [Data(), Data("{\"session_id\": \"a".utf8), Data("[]".utf8)] {
            let content = AgentSession.parse(statusFileData: data, pid: nil, updatedAt: Date())
            #expect(content == .undecodable)
        }
    }

    @Test("unknown events leave the previous state untouched")
    func unknownEventUndecodable() {
        let content = AgentSession.parse(
            statusFileData: payload(event: "SessionStart"), pid: nil, updatedAt: Date()
        )
        #expect(content == .undecodable)
    }

    // MARK: - Aggregation

    private let projects: [Int: SpaceProject] = [
        100: SpaceProject(spaceID: 100, path: URL(fileURLWithPath: "/p/alpha"), name: "alpha", branch: "main"),
        200: SpaceProject(spaceID: 200, path: URL(fileURLWithPath: "/p/beta"), name: "beta", branch: nil),
    ]

    private func session(_ id: String, cwd: String, state: AgentState) -> AgentSession {
        AgentSession(
            sessionID: id, cwd: URL(fileURLWithPath: cwd), state: state, pid: nil, updatedAt: Date()
        )
    }

    @Test("sessions attribute to the Space of their repository")
    func attributesToSpace() {
        let states = AgentStatusStore.aggregate(
            sessions: [session("a", cwd: "/p/alpha", state: .working)],
            projectsBySpace: projects
        )
        #expect(states == [100: .working])
    }

    @Test("a session in a subdirectory attributes to its project")
    func subdirectoryAttributes() {
        let states = AgentStatusStore.aggregate(
            sessions: [session("a", cwd: "/p/beta/src/deep", state: .done)],
            projectsBySpace: projects
        )
        #expect(states == [200: .done])
    }

    @Test("a path that merely shares a prefix does not attribute")
    func prefixConfusionRejected() {
        let states = AgentStatusStore.aggregate(
            sessions: [session("a", cwd: "/p/alphabet", state: .working)],
            projectsBySpace: projects
        )
        #expect(states.isEmpty)
    }

    @Test("the most urgent session wins per Space")
    func urgencyWinsPerSpace() {
        let states = AgentStatusStore.aggregate(
            sessions: [
                session("a", cwd: "/p/alpha", state: .done),
                session("b", cwd: "/p/alpha", state: .waiting),
                session("c", cwd: "/p/alpha", state: .working),
            ],
            projectsBySpace: projects
        )
        #expect(states == [100: .waiting])
    }

    @Test("sessions outside every project attribute nowhere")
    func unknownCwdIgnored() {
        let states = AgentStatusStore.aggregate(
            sessions: [session("a", cwd: "/elsewhere", state: .waiting)],
            projectsBySpace: projects
        )
        #expect(states.isEmpty)
    }

    // MARK: - Store Pruning

    @MainActor
    @Test("dead and ended sessions are pruned from disk")
    func prunesDeadSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentStatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A session whose writer PID is dead, and one that reported its end
        try payload(event: "PreToolUse").write(to: directory.appendingPathComponent("111.json"))
        try payload(event: "SessionEnd").write(to: directory.appendingPathComponent("222.json"))

        let suite = TestSuiteFactory.createSuite()
        let store = DefaultsStore(suite: suite.suite)
        let stub = CGSStub()
        stub.activeDisplayIdentifier = "Main"
        stub.displays = [
            CGSStub.makeDisplay(displayID: "Main", spaces: [(id: 100, isFullscreen: false)], activeSpaceID: 100),
        ]
        let appState = AppState(displaySpaceProvider: stub, skipObservers: true, store: store)
        let agentStore = AgentStatusStore(
            directory: directory,
            projectIndex: appState.projectIndex,
            isProcessAlive: { _ in false }
        )

        agentStore.refresh()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.isEmpty)
        #expect(agentStore.statesBySpace.isEmpty)
    }
}
