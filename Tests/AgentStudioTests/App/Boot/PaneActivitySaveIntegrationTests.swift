import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("App pane activity save integration", .serialized)
struct PaneActivitySaveIntegrationTests {
    init() { installTestCoreAtomsIfNeeded() }
    @Test("App publishes before a held commit and subsequent batches stay ordered", arguments: [false, true])
    func publicationPrecedesCommitAndFailureContinues(firstCommitFails: Bool) async throws {
        let delegate = AppDelegate()
        delegate.atomStore = makeTestAtomRegistry()
        let recorder = PaneActivityHeldCommitRecorder()
        let sink = delegate.makePaneActivitySink { commit in try await recorder.commit(commit) }
        let clock = PaneActivityClock(sink: sink)
        await clock.start()
        let firstID = UUIDv7.generate()
        let secondID = UUIDv7.generate()
        let instant = ContinuousClock.now
        let first = PaneActivityOccurrence(
            paneId: firstID, source: .hook, orderingInstant: instant, wallTime: Date(timeIntervalSince1970: 100))
        let second = PaneActivityOccurrence(
            paneId: secondID, source: .terminal, orderingInstant: instant, wallTime: Date(timeIntervalSince1970: 200))
        do {
            clock.submit(first)
            let firstCommit = try await recorder.firstCommit.firstArrival()
            #expect(firstCommit.mutations == [.set(firstID, first.activityTime)])
            #expect(delegate.atomStore.core.paneActivityTime.value(for: firstID) == first.activityTime)
            #expect(await recorder.completed.isEmpty)
            // This ingress returns while the save is held, without awaiting SQLite.
            clock.submit(second)
            if firstCommitFails {
                recorder.firstCommit.fail(PaneActivityInjectedCommitFailure.failed)
            } else {
                recorder.firstCommit.release()
            }
            let secondCommit = try await recorder.secondCommit.firstArrival()
            #expect(secondCommit.mutations == [.set(secondID, second.activityTime)])
            #expect(recorder.firstOutcome() == (firstCommitFails ? .failed : .committed))
            #expect(delegate.atomStore.core.paneActivityTime.value(for: secondID) == second.activityTime)
            recorder.secondCommit.release()
            let completedCommit = try await recorder.secondCommitCompletion.firstArrival()
            #expect(completedCommit == secondCommit)
            #expect(await recorder.attempted == [firstCommit, secondCommit])
            #expect(await recorder.completed == (firstCommitFails ? [secondCommit] : [firstCommit, secondCommit]))
        } catch {
            recorder.firstCommit.retire()
            recorder.secondCommit.retire()
            recorder.secondCommitCompletion.retire()
            await clock.shutdown()
            throw error
        }
        await clock.shutdown()
    }

    @Test("App sink return depends on the held commit outcome")
    func sinkReturnDependsOnCommit() async throws {
        try await proveReplyDependsOnStep(
            makeScenario: {
                let delegate = AppDelegate()
                delegate.atomStore = makeTestAtomRegistry()
                let recorder = PaneActivityHeldCommitRecorder()
                let paneID = UUIDv7.generate()
                let time = PaneActivityTime(
                    orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .hook
                )
                let sink = delegate.makePaneActivitySink { commit in try await recorder.commit(commit) }
                return HeldReplyScenario(
                    context: recorder,
                    step: recorder.firstCommit,
                    produceReply: { @MainActor [delegate] in
                        await sink([.set(paneID, time)])
                        #expect(delegate.atomStore.core.paneActivityTime.value(for: paneID) == time)
                        return recorder.firstOutcome()
                    }
                )
            },
            replyReportsFailure: { reply, _ in reply == .failed },
            assertCommitted: { reply, _ in #expect(reply == .committed) }
        )
    }

    @Test("App sink commits real SQLite sets and final removals")
    func realDatastorePublicationAndRemoval() async throws {
        let delegate = AppDelegate()
        delegate.atomStore = makeTestAtomRegistry()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: UUIDv7.generate())
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let sink = delegate.makePaneActivitySink { commit in try await datastore.commitPaneActivity(commit) }
        let paneID = UUIDv7.generate()
        let time = PaneActivityTime(
            orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .hook)
        await sink([.set(paneID, time)])
        #expect(delegate.atomStore.core.paneActivityTime.value(for: paneID) == time)
        #expect(
            try fixture.localRepository.fetchPaneActivity() == [
                .init(paneId: paneID, wallTime: time.wallTime, source: .hook)
            ])
        await sink([.remove(paneID)])
        #expect(delegate.atomStore.core.paneActivityTime.value(for: paneID) == nil)
        #expect(try fixture.localRepository.fetchPaneActivity().isEmpty)
    }
}

private enum PaneActivityInjectedCommitFailure: Error { case failed }

private enum PaneActivityCommitOutcome: Sendable { case pending, committed, failed }

private actor PaneActivityHeldCommitRecorder {
    nonisolated let firstCommit = HeldStep<PaneActivityCommit>("first pane activity commit")
    nonisolated let secondCommit = HeldStep<PaneActivityCommit>("second pane activity commit")
    nonisolated let secondCommitCompletion = HeldStep<PaneActivityCommit>("second pane activity commit completed")
    nonisolated private let firstCommitOutcome = Mutex(PaneActivityCommitOutcome.pending)
    private(set) var attempted: [PaneActivityCommit] = []
    private(set) var completed: [PaneActivityCommit] = []

    init() {
        // This is a completion witness, not another hold on the operation.
        secondCommitCompletion.release()
    }

    nonisolated func firstOutcome() -> PaneActivityCommitOutcome {
        firstCommitOutcome.withLock { $0 }
    }

    func commit(_ commit: PaneActivityCommit) async throws {
        attempted.append(commit)
        let isFirstCommit = attempted.count == 1
        do {
            if isFirstCommit {
                try await firstCommit.arrive(commit)
            } else {
                try await secondCommit.arrive(commit)
            }
        } catch {
            if isFirstCommit { firstCommitOutcome.withLock { $0 = .failed } }
            throw error
        }
        completed.append(commit)
        if isFirstCommit {
            firstCommitOutcome.withLock { $0 = .committed }
        } else {
            try await secondCommitCompletion.arrive(commit)
        }
    }
}
