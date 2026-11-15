import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

struct SchedulerResultCustodyFixture: Sendable {
    typealias Scheduler = WatchedFolderScanScheduler
    let scheduler: Scheduler
    let consumer: WatchedFolderScanResultConsumerToken
    let pending: Scheduler.PendingResult
    let lease: WatchedFolderScanResultLease

    static func withLease(
        _ operation: @Sendable (Self) async throws -> Void
    ) async throws {
        let seed = try SchedulerLookupDiagnosticFixture()
        let result = seed.pending.result.scannerResult
        let scheduler = try Scheduler(
            maximumConcurrentScans: 1, now: { .zero },
            validationExecutor: RepoScannerValidationExecutor(validationClient: CustodyUnusedValidationClient()),
            sessionFactory: { _, _ in
                .init(
                    id: .init(rawValue: UUIDv7.generate()), advanceOneQuantum: { .finished(result) },
                    cancel: { .cancelled }, consumeValidationCompletion: { _ in .consumed })
            })
        do {
            await scheduler.seedCustodyPending(seed.pending)
            let consumer = WatchedFolderScanResultConsumerToken.make()
            #expect(await scheduler.bindResultConsumer(consumer) == .bound)
            let granted = await scheduler.nextResultLease(for: consumer)
            guard case .leased(let lease) = granted else {
                Issue.record("expected real scheduler to grant seeded pending result")
                await scheduler.shutdown()
                return
            }
            try await operation(.init(scheduler: scheduler, consumer: consumer, pending: seed.pending, lease: lease))
            await scheduler.shutdown()
        } catch {
            await scheduler.shutdown()
            throw error
        }
    }

    func resolve(
        consumer submittedConsumer: WatchedFolderScanResultConsumerToken? = nil,
        leaseID submittedLeaseID: WatchedFolderScanResultLeaseID? = nil
    ) async -> (WatchedFolderScanResultLeaseResolutionResult, Scheduler.ResultLeaseOutcomeCheckpoints) {
        let resolvingConsumer = submittedConsumer ?? consumer
        let resolvingLeaseID = submittedLeaseID ?? lease.leaseID
        let resolution = await scheduler.resolveResultLease(
            for: resolvingConsumer, leaseID: resolvingLeaseID,
            submittedDiagnostics: lease.submittedDiagnostics, resolution: .transferred)
        let afterReturn = FilesystemActor.observeResultLeaseResolution(resolution, at: .afterResolve)
        // A completed actor call orders this observation; there is no clock/idle wait.
        _ = await scheduler.stateSnapshot()
        let beforeSwitch = FilesystemActor.observeResultLeaseResolution(resolution, at: .beforeSwitch)
        let recorded = await scheduler.resultLeaseResolutionObservation(
            for: resolvingConsumer, leaseID: resolvingLeaseID,
            leaseStartOrdinal: lease.submittedDiagnostics.leaseStartOrdinal)
        return (
            resolution,
            .init(scheduler: recorded?.outcome, afterResolve: afterReturn, beforeSwitch: beforeSwitch)
        )
    }
}

extension WatchedFolderScanScheduler {
    func seedCustodyPending(_ pending: PendingResult) {
        currentRootBySourceID[pending.result.request.sourceID] = pending.result.request.canonicalRoot
        replaceSchedulingState(for: pending.result.request.sourceID, with: .pendingResult(pending))
    }
}

private struct CustodyUnusedValidationClient: RepoDiscoveryReadClient {
    func validateDiscoveryCandidate(at candidateURL: URL) async -> GitRepositoryDiscoveryOutcome {
        .failure(.serviceFailed(detail: "unexpected validation in result-custody test"))
    }
}
