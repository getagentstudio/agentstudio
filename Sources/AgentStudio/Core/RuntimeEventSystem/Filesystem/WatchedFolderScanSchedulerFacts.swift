import AgentStudioInfrastructure

/// One validation request retained by the scheduler, including its exact scan identity.
package struct WatchedFolderScanValidationScope: Hashable, Sendable {
    package let registration: FSEventRegistrationToken
    package let scanRunGeneration: UInt64
    package let requestID: RepoDiscoveryValidationRequestID
}

package enum WatchedFolderScanValidationSettlement: Equatable, Sendable {
    case finished
    case timedOut
    case cancelled
}

/// Synchronous observations of scheduler custody, never runtime bus events.
package enum WatchedFolderScanSchedulerFact: Equatable, Sendable {
    case validationParked
    case validationResubmitted
    case validationSettled(WatchedFolderScanValidationSettlement)
    case shutdownAwaitingAdmission
    case validationDiscardedDuringShutdown
}

package typealias WatchedFolderScanSchedulerFactSink =
    @Sendable (WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact) -> Void
