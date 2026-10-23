import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@Suite("Launch resume readiness")
struct RestoreResumeReadinessTests {
    @Test(
        "complete and missing reads release; unreadable reads refuse",
        arguments: [
            ClosedAppReadOutcome.complete(throughId: 41), .verifiedEmpty, .historyLost(thenComplete: nil),
            .unreadable(.localDatabase), .unreadable(.store(.readOnly)), .unreadable(.store(.unavailable)),
        ])
    func readOutcomeDecidesReadiness(outcome: ClosedAppReadOutcome) async {
        let readiness = RestoreResumeReadiness(clock: TestPushClock(), deadline: .seconds(2))
        await readiness.record(outcome)
        let result = await readiness.wait(paneId: UUIDv7.generate())
        if case .unreadable = outcome { #expect(result == .unavailable) } else { #expect(result == .ready) }
        await readiness.shutdown()
    }

    @Test("a busy read cannot release cold panes past the controlled deadline")
    func busyPastDeadlineRefuses() async throws {
        let scope = UUIDv7.generate()
        let facts = FactRecorder<UUID, ReadinessProofFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .closed }))
        let clock = TestPushClock(pendingSleepFactSink: { fact in
            if case .registrationSettled(let deadline, _) = fact { facts.append(scope: scope, fact: .sleep(deadline)) }
        })
        let deadline = clock.now.advanced(by: .seconds(2))
        let readiness = RestoreResumeReadiness(clock: clock, deadline: .seconds(2))
        await readiness.record(.incomplete(heldAtId: 41))
        let wait = Task {
            let result = await readiness.wait(paneId: scope)
            facts.append(scope: scope, fact: .waitEnded)
            return result
        }
        do {
            let registration = try await facts.expectNext(
                in: scope, where: { $0 == .sleep(deadline) || $0 == .waitEnded },
                "launch deadline or waiter termination")
            try #require(registration == .sleep(deadline))
            clock.advance(to: deadline)
            #expect(await wait.value == .unavailable)
            await readiness.shutdown()
            facts.append(scope: scope, fact: .closed)
            try await facts.finish()
        } catch {
            wait.cancel()
            await readiness.shutdown()
            _ = await wait.value
            facts.append(scope: scope, fact: .closed)
            try? await facts.finish()
            throw error
        }
    }

    @Test("cancellation and shutdown release readiness waiters")
    func cancelledWaitDoesNotLeak() async {
        let readiness = RestoreResumeReadiness(clock: TestPushClock(), deadline: .seconds(2))
        let wait = Task { await readiness.wait(paneId: UUIDv7.generate()) }
        wait.cancel()
        #expect(await wait.value == .unavailable)
        await readiness.shutdown()
    }
}

private enum ReadinessProofFact: Equatable, Sendable {
    case sleep(TestPushClock.Instant)
    case waitEnded, closed
}
