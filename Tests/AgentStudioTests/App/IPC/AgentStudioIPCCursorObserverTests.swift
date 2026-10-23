import AgentStudioIPCClientCore
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

@MainActor
@Suite("Cursor observers through the real Sessions adapter", .serialized)
struct AgentStudioIPCCursorObserverTests {
    @Test(
        "source-shaped serialized events pair tools and keep child outcomes off the parent turn",
        arguments: ["completed", "error"])
    func cursorObserversReachReducer(childStatus: String) async throws {
        try await withPaneContextSessionsBridge { fixture in
            let adapter = AgentStudioIPCSessionsAdapter(
                ingestion: fixture.ingestion, now: { fixture.time.now },
                processChainReader: EligibleTestProcessChainReader())
            let paneId = fixture.paneId.uuid
            func admit(_ event: String, extra: [String: String] = [:]) async throws {
                var fields = [
                    "conversation_id": "parent", "generation_id": "turn", "hook_event_name": event,
                    "cursor_version": "2026.10.16-e3cb207",
                ]
                fields.merge(extra) { _, new in new }
                let payload = try JSONDecoder().decode(CursorHookPayload.self, from: JSONEncoder().encode(fields))
                let name = try #require(CursorHookEventName(rawValue: event))
                let projected = try #require(CursorHookProjection.project(eventName: name, payload: payload))
                let result = try await adapter.recordProviderEvent(
                    paneId: paneId,
                    params: .init(
                        handle: paneId.uuidString, provider: projected.provider, event: projected.event,
                        correlationId: projected.event.occurrenceId),
                    provenance: .matchingPane)
                #expect(result.disposition == .admitted)
            }
            try await admit("sessionStart")
            let bootstrap = try await fixture.ingestion.repository.statusContext(paneId: paneId)
            #expect(bootstrap.evidence.last?.turnId == nil)
            let initial = try await adapter.readSessionState(paneId: paneId, params: .init(handle: "self"))
            #expect(initial.session?.status == .unknown)
            try await admit("beforeSubmitPrompt")
            try await admit("preToolUse", extra: ["tool_use_id": "tool-A", "tool_name": "Shell"])
            try await admit("postToolUse", extra: ["tool_use_id": "tool-A", "tool_name": "Shell"])
            try await admit(
                "postToolUseFailure",
                extra: [
                    "tool_use_id": "tool-B", "failure_type": "execution_error", "error_message": "private diagnostic",
                ])
            try await admit(
                "subagentStart",
                extra: ["subagent_id": "child-A", "parent_conversation_id": "parent", "task": "private task"])
            try await admit(
                "subagentStop",
                extra: [
                    "subagent_id": "child-A", "parent_conversation_id": "parent", "status": childStatus,
                    "error_message": "private child error",
                ])
            let context = try await fixture.ingestion.repository.statusContext(paneId: paneId)
            #expect(context.evidence.count == 7)
            #expect(
                context.evidence.map(\.subject) == [
                    .root, .root, .tool("tool-A"), .tool("tool-A"), .tool("tool-B"), .subagent("child-A"),
                    .subagent("child-A"),
                ])
            #expect(
                context.evidence.map(\.providerSignal) == [
                    .sessionStart, .turnStart, .toolActivity(toolName: "Shell"),
                    .toolCompleted(toolCallId: "tool-A"), .toolFailed(toolCallId: "tool-B"), .subagentActivity,
                    .subagentActivity,
                ])
            let read = try await adapter.readSessionState(paneId: paneId, params: .init(handle: "self"))
            #expect(read.session?.conversationId == "parent")
            #expect(read.session?.status == .working(state: .active))
        }
    }
}
