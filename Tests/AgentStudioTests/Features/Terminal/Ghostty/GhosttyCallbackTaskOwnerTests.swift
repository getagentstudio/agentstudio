import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

@Suite("Ghostty callback task owner")
struct GhosttyCallbackTaskOwnerTests {
    @Test("closing admission joins accepted work through failure and release")
    @MainActor
    func closeSnapshotJoinsAcceptedWorkThroughFailureAndRelease() async throws {
        let fixtureStore = GhosttyCallbackTaskOwnerFixtureStore()

        do {
            try await proveReplyDependsOnStep(
                makeScenario: {
                    let fixture = try GhosttyCallbackTaskOwnerFixture()
                    fixtureStore.append(fixture)
                    return fixture.replyScenario()
                },
                replyReportsFailure: { reply, fixture in
                    reply.outcome == .failed
                        && reply.pendingTaskCount == 0
                        && !fixture.owner.isAcceptingWork
                        && fixture.owner.pendingTaskCount == 0
                },
                assertCommitted: { reply, fixture in
                    #expect(reply.outcome == .released)
                    #expect(reply.pendingTaskCount == 0)
                    #expect(fixture.owner.pendingTaskCount == 0)
                    #expect(await fixture.task.value == .released)
                }
            )
        } catch {
            await fixtureStore.closeAndJoinAll()
            throw error
        }

        await fixtureStore.closeAndJoinAll()
    }

    @Test("enqueue racing admission close is either joined or rejected")
    func enqueueRacingAdmissionCloseIsJoinedOrRejected() async throws {
        let owner = GhosttyCallbackTaskOwner()
        let enqueueReady = HeldStep<Void>("callback enqueue reaches race gate")
        let closeReady = HeldStep<Void>("callback close reaches race gate")
        let operationStep = HeldStep<Void>("racing admitted callback operation")
        let outcomeRecorder = GhosttyCallbackTaskOutcomeRecorder()

        let race: GhosttyCallbackTaskRaceObservation
        do {
            race = try await withThrowingTaskGroup(
                of: GhosttyCallbackTaskRaceOperation.self,
                returning: GhosttyCallbackTaskRaceObservation.self
            ) { group in
                group.addTask {
                    try await enqueueReady.arrive(())
                    let task = owner.enqueueTask { @MainActor in
                        let outcome: GhosttyCallbackTaskOutcome
                        do {
                            try await operationStep.arrive(())
                            outcome = .released
                        } catch {
                            outcome = .failed
                        }
                        outcomeRecorder.record(outcome)
                        return outcome
                    }
                    return .enqueued(task)
                }
                group.addTask {
                    try await closeReady.arrive(())
                    return .closed(owner.closeAdmissionAndSnapshot())
                }

                do {
                    _ = try await enqueueReady.firstArrival()
                    _ = try await closeReady.firstArrival()
                    enqueueReady.release()
                    closeReady.release()
                } catch {
                    enqueueReady.retire()
                    closeReady.retire()
                    operationStep.retire()
                    throw error
                }

                var admittedTask: Task<GhosttyCallbackTaskOutcome, Never>?
                var closedSnapshot: GhosttyCallbackTaskSnapshot?
                for try await operation in group {
                    switch operation {
                    case .enqueued(let task):
                        admittedTask = task
                    case .closed(let snapshot):
                        closedSnapshot = snapshot
                    }
                }
                guard let closedSnapshot else {
                    throw GhosttyCallbackTaskOwnerTestFailure.closeDidNotReturnSnapshot
                }
                return GhosttyCallbackTaskRaceObservation(
                    admittedTask: admittedTask,
                    closedSnapshot: closedSnapshot
                )
            }
        } catch {
            enqueueReady.retire()
            closeReady.retire()
            operationStep.retire()
            await owner.closeAdmissionAndSnapshot().joinAdmittedTasks()
            throw error
        }

        #expect(!owner.isAcceptingWork)
        if let admittedTask = race.admittedTask {
            #expect(owner.pendingTaskCount == 1)
            do {
                _ = try await operationStep.firstArrival()
                operationStep.release()
                await race.closedSnapshot.joinAdmittedTasks()
                let outcomeAfterJoin = outcomeRecorder.snapshot()
                let pendingCountAfterJoin = owner.pendingTaskCount
                #expect(outcomeAfterJoin == .released)
                #expect(pendingCountAfterJoin == 0)
                #expect(await admittedTask.value == .released)
            } catch {
                operationStep.retire()
                await owner.closeAdmissionAndSnapshot().joinAdmittedTasks()
                throw error
            }
        } else {
            #expect(owner.pendingTaskCount == 0)
            #expect(operationStep.recordedArrivals.isEmpty)
            await race.closedSnapshot.joinAdmittedTasks()
        }
        #expect(owner.pendingTaskCount == 0)
    }

