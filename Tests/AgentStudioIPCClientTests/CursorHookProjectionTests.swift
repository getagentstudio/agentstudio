import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Cursor hook projection")
struct CursorHookProjectionTests {
    @Test("the installed vocabulary is exactly the three lifecycle hooks")
    func installedVocabulary() {
        #expect(CursorHookEventName.installedEvents.map(\.rawValue) == ["beforeSubmitPrompt", "stop", "sessionEnd"])
        for excluded in ["sessionStart", "subagentStart", "subagentStop", "preToolUse"] {
            #expect(CursorHookEventName(rawValue: excluded) == nil)
        }
    }

    @Test(
        "projects each Cursor event and preserves provider turn identity",
        arguments: [
            ("beforeSubmitPrompt", "", IPCSessionEventName.turnStart),
            ("sessionEnd", "", .sessionEnd),
            ("stop", "completed", .turnDone),
            ("stop", "aborted", .turnAbort),
            ("stop", "error", .turnFailed),
        ])
    func projectsLifecycle(scenario: (String, String, IPCSessionEventName)) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "conversation_id": "conversation", "generation_id": "generation", "hook_event_name": scenario.0,
            "status": scenario.1, "cursor_version": "2026.10.01-e373342",
            "unrelated": ["account": "never copied"],
        ])
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: data)
        let event = try #require(CursorHookEventName(rawValue: scenario.0))
        let projected = try #require(
            CursorHookProjection.project(
                eventName: event, payload: payload))
        #expect(projected.provider == .init(identifier: "cursor", version: "2026.10.01-e373342", mode: "cli"))
        #expect(projected.event.name == scenario.2)
        #expect(projected.event.conversationId == "conversation")
        #expect(projected.event.turnId == (scenario.0 == "sessionEnd" ? nil : "generation"))
        #expect(projected.event.subagentId == nil)
        #expect(projected.event.failureSummary == (scenario.2 == .turnFailed ? "unknown" : nil))
        let repeated = try #require(
            CursorHookProjection.project(
                eventName: event, payload: payload))
        #expect(projected.event.occurrenceId != repeated.event.occurrenceId)
    }

    @Test("unknown stop status projects nothing and missing version remains descriptive")
    func unknownStatusIsNotSuccess() throws {
        let payload = try JSONDecoder().decode(
            CursorHookPayload.self, from: Data(#"{"conversation_id":"conversation","status":"unexpected"}"#.utf8))
        #expect(CursorHookProjection.project(eventName: .stop, payload: payload) == nil)
        #expect(
            CursorHookProjection.project(eventName: .beforeSubmitPrompt, payload: payload)?.provider.version
                == "unknown")
    }
}
