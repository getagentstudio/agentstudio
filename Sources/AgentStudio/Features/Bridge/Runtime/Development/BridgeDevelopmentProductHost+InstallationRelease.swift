import Foundation

extension BridgeDevelopmentProductHost {
    /// An acknowledgement is stronger than the client's local stream abort:
    /// the installation is fenced and its server-side stream claims are gone.
    package func releaseInstallation(
        _ request: BridgeDevelopmentInstallationReleaseRequest,
        presentedCapability: String
    ) async throws {
        let expected = productSessionOwner.installationFenceProjection.snapshot
        guard !isShutdown, let fence = expected.installation,
            let installation = await productSessionOwner.activeInstallation,
            installation.installationFence == fence
        else { throw BridgeDevelopmentInstallationReleaseError.installationMismatch }
        guard installation.session.capabilityAuthenticator.matches(presentedCapability) else {
            throw BridgeDevelopmentInstallationReleaseError.unauthorized
        }
        guard installation.bootstrap.paneSessionId == request.paneSessionId,
            installation.bootstrap.workerInstanceId == request.workerInstanceId,
            productSessionOwner.installationFenceProjection.snapshot == expected, !isShutdown
        else { throw BridgeDevelopmentInstallationReleaseError.installationMismatch }

        // Reuse bootstrap ordering as well as the existing stream-drain waiter.
        // A successor cannot activate while this release joins the old claims,
        // so the all-stream drain cannot accidentally wait for successor work.
        let precedingTransition = bootstrapTransitionTail
        let transition = Task { [self] in
            if let precedingTransition { await precedingTransition.value }
            try Task.checkCancellation()
            guard !isShutdown, productSessionOwner.installationFenceProjection.snapshot == expected else {
                throw BridgeDevelopmentInstallationReleaseError.installationMismatch
            }
            expected.close()
            let retirement = await productSessionOwner.retire(reason: .pageReload, installation: expected)
            guard retirement == .retired else { throw BridgeDevelopmentInstallationReleaseError.releaseFailed }
            await productSessionOwner.schemeRouter.waitForStreamClaimDrain()
            try Task.checkCancellation()
            guard await productSessionOwner.schemeRouter.metadataStreamHasEnded(for: request.workerInstanceId) else {
                throw BridgeDevelopmentInstallationReleaseError.releaseFailed
            }
        }
        bootstrapTransitionTail = Task { _ = try? await transition.value }
        try await withTaskCancellationHandler {
            try await transition.value
        } onCancel: {
            transition.cancel()
        }
    }
}
