import AgentStudioCore
import Foundation

@MainActor
extension BridgePaneController {
    func failCurrentReviewComparisonRefresh(
        _ reviewGeneration: BridgeReviewGeneration,
        failureKind: String,
        reservation: BridgePaneRefreshCatchUpReservation,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        productAdmission: BridgeProductAdmissionContext
    ) -> BridgePaneRefreshCatchUpOutcome {
        guard
            !Task.isCancelled,
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            productAdmission.withValidAdmission({ true }) == true,
            refreshAdmissionCoordinator.isRefreshPassCurrent(reservation),
            reviewGeneration == nextReviewGeneration
        else { return .stale }
        if let activeTarget = refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
            .activeTarget
        {
            refreshAdmissionCoordinator.beginAndFailReviewComparisonAttempt(
                activeTarget: activeTarget,
                reviewGeneration: reviewGeneration.rawValue,
                failureKind: failureKind,
                retryable: true
            )
            // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
            _ = scheduleProductPresentationPublication()
        } else {
            failReviewComparisonAttempt(
                reviewGeneration: reviewGeneration,
                failureKind: failureKind,
                retryable: true
            )
        }
        return .failed
    }

    func failReviewComparisonAttempt(
        reviewGeneration: BridgeReviewGeneration,
        failureKind: String,
        retryable: Bool
    ) {
        refreshAdmissionCoordinator.failReviewComparisonAttempt(
            reviewGeneration: reviewGeneration.rawValue,
            failureKind: failureKind,
            retryable: retryable
        )
        // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
        _ = scheduleProductPresentationPublication()
    }

    static func reviewPackageRefreshFailureKind(for error: any Error) -> String {
        if let providerFailure = error as? BridgeProviderFailure,
            case .providerUnavailable = providerFailure
        {
            return "providerUnavailable"
        }
        return reviewPackageLoadFailureSummary(for: error, stage: "package")
    }
}
