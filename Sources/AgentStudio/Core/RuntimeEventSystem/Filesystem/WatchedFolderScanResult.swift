import AgentStudioInfrastructure
import Foundation

struct WatchedFolderScanRequest: Equatable, Sendable {
    let canonicalRoot: RegisteredRootDescriptor
    let cause: WatchedFolderScanCause
    let baselineMembershipRevision: UInt64
    let retainedCheckoutPaths: [URL]
    /// Reserved on the FilesystemActor before the request is submitted, so publication
    /// holds can tell which scans were requested before a hold was released.
    let submissionSequence: UInt64

    init(
        canonicalRoot: RegisteredRootDescriptor,
        cause: WatchedFolderScanCause,
        baselineMembershipRevision: UInt64 = 0,
        retainedCheckoutPaths: [URL] = [],
        submissionSequence: UInt64 = 0
    ) {
        self.canonicalRoot = canonicalRoot
        self.cause = cause
        self.baselineMembershipRevision = baselineMembershipRevision
        self.retainedCheckoutPaths = retainedCheckoutPaths
        self.submissionSequence = submissionSequence
    }

    var sourceID: FilesystemSourceID { canonicalRoot.sourceID }
}

enum WatchedFolderScanCause: Equatable, Sendable {
    case initialAdd
    case callback
    case manual
    case fallback
}

/// Narrow adapter around scanner-owned resumable state. The scheduler can advance or
/// cancel the opaque session, but it cannot inspect traversal state or inventory.
struct WatchedFolderScannerSessionPort: Sendable {
    let id: RepoScannerSessionID
    let advanceOneQuantum: @Sendable () async -> RepoScannerQuantumOutcome
    let cancel: @Sendable () -> RepoScannerSessionCancellationResult
    let consumeValidationCompletion:
        @Sendable (RepoScannerValidationCompletion) ->
            RepoScannerValidationCompletionConsumptionResult
}

struct ScheduledWatchedFolderScanResult: Equatable, Sendable {
    let resultID: WatchedFolderScanResultID
    let request: WatchedFolderScanRequest
    let demandCoverage: WatchedFolderScanDemandCoverage
    let scanRunGeneration: UInt64
    let scannerResult: RepoScannerResult
    let schedulingMetrics: WatchedFolderScanSchedulingMetrics
}

struct WatchedFolderScanSchedulingMetrics: Equatable, Sendable {
    let queueWaitDuration: Duration
    let quantumSelectionCount: UInt64
    let staleRegistrationDropCount: UInt64
    let staleScanRunDropCount: UInt64
    let followUpEvidence: WatchedFolderScanFollowUpEvidence
}

enum WatchedFolderScanFollowUpEvidence: Equatable, Sendable {
    case noFollowUp
    case dirtyFollowUpQueued
    case startedFromDirtyFollowUp
}

struct WatchedFolderScanResultID: Hashable, Sendable {
    let rawValue: UUID

    static func make() -> Self {
        Self(rawValue: UUIDv7.generate())
    }
}

struct WatchedFolderScanResultConsumerToken: Hashable, Sendable {
    let rawValue: UUID

    static func make() -> Self {
        Self(rawValue: UUIDv7.generate())
    }
}

struct WatchedFolderScanResultLeaseID: Hashable, Sendable {
    let rawValue: UUID

    static func make() -> Self {
        Self(rawValue: UUIDv7.generate())
    }
}

struct WatchedFolderScanResultLease: Equatable, Sendable {
    let leaseID: WatchedFolderScanResultLeaseID
    let result: ScheduledWatchedFolderScanResult
    let submittedDiagnostics: WatchedFolderScanScheduler.SubmittedLeaseDiagnostics

    // Diagnostic metadata does not change the lease's existing equality contract.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.leaseID == rhs.leaseID && lhs.result == rhs.result
    }
}

enum WatchedFolderScanResultConsumerBinding: Equatable, Sendable {
    case bound
    case alreadyBound
    case rejected(WatchedFolderScanResultConsumerBindingRejection)
}

enum WatchedFolderScanResultConsumerBindingRejection: Equatable, Sendable {
    case anotherConsumerBound
    case schedulerShutDown
}

enum WatchedFolderScanResultConsumerUnbindResult: Equatable, Sendable {
    case unbound
    case alreadyUnbound
    case rejected(WatchedFolderScanResultConsumerUnbindRejection)
}

enum WatchedFolderScanResultConsumerUnbindRejection: Equatable, Sendable {
    case consumerMismatch
    case leaseOutstanding(WatchedFolderScanResultLeaseID)
}

enum WatchedFolderScanResultLeaseWaitResult: Equatable, Sendable {
    case leased(WatchedFolderScanResultLease)
    case cancelled
    case consumerUnbound
    case schedulerShutDown
    case rejected(WatchedFolderScanResultLeaseWaitRejection)
}

enum WatchedFolderScanResultLeaseWaitRejection: Equatable, Sendable {
    case consumerMismatch
    case waiterAlreadyRegistered
    case leaseAlreadyOutstanding(WatchedFolderScanResultLeaseID)
    case leaseIdentityExhausted
}

enum WatchedFolderScanResultLeaseResolution: Equatable, Sendable {
    case transferred
    case retry
}

