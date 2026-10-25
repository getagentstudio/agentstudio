import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTerminal
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

extension RestoreResumeDecisionBoundaryTests {
    @Test("unavailable launch readiness leaves durable foreground evidence unchanged")
    func unavailableReadinessDoesNotPersistUnknown() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let before = try await harness.evidenceRepository.loadEvidence(paneId: pane.paneId)
            let verdict = await pane.decision(harness: harness).resolve(
                paneId: pane.paneId, sessionId: pane.zmxSessionId,
                readiness: .unavailable, launchBoot: .init(previousBootId: "B", currentBootId: "B"),
                inventory: .complete([:]))

            #expect(verdict.evidence == .unknown(.reportsNotRead))
            #expect(try await harness.evidenceRepository.loadEvidence(paneId: pane.paneId) == before)
        }
    }

    @Test("F4 names a stored other start even when cold end returns no main")
    func otherStartWithoutMainNamesItsOwnID() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            _ = await harness.drain()
            let pane = UUIDv7.generate()
            let other = UUIDv7.generate().uuidString
            let session = ZmxSessionID.generateUUIDv7()
            harness.membership.addPane(.init(existingUUID: pane))
            _ = try await harness.appendLifecycle(pane: pane, session: other, event: .sessionStart, at: 20)
            _ = await harness.drain()
            let decision = ColdRestoreResumeDecision(
                ingestion: harness.ingestion, foregroundRepository: harness.evidenceRepository,
                drain: harness.drainOwner, storeURL: harness.storeURL)
            let result = await decision.resolve(
                paneId: pane, sessionId: session, readiness: .ready,
                launchBoot: .init(previousBootId: "B", currentBootId: "B"), inventory: .complete([:]))
            #expect(result.endedMain == nil)
            #expect(result.evidence == .unknown(.changedWhileClosed))
            let plan = result.applying(to: coldResumeBasePlan(session: session))
            #expect(plan.resume == nil)
            #expect(plan.notice.linesByCandidateIndex[0].contains("Codex session \(other.prefix(8))"))
        }
    }

    @Test("an unsupported raw main can be named without becoming invocable")
    func cursorRawMainIsNotResumable() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(
                harness: harness, provider: "cursor", sessionId: "\n\u{1b}éabc123456789")
            let result = await pane.resolve(pane.decision(harness: harness))
            #expect(result.evidence == .unknown(.unknownProvider))
            let plan = result.applying(to: coldResumeBasePlan(session: pane.zmxSessionId))
            #expect(plan.resume == nil)
            #expect(plan.notice.linesByCandidateIndex[0].contains("Cursor session abc12345"))
        }
    }

    @Test("a same-binding reopen cannot clear the stored-other-start veto")
    func sameBindingReopenKeepsReportedVetoInActualVerdict() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            _ = try await harness.appendLifecycle(
                pane: pane.paneId, session: UUIDv7.generate().uuidString, event: .sessionStart, at: 20)
            _ = await harness.drain()
            #expect(await pane.resolve(pane.decision(harness: harness)).evidence == .unknown(.changedWhileClosed))
            _ = try await harness.ingestion.submitHook(
                .init(
                    paneId: pane.paneId, providerIdentifier: "codex", providerVersion: "1", sessionId: pane.sessionId,
                    eventName: .sessionStart, turnId: nil, signal: .sessionStart,
                    recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 25),
                    chain: TestMainAgentChain.observation))
            try await pane.repository.clearReportedEvidenceForChangedBinding(paneId: pane.paneId)
            #expect(await pane.resolve(pane.decision(harness: harness)).evidence == .unknown(.changedWhileClosed))
        }
    }

    @Test("an unhandled lifecycle row survives purge and decides the real cold verdict")
    func preservedLifecycleRowDecidesColdVerdict() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let row = try await harness.appendLifecycle(
                pane: pane.paneId, session: pane.sessionId, event: .sessionEnd, at: 20)
            let writer = harness.writer
            let remaining = try await valueFromDedicatedThread {
                _ = try writer.purgeHandledOutbox(
                    expectedStoreID: writer.identity.storeID, through: 0,
                    now: Date(timeIntervalSince1970: 100_000_000)
                ).get()
                return try writer.readOutbox(after: 0).get().entries.map(\.id)
            }
            #expect(remaining == [row.id])
            let result = await pane.resolve(pane.decision(harness: harness))
            #expect(result.evidence == .knownExited)
        }
    }

    @Test("a new positively observed Y resumes after S-to-T history loss; unchanged T stays adopted")
    func newBindingResumesAfterHistoryLoss() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let original = try await ColdResumeTestPane.make(harness: harness)
            try await FinalResumeRereadCase.replacement.apply(harness: harness, pane: original)
            #expect(await harness.drain().readOutcome == .historyLost(thenComplete: 0))
            let affected = await original.resolve(original.decision(harness: harness))
            #expect(affected.evidence == .unknown(.historyLost))
            let next = try await ColdResumeTestPane.make(harness: harness, paneId: original.paneId)
            #expect(next.bindingGenerationId != original.bindingGenerationId)
            #expect(await harness.drain().readOutcome == .complete(throughId: 0))
            #expect(await harness.drain().readOutcome == .complete(throughId: 0))
            let result = await next.resolve(next.decision(harness: harness))
            let invocation = ResumeInvocation(
                provider: .codex, sessionId: try ProviderSessionId(rawValue: next.sessionId))
            #expect(result.evidence == .interruptedCandidate(invocation))
        }
    }
}
