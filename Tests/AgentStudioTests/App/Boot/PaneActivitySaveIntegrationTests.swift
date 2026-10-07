import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
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
        let firstID = UUIDv7.generate()
        let secondID = UUIDv7.generate()
        let instant = ContinuousClock.now
        let first = PaneActivityOccurrence(
            paneId: firstID, source: .hook, orderingInstant: instant, wallTime: Date(timeIntervalSince1970: 100))
        let second = PaneActivityOccurrence(
            paneId: secondID, source: .terminal, orderingInstant: instant, wallTime: Date(timeIntervalSince1970: 200))
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
        #expect(delegate.atomStore.core.paneActivityTime.value(for: secondID) == second.activityTime)
        recorder.secondCommit.release()
        #expect(try await clock.settled() == .quiescent)
        #expect(await recorder.attempted == [firstCommit, secondCommit])
        #expect(await recorder.completed == (firstCommitFails ? [secondCommit] : [firstCommit, secondCommit]))
        await clock.shutdown()
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

private actor PaneActivityHeldCommitRecorder {
    nonisolated let firstCommit = HeldStep<PaneActivityCommit>("first pane activity commit")
    nonisolated let secondCommit = HeldStep<PaneActivityCommit>("second pane activity commit")
    private(set) var attempted: [PaneActivityCommit] = []
    private(set) var completed: [PaneActivityCommit] = []

    func commit(_ commit: PaneActivityCommit) async throws {
        attempted.append(commit)
        if attempted.count == 1 {
            try await firstCommit.arrive(commit)
        } else {
            try await secondCommit.arrive(commit)
        }
        completed.append(commit)
    }
}