    @Test("closed admission rejects later work without invoking it")
    func closedAdmissionRejectsLaterWorkWithoutInvokingIt() async {
        let owner = GhosttyCallbackTaskOwner()
        let invocationRecorder = GhosttyCallbackTaskInvocationRecorder()
        let closedSnapshot = owner.closeAdmissionAndSnapshot()

        let postCloseTask: Task<GhosttyCallbackTaskOutcome, Never>? = owner.enqueueTask { @MainActor in
            invocationRecorder.recordInvocation()
            return .released
        }

        var rejectedPostCloseEnqueue = false
        if let postCloseTask {
            _ = await postCloseTask.value
        } else {
            rejectedPostCloseEnqueue = true
        }
        await closedSnapshot.joinAdmittedTasks()

        #expect(rejectedPostCloseEnqueue)
        #expect(!invocationRecorder.wasInvoked)
        #expect(owner.pendingTaskCount == 0)
        #expect(!owner.isAcceptingWork)
    }

    @Test("completion removes only its own task handle")
    func completionRemovesOnlyItsOwnTaskHandle() async throws {
        let owner = GhosttyCallbackTaskOwner()
        let firstOperationStep = HeldStep<Void>("first owned callback operation")
        let secondOperationStep = HeldStep<Void>("second owned callback operation")
        let firstOutcomeRecorder = GhosttyCallbackTaskOutcomeRecorder()
        let secondOutcomeRecorder = GhosttyCallbackTaskOutcomeRecorder()

        guard
            let firstTask = owner.enqueueTask({ @MainActor in
                let outcome: GhosttyCallbackTaskOutcome
                do {
                    try await firstOperationStep.arrive(())
                    outcome = .released
                } catch {
                    outcome = .failed
                }
                firstOutcomeRecorder.record(outcome)
                return outcome
            })
        else {
            throw GhosttyCallbackTaskOwnerTestFailure.initialEnqueueWasRejected
        }
        guard
            let secondTask = owner.enqueueTask({ @MainActor in
                let outcome: GhosttyCallbackTaskOutcome
                do {
                    try await secondOperationStep.arrive(())
                    outcome = .released
                } catch {
                    outcome = .failed
                }
                secondOutcomeRecorder.record(outcome)
                return outcome
            })
        else {
            firstOperationStep.retire()
            await owner.closeAdmissionAndSnapshot().joinAdmittedTasks()
            let pendingCountAfterCleanupJoin = owner.pendingTaskCount
            #expect(pendingCountAfterCleanupJoin == 0)
            _ = await firstTask.value
            throw GhosttyCallbackTaskOwnerTestFailure.initialEnqueueWasRejected
        }

        do {
            _ = try await firstOperationStep.firstArrival()
            _ = try await secondOperationStep.firstArrival()
            #expect(owner.pendingTaskCount == 2)

            firstOperationStep.release()
            #expect(await firstTask.value == .released)
            #expect(owner.pendingTaskCount == 1)

            let closedSnapshot = owner.closeAdmissionAndSnapshot()
            secondOperationStep.release()
            await closedSnapshot.joinAdmittedTasks()
            let secondOutcomeAfterJoin = secondOutcomeRecorder.snapshot()
            let pendingCountAfterJoin = owner.pendingTaskCount
            #expect(secondOutcomeAfterJoin == .released)
            #expect(pendingCountAfterJoin == 0)
            #expect(await secondTask.value == .released)
            #expect(owner.pendingTaskCount == 0)
        } catch {
            firstOperationStep.retire()
            secondOperationStep.retire()
            await owner.closeAdmissionAndSnapshot().joinAdmittedTasks()
            let pendingCountAfterCleanupJoin = owner.pendingTaskCount
            #expect(pendingCountAfterCleanupJoin == 0)
            _ = await firstTask.value
            _ = await secondTask.value
            throw error
        }
    }
}

