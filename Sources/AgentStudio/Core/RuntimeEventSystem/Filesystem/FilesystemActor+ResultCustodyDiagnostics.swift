import os

extension FilesystemActor {
    package struct ResultLeaseConsumerCheckpoint: Equatable, Sendable {
        let resultHash: UInt32
        let completionOrdinal: UInt64
        let leaseStartOrdinal: UInt64
        let outcome: WatchedFolderScanScheduler.ResultLeaseOutcomeCase
        let logicalDebtPublicationRevision: UInt64?

        func matches(_ submitted: WatchedFolderScanScheduler.SubmittedLeaseDiagnostics) -> Bool {
            resultHash == submitted.resultHash && completionOrdinal == submitted.completionOrdinal
                && leaseStartOrdinal == submitted.leaseStartOrdinal
        }
    }

    package struct ResultLeaseConsumerObservations: Equatable, Sendable {
        let afterResolve: ResultLeaseConsumerCheckpoint?
        let beforeSwitch: ResultLeaseConsumerCheckpoint?
    }

    enum ResultLeaseObservationPoint: Sendable {
        case afterResolve
        case beforeSwitch
    }

    package func resultLeaseConsumerObservations() -> ResultLeaseConsumerObservations? {
        lastResultLeaseConsumerObservations
    }

    @inline(never)
    static func observeResultLeaseResolution(
        _ resolution: borrowing WatchedFolderScanResultLeaseResolutionResult,
        at _: ResultLeaseObservationPoint
    ) -> WatchedFolderScanScheduler.ResultLeaseOutcomeCase {
        WatchedFolderScanScheduler.ResultLeaseOutcomeCase(resolution)
    }

    // The sole consumer overwrites one scalar record; no result payload or history is retained.
    @inline(never)
    func recordResultLeaseObservation(
        _ resolution: borrowing WatchedFolderScanResultLeaseResolutionResult,
        submitted: WatchedFolderScanScheduler.SubmittedLeaseDiagnostics,
        at point: ResultLeaseObservationPoint
    ) {
        let checkpoint = ResultLeaseConsumerCheckpoint(
            resultHash: submitted.resultHash, completionOrdinal: submitted.completionOrdinal,
            leaseStartOrdinal: submitted.leaseStartOrdinal,
            outcome: Self.observeResultLeaseResolution(resolution, at: point),
            logicalDebtPublicationRevision: point == .beforeSwitch ? logicalDebtSnapshotPublicationRevision : nil)
        switch point {
        case .afterResolve:
            lastResultLeaseConsumerObservations = .init(afterResolve: checkpoint, beforeSwitch: nil)
        case .beforeSwitch:
            lastResultLeaseConsumerObservations = .init(
                afterResolve: lastResultLeaseConsumerObservations?.afterResolve, beforeSwitch: checkpoint)
        }
    }

    func reportResultLeaseCustodyFailure(
        consumer: WatchedFolderScanResultConsumerToken, lease: WatchedFolderScanResultLease
    ) async {
        let submitted = lease.submittedDiagnostics
        let consumerObservations = resultLeaseConsumerObservations()
        let afterResolve = consumerObservations?.afterResolve.flatMap { $0.matches(submitted) ? $0 : nil }
        let beforeSwitch = consumerObservations?.beforeSwitch.flatMap { $0.matches(submitted) ? $0 : nil }
        let recorded = await watchedFolderScanScheduler.resultLeaseResolutionObservation(
            for: consumer, leaseID: lease.leaseID, leaseStartOrdinal: submitted.leaseStartOrdinal)
        let checkpoints = WatchedFolderScanScheduler.ResultLeaseOutcomeCheckpoints(
            scheduler: recorded?.outcome, afterResolve: afterResolve?.outcome, beforeSwitch: beforeSwitch?.outcome)
        let report =
            WatchedFolderScanScheduler.formatSubmittedResultLease(
                submitted, transitionOrdinalAtResolve: recorded?.transitionOrdinalAtResolve)
            + "\n" + WatchedFolderScanScheduler.formatResultLeaseOutcomeCheckpoints(checkpoints)
            + "\nbefore-switch-debt-publication-revision=\(beforeSwitch?.logicalDebtPublicationRevision.map(String.init) ?? "unavailable")"
        for line in report.split(separator: "\n") {
            WatchedFolderScanScheduler.logger.fault(
                "Result custody \(submitted.resultIdentity, privacy: .public): \(line, privacy: .public)")
        }
    }
}
