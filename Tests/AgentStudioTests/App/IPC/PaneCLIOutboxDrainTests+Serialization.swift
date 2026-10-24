import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTerminal
import Foundation
import Testing

@testable import AgentStudio

extension PaneCLIOutboxDrainTests {
    @Test("overlapping final reads import a kept end once and never veto a later session")
    func concurrentFinalReadsDoNotReplayLifecycleEvidence() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let original = try await ColdResumeTestPane.make(harness: harness)
            let entry = try await harness.appendLifecycle(
                pane: original.paneId, session: original.sessionId, event: .sessionEnd, at: 20)
            let ledger = OutboxRestoreImportLedger()
            // History read is first; cursor snapshot is second.
            let held = HeldOutboxDrainSQLiteAccess(base: harness.sqliteAccess, heldRead: 2)
            let drain = try makeHeldOutboxDrain(harness: harness, held: held, ledger: ledger)
            let first = await startOutboxDrain(on: drain, storeURL: harness.storeURL, caller: .first, held: held)
            var second: StartedOutboxDrain?
            do {
                try await held.first.firstArrival()
                let started = await startOutboxDrain(
                    on: drain, storeURL: harness.storeURL, caller: .second, held: held)
                second = started
                // With no gate, capture the second old cursor before allowing the first commit.
                // With the gate, it cannot read until the predecessor releases its turn.
                if !started.queued { try await held.second.firstArrival() }
                held.first.release()
                let firstReport = await first.task.value
                try await held.second.firstArrival()
                #expect(firstReport.admittedEntryCount == 1)
                #expect(try await original.repository.loadEvidence(paneId: original.paneId)?.value == .reportedEnd)
                let next = try await ColdResumeTestPane.make(harness: harness, paneId: original.paneId)
                #expect(next.look.bindingGenerationId != original.look.bindingGenerationId)
                held.second.release()
                let secondReport = await started.task.value
                #expect(firstReport.admittedEntryCount + secondReport.admittedEntryCount == 1)
                guard case .sessionLifecycle(let report) = entry else {
                    Issue.record("fixture did not append a lifecycle row")
                    return
                }
                #expect(ledger.reports == [report.messageID])
                let observedLook = try await next.repository.load(paneId: next.paneId)
                #expect(observedLook == next.look)
                let result = await next.resolve(next.decision(harness: harness))
                let invocation = ResumeInvocation(
                    provider: .codex, sessionId: try ProviderSessionId(rawValue: next.sessionId))
                #expect(result.evidence == .interruptedCandidate(invocation))
            } catch {
                held.retire()
                first.task.cancel()
                second?.task.cancel()
                _ = await first.task.value
                _ = await second?.task.value
                throw error
            }
        }
    }

    @Test("overlapping history checks adopt a replacement once and cannot re-veto a later generation")
    func concurrentHistoryChecksDoNotReplayHistoryLoss() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let original = try await ColdResumeTestPane.make(harness: harness)
            try await FinalResumeRereadCase.replacement.apply(harness: harness, pane: original)
            let ledger = OutboxRestoreImportLedger()
            let held = HeldOutboxDrainSQLiteAccess(base: harness.sqliteAccess, heldRead: 1)
            let drain = try makeHeldOutboxDrain(harness: harness, held: held, ledger: ledger)
            let first = await startOutboxDrain(on: drain, storeURL: harness.storeURL, caller: .first, held: held)
            var second: StartedOutboxDrain?
            do {
                try await held.first.firstArrival()
                let started = await startOutboxDrain(
                    on: drain, storeURL: harness.storeURL, caller: .second, held: held)
                second = started
                if !started.queued { try await held.second.firstArrival() }
                held.first.release()
                #expect(await first.task.value.readOutcome == .historyLost(thenComplete: 0))
                try await held.second.firstArrival()
                #expect(
                    try await original.repository.loadEvidence(paneId: original.paneId)?.value
                        == .reportsUnreadable(.historyLost))
                _ = try await harness.ingestion.endLiveMainForColdRestore(paneId: original.paneId)
                let next = try await ColdResumeTestPane.make(harness: harness, paneId: original.paneId)
                held.second.release()
                #expect(await started.task.value.readOutcome == .complete(throughId: 0))
                #expect(ledger.historyLosses == 1)
                let observedLook = try await next.repository.load(paneId: next.paneId)
                #expect(observedLook == next.look)
                let result = await next.resolve(next.decision(harness: harness))
                let invocation = ResumeInvocation(
                    provider: .codex, sessionId: try ProviderSessionId(rawValue: next.sessionId))
                #expect(result.evidence == .interruptedCandidate(invocation))
            } catch {
                held.retire()
                first.task.cancel()
                second?.task.cancel()
                _ = await first.task.value
                _ = await second?.task.value
                throw error
            }
        }
    }

    @Test("a cancelled queued read settles while its predecessor is held and FIFO successors each read fresh")
    func cancelledQueuedDrainDoesNotBlockFreshFIFOSuccessors() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            #expect(await harness.drain().readOutcome == .complete(throughId: 0))
            let paneId = UUIDv7.generate()
            _ = try await harness.append(paneID: paneId, line: harness.messageLine(text: "first prefix"))
            let held = HeldOutboxDrainSQLiteAccess(base: harness.sqliteAccess, heldRead: 2)
            let drain = try makeHeldOutboxDrain(harness: harness, held: held, ledger: OutboxRestoreImportLedger())
            let first = await startOutboxDrain(on: drain, storeURL: harness.storeURL, caller: .first, held: held)
            var queued: [StartedOutboxDrain] = []
            do {
                try await held.first.firstArrival()
                let cancelled = await startOutboxDrain(
                    on: drain, storeURL: harness.storeURL, caller: .cancelled, held: held)
                queued.append(cancelled)
                cancelled.task.cancel()
                // This must settle before the first reader is released.
                #expect(await cancelled.task.value.readOutcome == .unreadable(.cancelled))
                #expect(await held.readCount(for: .cancelled) == 0)
                let second = await startOutboxDrain(
                    on: drain, storeURL: harness.storeURL, caller: .second, held: held)
                queued.append(second)
                let third = await startOutboxDrain(
                    on: drain, storeURL: harness.storeURL, caller: .third, held: held)
                queued.append(third)
                held.first.release()
                #expect(await first.task.value.admittedEntryCount == 1)
                try await held.second.firstArrival()
                let later = try await harness.append(
                    paneID: paneId, line: harness.messageLine(text: "fresh second read"))
                held.second.release()
                #expect(await second.task.value.admittedEntryCount == 1)
                #expect(await third.task.value.admittedEntryCount == 0)
                #expect(await third.task.value.readOutcome == .complete(throughId: later.id))
                let messages = try await harness.paneMessages(paneID: paneId).map(\.body)
                #expect(Set(messages) == Set(["first prefix", "fresh second read"]))
            } catch {
                held.retire()
                first.task.cancel()
                for operation in queued { operation.task.cancel() }
                _ = await first.task.value
                for operation in queued { _ = await operation.task.value }
                throw error
            }
        }
    }
}
