import Foundation
import os

extension WatchedFolderScanScheduler {
    static let logger = Logger(subsystem: "com.agentstudio", category: "WatchedFolderScanScheduler")

    /// Reports the lease trap's reread state to distinguish a missing entry from a different case.
    static func failPendingResultLease(
        reread: RootSchedulingState?,
        candidateCount: Int,
        scheduledRootCount: Int,
        pendingCount: Int,
        leasedCount: Int
    ) -> Never {
        let observed = reread?.diagnosticCaseName ?? "absent"
        Self.logger.fault(
            """
            Selected result must remain pending until leased; reread state: \(observed, privacy: .public), \
            candidates: \(candidateCount, privacy: .public), \
            scheduled roots: \(scheduledRootCount, privacy: .public), \
            pending: \(pendingCount, privacy: .public), \
            leased: \(leasedCount, privacy: .public)
            """
        )
        preconditionFailure("selected result must remain pending until leased; reread state: \(observed)")
    }

    /// Reports the ready-queue trap's stored state to distinguish a missing entry from a different case.
    static func failReadyRootSynchronization(
        stored: RootSchedulingState?,
        readyCount: Int,
        scheduledRootCount: Int,
        readyNodeCount: Int
    ) -> Never {
        let observed = stored?.diagnosticCaseName ?? "absent"
        Self.logger.fault(
            """
            Ready-root queue and scheduling state must remain synchronized; stored state: \
            \(observed, privacy: .public), ready: \(readyCount, privacy: .public), \
            scheduled roots: \(scheduledRootCount, privacy: .public), \
            ready nodes: \(readyNodeCount, privacy: .public)
            """
        )
        preconditionFailure(
            "ready-root queue and scheduling state must remain synchronized; stored state: \(observed)"
        )
    }
}

extension WatchedFolderScanScheduler.RootSchedulingState {
    var diagnosticCaseName: String {
        switch self {
        case .queuedNew: "queuedNew"
        case .queuedSuspended: "queuedSuspended"
        case .queuedSuspendedAndDirty: "queuedSuspendedAndDirty"
        case .running: "running"
        case .runningAndDirty: "runningAndDirty"
        case .awaitingValidation: "awaitingValidation"
        case .awaitingValidationAndDirty: "awaitingValidationAndDirty"
        case .pendingResult: "pendingResult"
        case .pendingResultAndDirty: "pendingResultAndDirty"
        case .leasedResult: "leasedResult"
        case .leasedResultAndDirty: "leasedResultAndDirty"
        }
    }
}
