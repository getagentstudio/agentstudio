import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite(
    "Bridge Review metadata publication pacing",
    .serialized,
    .timeLimit(.minutes(1))
)
struct BridgeReviewMetadataPublicationPacingTests {
    @Test("slow receipt credits drain a 130-item sealed Review snapshot in order")
    func slowReceiptCreditsDrainSealedReviewSnapshot() async throws {
        let sourceAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 130)
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: sourceAdmission.context
        )
        _ = try await deliverReviewPackage(
            package, through: source, productAdmission: sourceAdmission.context
        )
        let capture = try #require(
            try await applyReviewViewDemand(
                through: source, itemIds: package.orderedItemIds,
                productAdmission: sourceAdmission.context
            )
        )

        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        )
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let scopeRequest = try reviewTestViewScopeRequest(
            itemIds: package.orderedItemIds, handle: "review-pacing-handle"
        )
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest, productAdmission: harness.productAdmission.context
            ) == nil
        )
        #expect(
            try await harness.session.sealReviewSnapshot(
                subscriptionId: scopeRequest.subscriptionId,
                snapshot: capture.snapshot,
                productAdmission: harness.productAdmission.context
            )
        )

        var deliveredKinds: [String] = []
        var deliveredKeys: [String] = []
        var receivedParts = 0
        for _ in 0..<(capture.snapshot.items.count + 3) {
            let queued = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease, from: harness.session,
                    productAdmission: harness.productAdmission.context
                )
            )
            let frame = try #require(BridgeProductMetadataFrameDecoder().append(queued.data).first)
            deliveredKinds.append(frame.kind)
            if frame.kind == "subscription.batchPart" {
                receivedParts += 1
                if case .batch(.part(let part)) = frame,
                    case .put(let key, _, _) = part.part
                {
                    deliveredKeys.append(key)
                }
                if receivedParts.isMultiple(of: 8) {
                    try await acknowledgePacingReviewParts(
                        through: receivedParts, scopeRequest: scopeRequest, harness: harness
                    )
                }
            }
        }
        #expect(receivedParts == 131)
        #expect(deliveredKinds.first == "subscription.batchBegin")
        #expect(deliveredKinds.dropFirst().dropLast().allSatisfy { $0 == "subscription.batchPart" })
        #expect(deliveredKinds.last == "subscription.batchComplete")
        #expect(deliveredKinds.count == 133)
        #expect(capture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
        #expect(Set(deliveredKeys) == Set(package.orderedItemIds + ["publication"]))
        try await harness.closeProducer(lease)
    }
}

private func acknowledgePacingReviewParts(
    through deliverySequence: Int,
    scopeRequest: BridgeProductViewScopeRequest,
    harness: BridgeProductSessionLifecycleHarness
) async throws {
    let receiptBytes = try JSONSerialization.data(withJSONObject: [
        "kind": "subscription.acknowledge",
        "wireVersion": 2,
        "paneSessionId": "pane-session-1",
        "workerInstanceId": "worker-instance-1",
        "subscriptionId": scopeRequest.subscriptionId,
        "domain": "default",
        "handle": scopeRequest.handle,
        "incarnation": scopeRequest.incarnation,
        "receivedThroughDeliverySequence": deliverySequence,
    ])
    let receipt = try BridgeProductStrictJSON.decode(
        BridgeProductViewAcknowledgementRequest.self, from: receiptBytes
    )
    #expect(
        await harness.session.acknowledgeViewReceipt(
            receipt, exactRequestBytes: receiptBytes,
            productAdmission: harness.productAdmission.context
        ) != nil
    )
}