private enum GhosttyCallbackTaskOutcome: Sendable, Equatable {
    case pending
    case released
    case failed
}

private enum GhosttyCallbackTaskOwnerTestFailure: Error, Sendable {
    case initialEnqueueWasRejected
    case closeDidNotReturnSnapshot
}

private struct GhosttyCallbackTaskOwnerFixture: Sendable {
    let owner: GhosttyCallbackTaskOwner
    let entryStep: HeldStep<Void>
    let step: HeldStep<Void>
    let task: Task<GhosttyCallbackTaskOutcome, Never>
    let snapshot: GhosttyCallbackTaskSnapshot
    let outcomeRecorder: GhosttyCallbackTaskOutcomeRecorder

    init() throws {
        let owner = GhosttyCallbackTaskOwner()
        let entryStep = HeldStep<Void>("reply starts before the task-owner join")
        let step = HeldStep<Void>("accepted callback task owner operation")
        let outcomeRecorder = GhosttyCallbackTaskOutcomeRecorder()
        guard
            let task = owner.enqueueTask({ @MainActor in
                let outcome: GhosttyCallbackTaskOutcome
                do {
                    try await entryStep.arrive(())
                    try await step.arrive(())
                    outcome = .released
                } catch {
                    outcome = .failed
                }
                outcomeRecorder.record(outcome)
                return outcome
            })
        else {
            throw GhosttyCallbackTaskOwnerTestFailure.initialEnqueueWasRejected
        }

        self.owner = owner
        self.entryStep = entryStep
        self.step = step
        self.task = task
        self.snapshot = owner.closeAdmissionAndSnapshot()
        self.outcomeRecorder = outcomeRecorder
    }

    func replyScenario() -> HeldReplyScenario<
        Self,
        Void,
        GhosttyCallbackTaskOwnerReply
    > {
        HeldReplyScenario(
            context: self,
            step: step,
            produceReply: { @MainActor [entryStep, snapshot, owner, outcomeRecorder] in
                _ = try? await entryStep.firstArrival()
                entryStep.release()
                await snapshot.joinAdmittedTasks()
                return GhosttyCallbackTaskOwnerReply(
                    outcome: outcomeRecorder.snapshot(),
                    pendingTaskCount: owner.pendingTaskCount
                )
            }
        )
    }

    func closeAndJoin() async {
        entryStep.retire()
        step.retire()
        await owner.closeAdmissionAndSnapshot().joinAdmittedTasks()
    }
}

private final class GhosttyCallbackTaskOwnerFixtureStore: Sendable {
    private let fixtures = Mutex<[GhosttyCallbackTaskOwnerFixture]>([])

    func append(_ fixture: GhosttyCallbackTaskOwnerFixture) {
        fixtures.withLock { $0.append(fixture) }
    }

    func closeAndJoinAll() async {
        let retainedFixtures = fixtures.withLock { $0 }
        for fixture in retainedFixtures {
            await fixture.closeAndJoin()
        }
    }
}

private enum GhosttyCallbackTaskRaceOperation: Sendable {
    case enqueued(Task<GhosttyCallbackTaskOutcome, Never>?)
    case closed(GhosttyCallbackTaskSnapshot)
}

private struct GhosttyCallbackTaskRaceObservation: Sendable {
    let admittedTask: Task<GhosttyCallbackTaskOutcome, Never>?
    let closedSnapshot: GhosttyCallbackTaskSnapshot
}

private struct GhosttyCallbackTaskOwnerReply: Sendable {
    let outcome: GhosttyCallbackTaskOutcome
    let pendingTaskCount: Int
}

private final class GhosttyCallbackTaskOutcomeRecorder: Sendable {
    private let outcome = Mutex(GhosttyCallbackTaskOutcome.pending)

    func record(_ outcome: GhosttyCallbackTaskOutcome) {
        self.outcome.withLock { $0 = outcome }
    }

    func snapshot() -> GhosttyCallbackTaskOutcome {
        outcome.withLock { $0 }
    }
}

private final class GhosttyCallbackTaskInvocationRecorder: Sendable {
    private let invoked = Mutex(false)

    var wasInvoked: Bool {
        invoked.withLock { $0 }
    }

    func recordInvocation() {
        invoked.withLock { $0 = true }
    }
}
