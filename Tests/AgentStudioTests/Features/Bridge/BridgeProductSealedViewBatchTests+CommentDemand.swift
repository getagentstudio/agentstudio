import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeProductSealedViewBatchTests {
    @Test("a Comment batch captured before demand changes still seals under the same worktree handle")
    func commentDemandChangePreservesCapturedBatch() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        var open = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        open["subscription"] = ["subscriptionKind": "file.annotations"]
        open["subscriptionId"] = "comment-demand-seal"
        try await harness.openSubscription(open)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context
            )
        )
        let view = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-demand-seal", worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context
            )
        )
        let captured = BridgeProductCommentCatalogBatch(
            handle: view.handle, scopeRevision: 0, baseRevision: 0,
            targetRevision: 1, puts: [], deletes: []
        )
        let requestBytes = try JSONSerialization.data(
            withJSONObject: [
                "kind": "subscription.setScope", "wireVersion": 2,
                "paneSessionId": "pane-session-1", "workerInstanceId": "worker-instance-1",
                "requestId": "comment-demand-seal-scope", "requestSequence": 3,
                "subscriptionId": "comment-demand-seal", "subscriptionKind": "file.annotations",
                "domain": view.viewDomain.domain.rawValue, "handle": view.handle,
                "incarnation": view.viewDomain.incarnation, "scopeRevision": 1,
                "scope": ["kind": "comment", "worktreeId": "worktree-1", "sessionIds": ["session-1"]],
            ] as [String: Any])
        let request = try BridgeProductStrictJSON.decode(BridgeProductViewScopeRequest.self, from: requestBytes)
        #expect(
            await harness.session.acceptViewScope(request, productAdmission: harness.productAdmission.context) == nil)

        #expect(
            try await harness.session.sealCommentCatalogBatch(
                subscriptionId: "comment-demand-seal", catalogBatch: captured, mode: .snapshot,
                productAdmission: harness.productAdmission.context
            ) == .completed)
        let wrongWorktreeBytes = try JSONSerialization.data(
            withJSONObject: [
                "kind": "subscription.setScope", "wireVersion": 2,
                "paneSessionId": "pane-session-1", "workerInstanceId": "worker-instance-1",
                "requestId": "comment-demand-seal-wrong-worktree", "requestSequence": 4,
                "subscriptionId": "comment-demand-seal", "subscriptionKind": "file.annotations",
                "domain": view.viewDomain.domain.rawValue, "handle": view.handle,
                "incarnation": view.viewDomain.incarnation, "scopeRevision": 2,
                "scope": ["kind": "comment", "worktreeId": "worktree-2", "sessionIds": []],
            ] as [String: Any])
        let wrongWorktree = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self, from: wrongWorktreeBytes
        )
        #expect(
            await harness.session.acceptViewScope(
                wrongWorktree, productAdmission: harness.productAdmission.context
            ) == .invalidRequest)
        try await harness.closeProducer(lease)
    }
}
