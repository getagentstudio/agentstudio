import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("Ghostty router restore-phase end during drain", .serialized)
struct GhosttyRouterRestorePhaseEndDuringDrainTests {
    @Test("input landing while the real drain is suspended still schedules a follow-up that delivers it")
    func restorePhaseEndWhileRealDrainIsSuspendedStillDelivers() async throws {
        let generation = RestoreGeneration(rawValue: 11)
        let suspensionPoint = HeldStep<Void>("real drain suspended submitting ordinary activity")
        let source = LocalFactSource<UUID, RestoreGeneration>(
            vocabulary: FactVocabulary(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) }, isClosing: { _, _ in true })
        )
        let facts = try source.attach()
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.registerRuntime = false
        configuration.activityProjectionContext = .init(
            isAttended: false, isAgentClassified: false, outputBurstThreshold: 30)
        configuration.activityInputObserved = { input in
            switch input {
            case .aggregate:
                try? await suspensionPoint.arrive(())
            case .orderedControl(_, let paneID, _, .restorePhaseEnded(let generation)):
                source.sink(paneID, generation)
            default:
                break
            }
        }
        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            let taskOwner = GhosttyCallbackTaskOwner()
            let schedulerReference = Mutex<TerminalLocalActionDrainScheduler?>(nil)
            let scheduler = TerminalLocalActionDrainScheduler(
                drain: { surfaceID, lane, accumulator in
                    await fixture.handler.host.drainLocalActions(
                        for: surfaceID, lane: lane, accumulator: accumulator)
                },
                enqueueMainActorDrain: { operation in
                    // fire-and-forget: taskOwner admits this task and the test joins every admitted task at teardown.
                    _ = taskOwner.enqueueTask {
                        await operation()
                        if schedulerReference.withLock({ $0?.pendingDrainClaimCount }) == 0 {
                            // A missing follow-up closes the source instead of hanging the fact wait.
                            source.end()
                            suspensionPoint.retire()
                        }
                    }
                }
            )
            schedulerReference.withLock { $0 = scheduler }
            let accumulator = TerminalLocalActionAccumulator(
                scheduleDrain: scheduler.schedule, scheduleFollowUpDrain: scheduler.scheduleFollowUp,
                isAcceptingWork: { taskOwner.isAcceptingWork })
            accumulator.offer(
                .scrollbar(ScrollbarState(top: 0, bottom: 10, total: 10), observedAtMilliseconds: 1000),
                for: fixture.surfaceID)
            do {
                _ = try await suspensionPoint.firstArrival()
                accumulator.markRestorePhaseEnded(
                    surfaceID: fixture.surfaceID, generation: generation,
                    contextBeforeControl: configuration.activityProjectionContext)
                suspensionPoint.release()
                try await facts.expectNext(in: fixture.paneUUID, generation)
                let snapshot = taskOwner.closeAdmissionAndSnapshot()
                await snapshot.joinAdmittedTasks()
                scheduler.cancelAll()
                try await facts.finish()
            } catch {
                suspensionPoint.retire()
                let snapshot = taskOwner.closeAdmissionAndSnapshot()
                scheduler.cancelAll()
                await snapshot.joinAdmittedTasks()
                throw error
            }
        }
        source.end()
    }
}
