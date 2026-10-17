import Foundation
import Synchronization

/// Synchronous currency shared by the reconciler and its MainActor writer.
final class BridgeFileSurfaceOutcomeCurrency: Sendable {
    private let currentAttemptNonce = Mutex<UUID?>(nil)

    func replace(with attempt: BridgeFileSurfaceReconciler.Attempt) {
        currentAttemptNonce.withLock { $0 = attempt.nonce }
    }

    func retire() {
        currentAttemptNonce.withLock { $0 = nil }
    }

    func retire(ifCurrent attempt: BridgeFileSurfaceReconciler.Attempt) {
        currentAttemptNonce.withLock { currentNonce in
            if currentNonce == attempt.nonce { currentNonce = nil }
        }
    }

    func withCurrentAttempt(_ attempt: BridgeFileSurfaceReconciler.Attempt, write: () -> Void) {
        currentAttemptNonce.withLock { currentNonce in
            guard currentNonce == attempt.nonce else { return }
            write()
        }
    }
}

/// Keeps the original attempt and File authority through the publication hop.
struct BridgeFileSurfaceOutcomeApplication: Sendable {
    let failure: BridgePaneProductFileRefreshFailure?
    let attempt: BridgeFileSurfaceReconciler.Attempt
    let fileAuthorityAdmission: BridgePaneRefreshWorkAdmission
    let currency: BridgeFileSurfaceOutcomeCurrency

    @MainActor
    func apply(_ write: (BridgePaneProductFileRefreshFailure?) -> Void) {
        _ = fileAuthorityAdmission.withValidAdmission {
            currency.withCurrentAttempt(attempt) { write(failure) }
        }
    }
}
