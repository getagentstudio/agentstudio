/// Names the boundary that prevented a clean-continuity barrier from being prepared.
package enum GitCleanContinuityPrepareFailure: Sendable, Equatable {
    case unsupportedObservation
    case bindingPlanUnavailable
    case clientShutdown
    case registrationMissing
    case rootMismatch
    case replacementCreationFailed
    case shutdownDuringReplacementInstall
    case replacementInstallLost
    case sharedBindingInstallFailed
    case preFlushBarrierUnavailable
    case compositeStreamsUnavailable
    case streamFlushFailed
    case postFlushBarrierUnavailable
    case barrierChangedDuringFlush
    case compositeStreamsChangedDuringFlush
}

package enum GitCleanContinuityPrepareOutcome: Sendable, Equatable {
    case prepared(GitCleanContinuityBarrier)
    case unavailable(GitCleanContinuityPrepareFailure)

    /// Failed preparation retains the existing ordinary-status fallback.
    package var barrier: GitCleanContinuityBarrier? {
        guard case .prepared(let barrier) = self else { return nil }
        return barrier
    }
}