enum WatchedFolderScanResultLeaseResolutionResult: Equatable, Sendable {
    case transferred
    case queuedForRetry
    case staleResultDiscarded
    case rejected(WatchedFolderScanResultLeaseResolutionRejection)
}

enum WatchedFolderScanResultLeaseResolutionRejection: Equatable, Sendable {
    case consumerMismatch
    case noLeaseOutstanding
    case leaseMismatch(
        submitted: WatchedFolderScanResultLeaseID,
        current: WatchedFolderScanResultLeaseID
    )
}

struct WatchedFolderScanDemandGeneration: Comparable, Hashable, Sendable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WatchedFolderScanDemandID: Hashable, Sendable {
    let rawValue: UUID

    static func make() -> Self {
        Self(rawValue: UUIDv7.generate())
    }
}

struct WatchedFolderScanDemandCoverage: Equatable, Sendable {
    let registration: FSEventRegistrationToken
    let throughDemandGeneration: WatchedFolderScanDemandGeneration

    func covers(_ demandedCoverage: Self) -> Bool {
        registration == demandedCoverage.registration
            && throughDemandGeneration >= demandedCoverage.throughDemandGeneration
    }

    func covers(_ receipt: WatchedFolderScanDemandReceipt) -> Bool {
        covers(receipt.coverage)
    }
}

struct WatchedFolderScanDemandReceipt: Equatable, Sendable {
    let id: WatchedFolderScanDemandID
    let registration: FSEventRegistrationToken
    let demandGeneration: WatchedFolderScanDemandGeneration

    var coverage: WatchedFolderScanDemandCoverage {
        WatchedFolderScanDemandCoverage(
            registration: registration,
            throughDemandGeneration: demandGeneration
        )
    }
}

enum WatchedFolderScanSubmissionIntent: Equatable, Sendable {
    case tracked
    case untracked
}

enum WatchedFolderScanSubmissionDisposition: Equatable, Sendable {
    case started
    case queued
    case replacedQueued
    case markedRunningDirty
    case markedResultDirty
}

enum WatchedFolderScanSubmissionAcceptance: Equatable, Sendable {
    case tracked(
        receipt: WatchedFolderScanDemandReceipt,
        disposition: WatchedFolderScanSubmissionDisposition
    )
    case untracked(
        coverage: WatchedFolderScanDemandCoverage,
        disposition: WatchedFolderScanSubmissionDisposition
    )

    var coverage: WatchedFolderScanDemandCoverage {
        switch self {
        case .tracked(let receipt, _): receipt.coverage
        case .untracked(let coverage, _): coverage
        }
    }

    var disposition: WatchedFolderScanSubmissionDisposition {
        switch self {
        case .tracked(_, let disposition), .untracked(_, let disposition): disposition
        }
    }
}

enum WatchedFolderScanSubmissionRejection: Equatable, Sendable {
    case schedulerShutDown
    case staleRegistration(
        submitted: FSEventRegistrationToken,
        current: FSEventRegistrationToken
    )
    case registrationDescriptorMismatch(FSEventRegistrationToken)
    case demandGenerationExhausted(FilesystemSourceID)
    case scanRunGenerationExhausted(FilesystemSourceID)
}

enum WatchedFolderScanSubmissionResult: Equatable, Sendable {
    case accepted(WatchedFolderScanSubmissionAcceptance)
    case rejected(WatchedFolderScanSubmissionRejection)
}

enum WatchedFolderScanRetirementDisposition: Equatable, Sendable {
    case idle
    case queuedRemoved
    case runningInvalidated
    case runningInvalidatedAndDirtyDiscarded
    case awaitingValidationInvalidated
    case awaitingValidationInvalidatedAndDirtyDiscarded
    case pendingResultDiscarded
    case pendingResultAndDirtyDiscarded
    case leasedResultInvalidated
    case leasedResultInvalidatedAndDirtyDiscarded
    case alreadyRetired
}

enum WatchedFolderScanRetirementRejection: Equatable, Sendable {
    case schedulerShutDown
    case sourceNotRegistered(FilesystemSourceID)
    case registrationMismatch(
        submitted: FSEventRegistrationToken,
        current: FSEventRegistrationToken
    )
    case registrationDescriptorMismatch(FSEventRegistrationToken)
}

enum WatchedFolderScanRetirementResult: Equatable, Sendable {
    case retired(WatchedFolderScanRetirementDisposition)
    case rejected(WatchedFolderScanRetirementRejection)
}

enum WatchedFolderScanSchedulerConfigurationError: Error, Equatable, Sendable {
    case invalidMaximumConcurrentScans(Int)
}

enum WatchedFolderScanSchedulerStateSnapshot: Equatable, Sendable {
    case active(WatchedFolderScanSchedulerActiveState)
    case shuttingDown(WatchedFolderScanSchedulerCustodyState)
    case shutDown
}

struct WatchedFolderScanSchedulerActiveState: Equatable, Sendable {
    let ready: Int
    let activeQuanta: Int
    let awaitingValidations: Int
    let pendingResults: Int
    let leasedResults: Int
    let dirtyFollowUps: Int
    let resultCustodyHighWater: Int
}

struct WatchedFolderScanSchedulerCustodyState: Equatable, Sendable {
    let activeQuanta: Int
    let awaitingValidations: Int
    let pendingResults: Int
    let leasedResults: Int
}
