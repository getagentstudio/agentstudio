import Foundation
import os

extension WatchedFolderScanScheduler {
    static let logger = Logger(subsystem: "com.agentstudio", category: "WatchedFolderScanScheduler")

    /// Reports the lease trap's reread state to distinguish a missing entry from a different case.
    static func failPendingResultLease(
        _ snapshot: LeaseLookupSnapshot
    ) -> Never {
        let observed = snapshot.checkpoints.afterLeaseCreation
        // Keep each bounded entry in its own record instead of one large dynamic string.
        for line in Self.formatLeaseLookup(snapshot).split(separator: "\n") {
            Self.logger.fault(
                "Lease lookup \(snapshot.selectedResult.reportText, privacy: .public): \(line, privacy: .public)")
        }
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
    var diagnosticCaseName: String { diagnosticStateCase.rawValue }

    var diagnosticStateCase: WatchedFolderScanScheduler.SchedulingStateCase {
        switch self {
        case .queuedNew: .queuedNew
        case .queuedSuspended: .queuedSuspended
        case .queuedSuspendedAndDirty: .queuedSuspendedAndDirty
        case .running: .running
        case .runningAndDirty: .runningAndDirty
        case .awaitingValidation: .awaitingValidation
        case .awaitingValidationAndDirty: .awaitingValidationAndDirty
        case .pendingResult: .pendingResult
        case .pendingResultAndDirty: .pendingResultAndDirty
        case .leasedResult: .leasedResult
        case .leasedResultAndDirty: .leasedResultAndDirty
        }
    }
}

extension WatchedFolderScanScheduler {
    enum SchedulingStateCase: String, Sendable {
        case absent
        case queuedNew
        case queuedSuspended
        case queuedSuspendedAndDirty
        case running
        case runningAndDirty
        case awaitingValidation
        case awaitingValidationAndDirty
        case pendingResult
        case pendingResultAndDirty
        case leasedResult
        case leasedResultAndDirty
    }
}
