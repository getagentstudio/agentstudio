import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTerminal
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("B1's accepted late-end windows", .serialized)
struct RestoreResumeSameBootTests {
    @Test("a kept end after the reread is honored only at the next launch")
    func storedEndAfterRereadDecidesNextLaunch() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let hold = HeldStep<PaneForegroundEvidence?>("current E8 after final reread before FIFO")
            let repository = HeldResumeEvidenceRepository(base: pane.repository, hold: hold, heldRead: 2)
            let decision = pane.decision(harness: harness, foreground: repository)
            let operation = Task {
                defer { hold.retire() }
                return await pane.resolve(decision)
            }
            do {
                _ = try await hold.firstArrival()
                _ = try await harness.appendLifecycle(
                    pane: pane.paneId, session: pane.sessionId, event: .sessionEnd, at: 20)
                hold.release()
                let result = await operation.value
                guard case .interruptedCandidate = result.evidence else {
                    Issue.record("late stored end must miss this launch's reread cutoff")
                    return
                }
                try await reopen(harness: harness, pane: pane)
                _ = try await harness.restartedDrain()
                let next = await pane.resolve(pane.decision(harness: harness))
                #expect(next.evidence == .knownExited)
            } catch {
                hold.retire()
                _ = await operation.value
                throw error
            }
        }
    }

    @Test(arguments: [false, true])
    func lateLiveEndOrderDeterminesNextLaunch(afterStart: Bool) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let first = await pane.resolve(pane.decision(harness: harness))
            guard case .interruptedCandidate = first.evidence else {
                Issue.record("positive control must commit before the late live end")
                return
            }
            if afterStart { try await reopen(harness: harness, pane: pane) }
            let end = try await harness.ingestion.submitHook(
                .init(
                    paneId: pane.paneId, providerIdentifier: "codex", providerVersion: "1", sessionId: pane.sessionId,
                    eventName: .sessionEnd, turnId: nil, signal: .sessionEnd,
                    recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 20)))
            guard case .committed(let committed) = end else {
                Issue.record("live end not admitted")
                return
            }
            #expect(committed.disposition == (afterStart ? .applied : .recordedOnly))
            if !afterStart { try await reopen(harness: harness, pane: pane) }
            let next = await pane.resolve(pane.decision(harness: harness))
            if afterStart {
                #expect(next.evidence == .knownExited)
            } else {
                guard case .interruptedCandidate = next.evidence else {
                    Issue.record("end before resumed start must permit the next restore")
                    return
                }
            }
        }
    }

    private func reopen(harness: PaneCLIOutboxDrainHarness, pane: ColdResumeTestPane) async throws {
        _ = try await harness.ingestion.submitHook(
            .init(
                paneId: pane.paneId, providerIdentifier: "codex", providerVersion: "1", sessionId: pane.sessionId,
                eventName: .sessionStart, turnId: nil, signal: .sessionStart,
                recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 25)))
    }
}
