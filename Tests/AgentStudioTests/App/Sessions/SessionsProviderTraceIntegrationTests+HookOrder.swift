import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionsProviderTraceIntegrationTests {
    @Test(
        "captured Stop before older question Pre/PostToolUse matches source-order delivery and restore",
        arguments: [false, true])
    func hookSourceOrderMatchesLiveAndRestore(reversed: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        let initial = try await fixture.withIngestion { ingestion, adapter in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            let events: [(String, TimeInterval)] =
                reversed
                ? [("Stop", 30), ("AskUserQuestion.PreToolUse", 10), ("AskUserQuestion.PostToolUse", 20)]
                : [("AskUserQuestion.PreToolUse", 10), ("AskUserQuestion.PostToolUse", 20), ("Stop", 30)]
            for (name, sourceTime) in events {
                let params = try orderedHookParams(name, sourceTime: sourceTime)
                let admitted = try await adapter.recordProviderEvent(
                    paneId: paneId, params: params, provenance: .matchingPane)
                #expect(admitted.disposition == .admitted)
                if reversed {
                    let current = try await ingestion.sessionSummary(paneId: paneId)
                    #expect(current?.status == .idle(.done))
                    #expect(current?.providerPrompts.isEmpty == true)
                }
            }
            let final = try #require(try await ingestion.sessionSummary(paneId: paneId))
            #expect(final.status == .idle(.done))
            #expect(final.providerPrompts.isEmpty)
            return final
        }
        let restored = try await fixture.withIngestion { ingestion, _ in
            try await ingestion.sessionSummary(paneId: paneId)
        }
        #expect(restored == initial)
    }

    @Test("equal source times and absent source times preserve the actual admission order", arguments: [false, true])
    func hookTiesAndMissingSourceKeepAdmission(hasSourceTime: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        let initial = try await fixture.withIngestion { ingestion, adapter in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            for name in ["Stop", "AskUserQuestion.PreToolUse", "AskUserQuestion.PostToolUse"] {
                let params = try orderedHookParams(name, sourceTime: hasSourceTime ? 10 : nil)
                let result = try await adapter.recordProviderEvent(
                    paneId: paneId, params: params, provenance: .matchingPane)
                #expect(result.disposition == .admitted)
            }
            let summary = try #require(try await ingestion.sessionSummary(paneId: paneId))
            #expect(summary.status == .working(.active))
            #expect(summary.providerPrompts.isEmpty)
            return summary
        }
        let restored = try await fixture.withIngestion { ingestion, _ in
            try await ingestion.sessionSummary(paneId: paneId)
        }
        #expect(restored == initial)
    }

    @Test("an older hook replay preserves the independently sequenced open ask and Agent Line work")
    func olderHookPreservesAskSummaryAndLine() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        try await fixture.withIngestion { ingestion, adapter in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            let bound = try #require(try await ingestion.sessionSummary(paneId: paneId))
            // These two recorded traces have different session ids; only the
            // identity is unified so both facts belong to this test binding.
            let newer = try orderedHookParams(
                "UserPromptSubmit", sourceTime: 30, conversationId: bound.sessionRef.value)
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: newer, provenance: .matchingPane)
            let generation = try #require(try await ingestion.sessionSummary(paneId: paneId)?.bindingGeneration)
            await ingestion.receiveAgentLine(work: .monitoring, bindingGenerationId: generation)
            await ingestion.receiveOpenAskSummary(
                .init(
                    bindingGenerationId: generation, summary: .init(sequence: 2, approval: 1, question: 0, blocked: 0)))
            let older = try orderedHookParams("Stop", sourceTime: 10)
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: older, provenance: .matchingPane)
            let withAsk = try await ingestion.sessionSummary(paneId: paneId)
            #expect(withAsk?.status == .needsYou(.approval))
            await ingestion.receiveOpenAskSummary(
                .init(
                    bindingGenerationId: generation, summary: .init(sequence: 1, approval: 0, question: 0, blocked: 0)))
            let delayed = try await ingestion.sessionSummary(paneId: paneId)
            #expect(delayed?.status == .needsYou(.approval))
            await ingestion.receiveOpenAskSummary(
                .init(
                    bindingGenerationId: generation, summary: .init(sequence: 3, approval: 0, question: 0, blocked: 0)))
            let withoutAsk = try await ingestion.sessionSummary(paneId: paneId)
            #expect(withoutAsk?.status == .working(.monitoring))
        }
    }

    @Test(
        "re-reduction preserves a viewed mark on the original stamped or unstamped completion",
        arguments: [false, true])
    func olderHookPreservesViewedCompletion(unstampedStop: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        try await fixture.withIngestion { ingestion, adapter in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            let stop = try orderedHookParams("Stop", sourceTime: unstampedStop ? nil : 30)
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: stop, provenance: .matchingPane)
            if unstampedStop {
                let completion = try orderedHookParams("AskUserQuestion.PostToolUse", sourceTime: 30)
                _ = try await adapter.recordProviderEvent(paneId: paneId, params: completion, provenance: .matchingPane)
            }
            let original = try await ingestion.repository.statusContext(paneId: paneId)
            let generation = try #require(original.currentBinding?.bindingGenerationId)
            let clock = TestPushClock()
            let opening = clock.now
            let base = ContinuousClock.now
            var runtime = SessionsStatusRuntime()
            runtime.restore(original, paneId: paneId, admittedAt: base)
            clock.advance(by: .seconds(1))
            let viewedAt = base.advanced(by: opening.duration(to: clock.now))
            runtime.latestViewedAt[paneId] = viewedAt
            var viewedState = try #require(runtime.states[generation])
            SessionStatusReducer.apply(
                .init(
                    input: .paneViewed(viewedAt), sequence: 0, occurredAt: Date(timeIntervalSince1970: 1),
                    admittedAt: viewedAt, turnId: nil), to: &viewedState)
            runtime.states[generation] = viewedState
            let viewedSummary = try runtime.summary(paneId: paneId)
            #expect(viewedSummary?.status == .idle(.ready))
            clock.advance(by: .seconds(1))
            let older = try orderedHookParams(
                "ElicitationResult", sourceTime: 10, conversationId: original.currentBinding?.providerConversationId)
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: older, provenance: .matchingPane)
            let after = try await ingestion.repository.statusContext(paneId: paneId)
            let lateRecord = try #require(after.evidence.first { $0.occurrenceId == older.event.occurrenceId })
            #expect(runtime.isOlderHook(lateRecord))
            runtime.rereduceBinding(
                after, bindingGenerationId: generation, admittedAt: base.advanced(by: opening.duration(to: clock.now)))
            let summary = try runtime.summary(paneId: paneId)
            #expect(summary?.status == .idle(.ready))
            guard case .done(_, let completionAdmission)? = runtime.states[generation]?.turn else {
                Issue.record("Expected the original Stop completion")
                return
            }
            #expect(completionAdmission == base)
        }
    }
}

private func orderedHookParams(_ fixtureName: String, sourceTime: TimeInterval?, conversationId: String? = nil) throws
    -> IPCSessionEventParams
{
    let original = try projectRecordedStatus(data: recordedStatusData(fixtureName))
    let event = original.event
    var fields = event.providerFields
    fields.sourceOccurredAt = sourceTime.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) }
    return .init(
        handle: original.handle, provider: original.provider,
        event: .init(
            name: event.name, conversationId: conversationId ?? event.conversationId, turnId: event.turnId,
            requestId: event.requestId,
            toolId: event.toolId, subagentId: event.subagentId, occurrenceId: event.occurrenceId, providerFields: fields
        ),
        correlationId: original.correlationId)
}
