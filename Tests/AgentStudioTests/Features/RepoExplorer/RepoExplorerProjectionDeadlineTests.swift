import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioRepoExplorer

@Suite("Repo Explorer projection deadline worker")
struct RepoExplorerProjectionDeadlineTests {
    @Test("Panes deadlines use the captured continuous reference after a wall step")
    func paneDeadlineIgnoresWallClockStep() async {
        let pushClock = TestPushClock()
        let requestedDurations = AsyncStream.makeStream(of: Duration.self)
        let referenceInstant = ContinuousClock.now
        let worker = RepoExplorerProjectionWorker(
            deadlineDelay: AsyncDelay { duration in
                requestedDurations.continuation.yield(duration)
                try await pushClock.sleep(for: duration)
            },
            deadlineNow: { Date(timeIntervalSince1970: 900) },
            continuousNow: { referenceInstant.advanced(by: .seconds(5)) }
        )
        let deadline = RepoExplorerPreparedPresentationDeadline(
            deadline: Date(timeIntervalSince1970: 1010),
            paneIDs: [UUIDv7.generate()],
            repositoryIDs: [],
            referenceInstant: referenceInstant,
            referenceDate: Date(timeIntervalSince1970: 1000)
        )

        await worker.updatePresentationDeadline(deadline, demanded: true, generation: 1)
        var iterator = requestedDurations.stream.makeAsyncIterator()
        #expect(await iterator.next() == .seconds(5))
        await pushClock.waitForPendingSleepCount(exactly: 1)
        await worker.updatePresentationDeadline(nil, demanded: false, generation: 2)
        await pushClock.waitForPendingSleepCount(exactly: 0)
        requestedDurations.continuation.finish()
    }

    @Test("demand removal cancels the wait; one current deadline fires; stale generations are ignored")
    func demandAndGenerationOwnOneDeadline() async {
        let pushClock = TestPushClock()
        let firedGenerations = Mutex<[Int]>([])
        let fireEvents = AsyncStream.makeStream(of: Int.self)
        let deadline = RepoExplorerPreparedPresentationDeadline(
            deadline: Date(timeIntervalSince1970: 1010),
            paneIDs: [UUIDv7.generate()],
            repositoryIDs: []
        )
        let worker = RepoExplorerProjectionWorker(
            deadlineDelay: .clock(pushClock),
            deadlineNow: { Date(timeIntervalSince1970: 1000) },
            onDeadline: { generation, _ in
                firedGenerations.withLock { $0.append(generation) }
                fireEvents.continuation.yield(generation)
            }
        )

        await worker.updatePresentationDeadline(deadline, demanded: true, generation: 1)
        await pushClock.waitForPendingSleepCount(exactly: 1)
        await worker.updatePresentationDeadline(nil, demanded: false, generation: 2)
        await pushClock.waitForPendingSleepCount(exactly: 0)
        pushClock.advance(by: .seconds(10))
        #expect(firedGenerations.withLock { $0.isEmpty })

        await worker.updatePresentationDeadline(deadline, demanded: true, generation: 3)
        await pushClock.waitForPendingSleepCount(exactly: 1)
        var iterator = fireEvents.stream.makeAsyncIterator()
        pushClock.advance(by: .seconds(10))
        #expect(await iterator.next() == 3)
        #expect(firedGenerations.withLock { $0 } == [3])
        #expect(await worker.hasPendingPresentationDeadline() == false)

        await worker.updatePresentationDeadline(deadline, demanded: true, generation: 2)
        #expect(await worker.hasPendingPresentationDeadline() == false)
        fireEvents.continuation.finish()
    }

    /// Output at t=10 moves a pane's clock boundary from t=60 to t=70 while its row still reads
    /// "Now", so the projection is equal-paint. The deadline must move with it, or "Now" goes
    /// stale; a re-projection that lands on the same transitions must not re-arm, or a fired
    /// deadline would loop.
    @Test("an equal-paint result re-arms only when a pane or repository transition moved")
    func equalPaintRearmFollowsMovedTransitions() {
        let paneID = UUIDv7.generate()
        let repositoryID = UUIDv7.generate()
        let firstTransition = Date(timeIntervalSince1970: 1060)
        let repositoryCutoff = Date(timeIntervalSince1970: 1060)
        let baseline = Self.result(
            paneTransitions: [paneID: firstTransition],
            repositoryTransitions: [repositoryID: repositoryCutoff]
        )

        let movedPane = Self.result(
            paneTransitions: [paneID: firstTransition.addingTimeInterval(10)],
            repositoryTransitions: [repositoryID: repositoryCutoff]
        )
        let movedRepository = Self.result(
            paneTransitions: [paneID: firstTransition],
            repositoryTransitions: [repositoryID: repositoryCutoff.addingTimeInterval(60)]
        )
        let unchanged = Self.result(
            paneTransitions: [paneID: firstTransition],
            repositoryTransitions: [repositoryID: repositoryCutoff]
        )

        #expect(movedPane.movesPresentationTransitions(from: baseline))
        #expect(movedRepository.movesPresentationTransitions(from: baseline))
        #expect(!unchanged.movesPresentationTransitions(from: baseline))
        #expect(baseline.movesPresentationTransitions(from: nil))
    }

    private static func result(
        paneTransitions: [UUID: Date],
        repositoryTransitions: [UUID: Date]
    ) -> RepoExplorerProjectionResult {
        let empty = RepoExplorerProjectionResult.empty
        return RepoExplorerProjectionResult(
            generation: empty.generation,
            snapshot: empty.snapshot,
            collapsedGroupIds: empty.collapsedGroupIds,
            isFiltering: empty.isFiltering,
            trigger: empty.trigger,
            projection: empty.projection,
            rowIndex: empty.rowIndex,
            materializationSnapshot: empty.materializationSnapshot,
            workerDuration: empty.workerDuration,
            projectionDuration: empty.projectionDuration,
            rowIndexDuration: empty.rowIndexDuration,
            branchStatusByWorktreeId: empty.branchStatusByWorktreeId,
            branchNameByWorktreeId: empty.branchNameByWorktreeId,
            bridgeCommandResolutionByWorktreeId: empty.bridgeCommandResolutionByWorktreeId,
            paneRowFactsByPaneId: empty.paneRowFactsByPaneId,
            tabGroupFactsByTabId: empty.tabGroupFactsByTabId,
            repositoryActivityDispositionByRepoId: empty.repositoryActivityDispositionByRepoId,
            repositoryActivityTransitionAtByRepoId: repositoryTransitions,
            sidebarPresentationTransitionAtByPaneId: paneTransitions,
            preparedPresentationDeadline: nil,
            semanticBaselineSequence: nil
        )
    }
}
