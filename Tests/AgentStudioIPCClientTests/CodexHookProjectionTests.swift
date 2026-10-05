import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// The hook projection is the contract between Codex and Sessions: it names
/// the event and preserves provider identities needed to correlate real work.
@Suite("Codex hook projection")
struct CodexHookProjectionTests {
    @Test(
        "each projected Codex event maps to its session event name",
        arguments: [
            (CodexHookEventName.sessionStart, IPCSessionEventName.sessionStart),
            (.userPromptSubmit, .turnStart),
            (.stop, .turnDone),
            (.interrupt, .turnAbort),
            (.permissionRequest, .permission),
            (.preToolUse, .toolActivity),
            (.subagentStart, .subagentActivity),
            (.subagentStop, .subagentActivity),
            (.sessionEnd, .sessionEnd),
        ]
    )
    func projectedEventNames(
        eventName: CodexHookEventName, expected: IPCSessionEventName
    ) throws {
        let payload = try CodexFixtures.payload(for: eventName)

        let projected = try #require(
            CodexHookProjection.project(eventName: eventName, payload: payload))

        #expect(projected.event.name == expected)
        #expect(projected.event.conversationId == CodexFixtures.sessionId)
        #expect(projected.provider.identifier == "codex")
        #expect(projected.provider.version == "0.154.0")
        #expect(projected.provider.mode == "cli")
    }

    @Test("the session lifecycle events carry no turn and turn events keep the provider turn id")
    func turnIdentityFollowsThePayload() throws {
        let start = try projected(.sessionStart)
        let end = try projected(.sessionEnd)
        let turnStart = try projected(.userPromptSubmit)

        #expect(start.event.turnId == nil)
        #expect(end.event.turnId == nil)
        #expect(turnStart.event.turnId == CodexFixtures.turnId)
    }

    @Test("tool and subagent events keep their real provider identities")
    func subjectIdentityFollowsThePayload() throws {
        let tool = try projected(.preToolUse)
        let subagentStart = try projected(.subagentStart)
        let subagentStop = try projected(.subagentStop)

        #expect(tool.event.toolId == "call_9f2c41ab")
        #expect(tool.event.subagentId == nil)
        #expect(subagentStart.event.subagentId == "agent_4d71")
        #expect(subagentStop.event.subagentId == "agent_4d71")
        #expect(subagentStart.event.toolId == nil)
    }

    @Test("subagent events preserve each payload's agent id")
    func distinctSubagentIdsStayDistinct() throws {
        let reviewer = CodexHookPayload(
            sessionId: CodexFixtures.sessionId, turnId: CodexFixtures.turnId, agentId: "agent-reviewer")
        let researcher = CodexHookPayload(
            sessionId: CodexFixtures.sessionId, turnId: CodexFixtures.turnId, agentId: "agent-researcher")

        let reviewerEvent = try #require(CodexHookProjection.project(eventName: .subagentStart, payload: reviewer))
        let researcherEvent = try #require(
            CodexHookProjection.project(eventName: .subagentStart, payload: researcher))

        #expect(reviewerEvent.event.subagentId == "agent-reviewer")
        #expect(researcherEvent.event.subagentId == "agent-researcher")
        #expect(reviewerEvent.event.subagentId != researcherEvent.event.subagentId)
    }

    @Test("Codex does not manufacture a permission request identity")
    func permissionRequestHasNoSyntheticRequestIdentity() throws {
        let permission = try projected(.permissionRequest)
        let turnStart = try projected(.userPromptSubmit)

        #expect(permission.event.requestId == nil)
        #expect(turnStart.event.requestId == nil)
    }

    @Test("each projection uses the supplied fresh occurrence identity")
    func occurrenceIdentityUsesFreshIdentifierSeam() throws {
        let payload = try CodexFixtures.payload(for: .preToolUse)
        let firstIdentifier = UUIDv7.generate()
        let secondIdentifier = UUIDv7.generate()
        var issued = [firstIdentifier, secondIdentifier]
        let freshIdentifier: () -> UUID = { issued.removeFirst() }

        let first = try #require(
            CodexHookProjection.project(
                eventName: .preToolUse, payload: payload, freshOccurrenceIdentifier: freshIdentifier))
        let second = try #require(
            CodexHookProjection.project(
                eventName: .preToolUse, payload: payload, freshOccurrenceIdentifier: freshIdentifier))

        #expect(first.event.occurrenceId == firstIdentifier)
        #expect(second.event.occurrenceId == secondIdentifier)
        #expect(first.event.occurrenceId != second.event.occurrenceId)
    }

    @Test("the projection's default occurrence identity is UUIDv7")
    func defaultOccurrenceIdentityIsUUIDv7() throws {
        let projected = try projected(.stop)

        #expect(projected.event.occurrenceId.uuid.6 & 0xF0 == 0x70)
    }

    @Test(
        "the events Agent Studio does not model project to nothing",
        arguments: [CodexHookEventName.postToolUse, .preCompact, .postCompact])
    func unmodelledEventsDoNotProject(eventName: CodexHookEventName) {
        let payload = CodexHookPayload(sessionId: CodexFixtures.sessionId, turnId: CodexFixtures.turnId)

        #expect(CodexHookProjection.isProjected(eventName) == false)
        #expect(CodexHookProjection.project(eventName: eventName, payload: payload) == nil)
    }

    @Test("a payload version overrides the verified default when a provider reports one")
    func reportedVersionWins() {
        let payload = CodexHookPayload(sessionId: "s", codexVersion: "0.155.1")

        let projected = CodexHookProjection.project(eventName: .sessionStart, payload: payload)

        #expect(projected?.provider.version == "0.155.1")
    }

    private func projected(_ eventName: CodexHookEventName) throws -> CodexHookProjectedEvent {
        try #require(
            CodexHookProjection.project(
                eventName: eventName, payload: try CodexFixtures.payload(for: eventName)))
    }
}
