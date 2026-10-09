import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Comment E3 open authority")
struct BridgeProductCommentOpenAuthorityTests {
    @Test("missing native Comment worktree refuses E3 before an accepted reply")
    func missingWorktreeRefusesCommentOpen() async throws {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await provider.metadataCoordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        var openObject = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        openObject["subscription"] = ["subscriptionKind": "file.annotations"]
        let request = try bridgeProductLifecycleControlRequest(openObject)

        let response = await provider.response(for: request, productAdmission: harness.productAdmission.context)

        guard case .requestError(let refusal) = response else {
            Issue.record("Missing Comment worktree yielded an accepted E3 response")
            try await harness.closeProducer(lease)
            await provider.closeAndDrain()
            return
        }
        #expect(refusal.code == .staleSource)
        #expect(refusal.retryable)
        #expect(refusal.nextExpectedRequestSequence == 3)
        try await harness.closeProducer(lease)
        await provider.closeAndDrain()
    }
}
