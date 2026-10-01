import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

/// Native composition fixtures own this worker lease. Live page carriers send
/// their own mode updates and must not call this step.
@MainActor
func showReviewInNativeFixture(
    _ controller: BridgePaneController,
    metadataProducerLease: BridgeProductProducerLease? = nil
) async throws {
    let installation = try #require(await controller.productSessionOwner.activeInstallation)
    let productAdmission = try #require(installation.productAdapter.acquireAdmission())
    if metadataProducerLease == nil {
        _ = try await installRefreshAdmissionMetadataProducer(
            installation: installation,
            productProvider: try #require(controller.productSchemeProvider),
            productAdmission: productAdmission
        )
    }
    // G2 admits Review builds from the page's accepted mode, not a native request.
    await sendPageActiveViewerMode(
        .review, controller: controller, productAdmission: productAdmission,
        sequence: (controller.activeViewerModeSignalState.lastSequence ?? 0) + 1
    )
    #expect(controller.isReviewShownByPage)
}

@MainActor
func beginInitialReviewInNativeFixture(
    _ controller: BridgePaneController,
    facts: BridgePaneReviewBuildAdmissionTrace,
    metadataProducerLease: BridgeProductProducerLease? = nil
) async throws -> BridgePaneReviewBuildAttemptOutcome {
    // G2 makes the accepted page mode the initial build trigger. Starting a
    // second direct load here would race the real scheduled attempt.
    try await showReviewInNativeFixture(controller, metadataProducerLease: metadataProducerLease)
    let attempt = try #require(controller.activeReviewRefreshTask)
    await attempt.value
    let outcome = try await facts.nextAttemptOutcome()
    try await facts.finish()
    return outcome
}
