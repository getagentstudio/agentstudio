import Foundation
import WebKit
import os.log

private let bridgeProductBootstrapFailureLogger = Logger(
    subsystem: "com.agentstudio",
    category: "BridgeProductBootstrap"
)

/// Why native answered a product-session bootstrap request without a bootstrap. The web
/// page treats every reason as retryable within its own bounded re-request budget.
package enum BridgeProductSessionBootstrapFailureReason: String, Sendable {
    case activationFailed = "activation_failed"
    case candidatePreparationFailed = "candidate_preparation_failed"
    case deliveryFailed = "delivery_failed"
    case noActiveSession = "no_active_session"
    case retirementFailed = "retirement_failed"
}

package typealias BridgeProductSessionBootstrapFailureSink =
    @MainActor (
        _ page: WebPage,
        _ requestId: String,
        _ reason: BridgeProductSessionBootstrapFailureReason,
        _ contentWorld: WKContentWorld
    ) async throws -> Void

@MainActor
extension BridgePaneController {
    /// Replaces the active product session for a page that already received one. Returns
    /// nil after a current request's typed failure, supersession, or pane closure.
    func activateReplacementProductSessionInstallation(
        requestId: String,
        reason: BridgeReadyMessageHandler.ProductSessionBootstrapReason,
        productAdmission: BridgeProductAdmissionContext,
        predecessor: BridgeProductInstallationFenceSnapshot?
    ) async -> BridgeProductSessionInstallation? {
        guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return nil }
        do {
            let candidate = try await productSessionOwner.prepareCandidate(
                productAdmission: productAdmission
            )
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else {
                candidate.installationFence.close()
                _ = await productSessionOwner.rejectPreparedCandidateAfterAdmissionClose(candidate)
                return nil
            }
            let activation = await productSessionOwner.activatePreparedCandidate(
                candidate,
                productAdmission: productAdmission,
                replacing: predecessor
            )
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else {
                await retireProductBootstrapCandidateIfCurrent(candidate)
                return nil
            }
            guard activation == .activated,
                productSessionOwner.installationFenceProjection.snapshot.installation == candidate.installationFence,
                let installationAdmission = candidate.productAdapter.acquireAdmission(),
                installationAdmission.withValidAdmission({
                    surfaceSelectionAuthority.invalidateCurrentBinding()
                    return true
                }) == true
            else {
                setProductBootstrapConnectionErrorIfAdmitted(
                    productAdmission, requestId: requestId, predecessor: predecessor)
                await answerProductSessionBootstrapFailure(
                    requestId: requestId,
                    reason: .activationFailed,
                    productAdmission: productAdmission
                )
                return nil
            }
            return candidate
        } catch BridgePaneProductSessionOwnerError.ownerDisposed {
            return nil
        } catch {
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return nil }
            bridgeProductBootstrapFailureLogger.error("Bridge product session replacement failed: \(error)")
            setProductBootstrapConnectionErrorIfAdmitted(
                productAdmission, requestId: requestId, predecessor: predecessor)
            await answerProductSessionBootstrapFailure(
                requestId: requestId,
                reason: .candidatePreparationFailed,
                productAdmission: productAdmission
            )
            return nil
        }
    }

    /// Current requests receive typed failures; a superseded request has no page waiter.
    /// Answer delivery is best effort when the page itself is unreachable.
    func answerProductSessionBootstrapFailure(
        requestId: String,
        reason: BridgeProductSessionBootstrapFailureReason,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return }
        bridgeProductBootstrapFailureLogger.error(
            "Answering product session bootstrap requestId=\(requestId, privacy: .public) with failure reason=\(reason.rawValue, privacy: .public)"
        )
        do {
            let sink = productSessionBootstrapFailureSink
            let replyPage = page
            let replyWorld = bridgeWorld
            try await deliverProductBootstrapReply(requestId: requestId, admission: productAdmission) {
                try await sink(replyPage, requestId, reason, replyWorld)
            }
        } catch {
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return }
            bridgeProductBootstrapFailureLogger.error(
                "Product session bootstrap failure reply could not be delivered requestId=\(requestId, privacy: .public)"
            )
        }
    }

    static func dispatchProductSessionBootstrapFailure(
        page: WebPage,
        requestId: String,
        reason: BridgeProductSessionBootstrapFailureReason,
        contentWorld: WKContentWorld
    ) async throws {
        try await page.callJavaScript(
            """
            document.dispatchEvent(new CustomEvent('__bridge_product_session_bootstrap', {
                detail: {
                    requestId: requestId,
                    failure: { reason: reason }
                }
            }));
            """,
            arguments: [
                "requestId": requestId,
                "reason": reason.rawValue,
            ],
            contentWorld: contentWorld
        )
    }
}
