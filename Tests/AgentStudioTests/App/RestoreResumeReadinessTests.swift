import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@Suite("Launch resume readiness")
struct RestoreResumeReadinessTests {
    @Test("waiting before IPC starts does not consume the launch-read deadline")
    func waitingBeforeReadDoesNotExpireReadiness() async throws {
        let paneId = UUIDv7.generate()
        let facts = FactRecorder<UUID, ReadinessProofFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .closed }))
        let clock = TestPushClock()
        let readiness = RestoreResumeReadiness(
            clock: clock, deadline: AppPolicies.Restore.resumeReadinessDeadline,
            waiterRegistered: { facts.append(scope: $0, fact: .waitRegistered) })
        let wait = Task {
            let result = await readiness.wait(paneId: paneId)
            facts.append(scope: paneId, fact: .waitEnded)
            return result
        }
        do {
            let registration = try await facts.expectNext(
                in: paneId, where: { $0 == .waitRegistered || $0 == .waitEnded },
                "cold waiter registration or termination")
            try #require(registration == .waitRegistered)
            clock.advance(by: AppPolicies.Restore.resumeReadinessDeadline + .seconds(1))
            // Joining a mistakenly armed task makes the old failure deterministic.
            // Correct code has no deadline task until beginRead, so this never waits.
            await readiness.deadlineTask?.value
            await readiness.beginRead()
            await readiness.record(.complete(throughId: 41))

            #expect(await wait.value == .ready)
            await readiness.shutdown()
            facts.append(scope: paneId, fact: .closed)
            try await facts.finish()
        } catch {
            wait.cancel()
            await readiness.shutdown()
            _ = await wait.value
            facts.append(scope: paneId, fact: .closed)
            try? await facts.finish()
            throw error
        }
    }

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
        await readiness.beginRead()
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

    @Test("an incomplete report cannot start a deadline before beginRead")
    func incompleteReportDoesNotStartRead() async {
        let readiness = RestoreResumeReadiness(clock: TestPushClock(), deadline: .seconds(2))
        await readiness.record(.incomplete(heldAtId: 41))
        #expect(await readiness.deadlineTask == nil)
        await readiness.shutdown()
    }

    @Test("launch-drain construction failure releases the waiter without a timer")
    func constructionFailureReleasesWaiter() async {
        struct ConstructionFailure: Error {}
        let readiness = RestoreResumeReadiness(clock: TestPushClock(), deadline: .seconds(2))
        let wait = Task { await readiness.wait(paneId: UUIDv7.generate()) }
        let drain = await PaneCLIOutboxDrain.makeAndDrainForLaunch(
            storeURL: URL(fileURLWithPath: "/unused-readiness-proof"), readiness: readiness,
            clock: TestPushClock(), makeDrain: { throw ConstructionFailure() })

        #expect(drain == nil)
        let missingOutcome = await readiness.isPending
        #expect(!missingOutcome, "construction failure must publish unavailable before returning")
        if missingOutcome { wait.cancel() }
        #expect(await wait.value == .unavailable)
        await readiness.shutdown()
    }

    @Test("shutdown before a read releases the waiter without a timer")
    func shutdownBeforeReadReleasesWaiter() async {
        let readiness = RestoreResumeReadiness(clock: TestPushClock(), deadline: .seconds(2))
        let wait = Task { await readiness.wait(paneId: UUIDv7.generate()) }
        await readiness.shutdown()

        #expect(await readiness.isPending == false)
        #expect(await wait.value == .unavailable)
    }
}

private enum ReadinessProofFact: Equatable, Sendable {
    case sleep(TestPushClock.Instant)
    case waitRegistered, waitEnded, closed
}
