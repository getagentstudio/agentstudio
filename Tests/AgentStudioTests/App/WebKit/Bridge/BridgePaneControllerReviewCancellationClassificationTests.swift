import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgePaneControllerTests {
    @Test("provider cancellation with current Review authority ends as retryable failure")
    func providerCancellationWithCurrentReviewAuthorityEndsAsRetryableFailure() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            initialContributionTarget: .branch(name: "main")
        )
        try await fixture.loadInitialReviewPackage()
        await fixture.reviewProvider.cancelNextReviewPackageBuild()

        fixture.controller.refreshAdmissionCoordinator.recordInvalidation(
            fileChangeset: fixture.makeChangeset(
                paths: ["Sources/App/ProviderCancelled.swift"],
                batchSequence: 202
            ),
            requiresReviewRefresh: true
        )
        let reservation = try #require(
            fixture.controller.refreshAdmissionCoordinator.reserveForegroundRefreshPass(for: .review)
        )
        let outcome = await fixture.controller.refreshCurrentReviewPackage(
            reservation: reservation,
            foregroundWorkAdmission: reservation.foregroundWorkAdmission,
            productAdmission: fixture.productAdmission
        )

        #expect(outcome == .failed)
        #expect(fixture.controller.paneState.diff.status == .ready)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"])
        #expect(
            fixture.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                .attempt
                == .unavailable(
                    failureKind: "loadFailed:package:cancelled",
                    retryable: true
                )
        )
        await fixture.finish()
    }
}
