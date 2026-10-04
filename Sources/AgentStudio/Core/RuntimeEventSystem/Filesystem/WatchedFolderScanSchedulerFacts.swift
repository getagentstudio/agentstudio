import AgentStudioInfrastructure

/// One validation request retained by the scheduler, including its exact scan identity.
package struct WatchedFolderScanValidationScope: Hashable, Sendable {
    package let registration: FSEventRegistrationToken
    package let scanRunGeneration: UInt64
    package let requestID: RepoDiscoveryValidationRequestID
}

/// Synchronous observations of scheduler custody, never runtime bus events.
package enum WatchedFolderScanSchedulerFact: Equatable, Sendable {
    case validationParked
    case validationResubmitted
}

package typealias WatchedFolderScanSchedulerFactSink =
    @Sendable (WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact) -> Void
