import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension FilesystemActorWatchedFolderTests {
    @Test("real result drain retains correlated observations around its debt publication")
    func realDrainRetainsResultCustodyObservations() async throws {
        let fixture = try await WatchedFolderActorFixture(recordsLogicalDebt: true)
        defer { fixture.removeTemporaryRoot() }
        do {
            let pending = try makeConsumerCustodyPending(watchedPath: fixture.watchedPath)
            await fixture.scheduler.seedCustodyPending(pending)
            await fixture.actor.recordLogicalDebtSnapshotIfChanged()
            let baselineRevision = await fixture.actor.logicalDebtSnapshotPublicationRevision
            let consumer = await fixture.actor.watchedFolderScanState.resultConsumer
            let drain = try #require(
                await fixture.actor.startConsumerCustodyDrain(pending: pending, watchedPath: fixture.watchedPath))
            // Scheduler shutdown preserves the pending result and closes the drain after its transfer.
            await fixture.scheduler.shutdown()
            await drain.value

            let retained = try #require(await fixture.actor.resultLeaseConsumerObservations())
            let afterResolve = try #require(retained.afterResolve)
            let beforeSwitch = try #require(retained.beforeSwitch)
            let schedulerObservation = try #require(await fixture.scheduler.lastResultLeaseOutcomes[consumer])
            #expect(schedulerObservation.outcome == .transferred)
            #expect(afterResolve.outcome == .transferred)
            #expect(beforeSwitch.outcome == .transferred)
            for checkpoint in [afterResolve, beforeSwitch] {
                #expect(checkpoint.resultHash == UInt32(truncatingIfNeeded: pending.result.resultID.hashValue))
                #expect(checkpoint.completionOrdinal == pending.completionOrdinal)
                #expect(checkpoint.leaseStartOrdinal == schedulerObservation.leaseStartOrdinal)
            }
            let finalRevision = await fixture.actor.logicalDebtSnapshotPublicationRevision
            #expect(finalRevision == baselineRevision + 1)
            #expect(beforeSwitch.logicalDebtPublicationRevision == finalRevision)
            #expect(await fixture.actor.lastRecordedLogicalDebtSnapshot?.logicalDebtCount == 0)
            let receipts = await fixture.actor.currentWatchedFolderObservationReceipts()
            #expect(receipts.count == 1, "the real apply path must publish the arranged result")
            #expect(receipts.first?.observation.demandCoverage == pending.result.demandCoverage)
            await fixture.shutdown()
            try await fixture.performanceTraceRecorder?.drain()
        } catch {
            await fixture.shutdown()
            do {
                try await fixture.performanceTraceRecorder?.drain()
            } catch let cleanupError {
                Issue.record("trace cleanup failed after custody test failure: \(cleanupError)")
            }
            throw error
        }
    }
}

private func makeConsumerCustodyPending(watchedPath: WatchedPath) throws -> WatchedFolderScanScheduler.PendingResult {
    let seed = try SchedulerLookupDiagnosticFixture()
    let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: watchedPath.id)
    let root = try FilesystemSourceConfiguration.registerRoot(
        from: .hostAuthorized(
            .init(
                registration: .init(sourceID: sourceID, registrationGeneration: 1, rootGeneration: 1),
                authorizedBoundary: watchedPath.path, registeredRoot: watchedPath.path)))
    let request = WatchedFolderScanRequest(canonicalRoot: root, cause: .manual)
    return .init(
        result: .init(
            resultID: seed.pending.result.resultID, request: request,
            demandCoverage: .init(registration: root.registration, throughDemandGeneration: .init(rawValue: 1)),
            scanRunGeneration: 1, scannerResult: completeResult(entries: []),
            schedulingMetrics: seed.pending.result.schedulingMetrics), completionOrdinal: 7)
}

extension FilesystemActor {
    fileprivate func startConsumerCustodyDrain(
        pending: WatchedFolderScanScheduler.PendingResult, watchedPath: WatchedPath
    ) -> Task<Void, Never>? {
        let sourceID = pending.result.request.sourceID
        watchedFolderScanState.registrationsBySourceID[sourceID] = .init(
            watchedPath: watchedPath, registeredRoot: pending.result.request.canonicalRoot,
            legacyCallbackRoutingID: UUIDv7.generate())
        watchedFolderScanState.latestDemandCoverageBySourceID[sourceID] = pending.result.demandCoverage
        ensureWatchedFolderResultDrainStarted()
        return watchedFolderScanState.resultDrainState.task
    }
}
