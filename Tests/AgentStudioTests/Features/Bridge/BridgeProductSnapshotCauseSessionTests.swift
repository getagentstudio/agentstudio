import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge snapshot cause across held native sealing")
struct BridgeProductSnapshotCauseSessionTests {
    @Test("a Review snapshot held behind coverage consumes the owed open cause")
    func heldReviewSnapshotCarriesOpen() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1))
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context))
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"held-review-scope","requestSequence":3,\
                "subscriptionId":"review-subscription-1","subscriptionKind":"review.metadata","domain":"default",\
                "handle":"review-handle","incarnation":"review-incarnation","scopeRevision":1,\
                "scope":{"kind":"review","interests":[]}}
                """.utf8))
        #expect(
            await harness.session.acceptViewScope(request, productAdmission: harness.productAdmission.context) == nil)
        let domain = BridgeProductViewDomainKey(
            viewId: request.subscriptionId, domain: .singleDomain, incarnation: request.incarnation)
        let publicationId = UUIDv7.generate()
        let publication = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: nil, publicationId: publicationId, revision: 1,
                desiredComparison: nil, desiredStatus: .ready, displayedPackage: makeReviewPackage(itemCount: 0),
                displayedPublicationId: publicationId, displayedComparison: nil))
        let coverage = try BridgeProductSealedViewBatch(
            viewDomain: domain, producerScanGeneration: 1, handle: request.handle, subscriptionKind: .reviewMetadata,
            scopeRevision: 1, baseRevision: 0, targetRevision: 0, mode: .coverage, publicationId: publicationId,
            scope: request.scope, coveredScope: request.scope, requiresCollection: nil,
            firstDeliverySequence: 1, parts: [])
        #expect(try await harness.session.sealViewBatch(coverage, productAdmission: harness.productAdmission.context))
        #expect(
            try await harness.session.sealReviewSnapshot(
                subscriptionId: request.subscriptionId,
                snapshot: .init(targetRevision: 1, publication: publication, items: []),
                productAdmission: harness.productAdmission.context))
        #expect(await harness.session.pendingReviewSnapshotByViewDomain[domain] != nil)
        var frames: [BridgeProductMetadataFrame] = []
        for _ in 0..<5 {
            let delivery = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease, from: harness.session, productAdmission: harness.productAdmission.context))
            frames.append(try #require(BridgeProductMetadataFrameDecoder().append(delivery.data).first))
        }
        guard case .batch(.begin(let first)) = frames[0], case .batch(.begin(let held)) = frames[2] else {
            Issue.record("Expected coverage then the held Review snapshot")
            try await harness.closeProducer(lease)
            return
        }
        #expect(first.mode == .coverage)
        #expect(first.snapshotCause == nil)
        #expect(held.mode == .snapshot)
        #expect(held.snapshotCause == .open)
        #expect(await harness.session.pendingReviewSnapshotByViewDomain[domain] == nil)
        #expect(await harness.session.viewSnapshotRequired(subscriptionId: request.subscriptionId) == false)
        try await harness.closeProducer(lease)
    }
}
