import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Cursor hook projection")
struct CursorHookProjectionTests {
    @Test("the installed vocabulary is exactly nine observer hooks")
    func installedVocabulary() {
        #expect(
            CursorHookEventName.installedEvents.map(\.rawValue) == [
                "beforeSubmitPrompt", "stop", "sessionEnd", "sessionStart", "preToolUse", "postToolUse",
                "postToolUseFailure", "subagentStart", "subagentStop",
            ])
        for excluded in ["afterTab", "workspaceOpen", "futureHook"] {
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

extension CursorHookProjectionTests {
    @Test(
        "observer payloads preserve only the declared correlation and summary fields",
        arguments: ["sessionStart", "preToolUse", "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop"])
    func observerPayloadMapping(eventName: String) throws {
        let data = Data(
            #"{"conversation_id":"parent","generation_id":"turn","tool_use_id":"tool-A","tool_name":"Shell","failure_type":"execution_error","is_interrupt":true,"subagent_id":"child-A","parent_conversation_id":"parent","status":"error","error_message":"private raw error","task":"private task"}"#
                .utf8)
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: data)
        let name = try #require(CursorHookEventName(rawValue: eventName))
        let projected = try #require(CursorHookProjection.project(eventName: name, payload: payload))
        let expected: IPCSessionEventName
        switch eventName {
        case "sessionStart": expected = .sessionStart
        case "preToolUse": expected = .toolActivity
        case "postToolUse": expected = .toolCompleted
        case "postToolUseFailure": expected = .toolFailed
        default: expected = .subagentActivity
        }
        #expect(projected.event.name == expected)
        #expect(projected.event.turnId == (eventName == "sessionStart" ? nil : "turn"))
        #expect(projected.event.toolId == (eventName.contains("ToolUse") ? "tool-A" : nil))
        #expect(projected.event.subagentId == (eventName.hasPrefix("subagent") ? "child-A" : nil))
        #expect(projected.event.toolName == (["preToolUse", "postToolUse"].contains(eventName) ? "Shell" : nil))
        #expect(projected.event.failureSummary == (eventName == "postToolUseFailure" ? "interrupted" : nil))
        #expect(projected.event.providerFields.message == nil)
    }

    @Test(
        "missing correlation ids cannot be admitted",
        arguments: ["preToolUse", "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop"],
        [nil, "", "  "] as [String?])
    func observerRequiresIdentifier(eventName: String, identifier: String?) throws {
        var fields = ["conversation_id": "parent", "generation_id": "turn"]
        fields[eventName.hasPrefix("subagent") ? "subagent_id" : "tool_use_id"] = identifier
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: JSONEncoder().encode(fields))
        #expect(
            CursorHookProjection.project(
                eventName: try #require(CursorHookEventName(rawValue: eventName)), payload: payload) == nil)
    }

    @Test(
        "failure summaries use provider categories with an unknown fallback",
        arguments: [nil, "execution_error"] as [String?])
    func toolFailureSummary(failureType: String?) throws {
        var fields = ["conversation_id": "parent", "tool_use_id": "tool-A", "error_message": "never copy raw errors"]
        fields["failure_type"] = failureType
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: JSONEncoder().encode(fields))
        #expect(
            CursorHookProjection.project(eventName: .postToolUseFailure, payload: payload)?.event.failureSummary
                == failureType ?? "unknown")
    }
    @Test("bootstrap requires a conversation and never creates a turn", arguments: ["", "conversation"])
    func bootstrapRequiresConversation(conversation: String) throws {
        let payload = try JSONDecoder().decode(
            CursorHookPayload.self,
            from: JSONEncoder().encode([
                "conversation_id": conversation, "generation_id": "bootstrap-id",
            ]))
        let projected = CursorHookProjection.project(eventName: .sessionStart, payload: payload)
        #expect((projected != nil) == !conversation.isEmpty)
        #expect(projected?.event.turnId == nil)
    }

}
