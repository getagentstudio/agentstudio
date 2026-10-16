import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product sealed native batch")
struct BridgeProductSealedViewBatchTests {
    @Test("Review demand reprioritization preserves a sealed in-flight snapshot")
    func reviewScopeChangePreservesInFlightBatch() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        )
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context
            )
        )
        let initialScope = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"review-in-flight-scope-1","requestSequence":3,\
                "subscriptionId":"review-subscription-1","subscriptionKind":"review.metadata",\
                "domain":"default","handle":"review-in-flight-handle","incarnation":"review-in-flight-incarnation",\
                "scopeRevision":1,"scope":{"kind":"review","interests":[]}}
                """.utf8
            )
        )
        #expect(
            await harness.session.acceptViewScope(initialScope, productAdmission: harness.productAdmission.context)
                == nil)
        let publication = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: nil,
                publicationId: reviewMetadataTestPublicationId,
                revision: 1,
                desiredComparison: nil,
                desiredStatus: .ready,
                displayedPackage: makeReviewPackage(itemCount: 0),
                displayedPublicationId: reviewMetadataTestPublicationId,
                displayedComparison: nil
            )
        )
        #expect(
            try await harness.session.sealReviewSnapshot(
                subscriptionId: initialScope.subscriptionId,
                snapshot: .init(targetRevision: 1, publication: publication, items: []),
                productAdmission: harness.productAdmission.context
            )
        )
        let viewDomain = BridgeProductViewDomainKey(
            viewId: initialScope.subscriptionId, domain: .singleDomain, incarnation: initialScope.incarnation
        )
        try #require(await harness.session.viewSenderState.hasActiveEmission(for: viewDomain))
        let reprioritizedScope = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"review-in-flight-scope-2","requestSequence":4,\
                "subscriptionId":"review-subscription-1","subscriptionKind":"review.metadata",\
                "domain":"default","handle":"review-in-flight-handle","incarnation":"review-in-flight-incarnation",\
                "scopeRevision":2,"scope":{"kind":"review","interests":[{"lane":"visible","itemIds":["a"]}]}}
                """.utf8
            )
        )
        #expect(
            await harness.session.acceptViewScope(
                reprioritizedScope, productAdmission: harness.productAdmission.context) == nil)
        try #require(await harness.session.viewSenderState.hasActiveEmission(for: viewDomain))
        var kinds: [String] = []
        for _ in 0..<3 {
            let delivery = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease, from: harness.session, productAdmission: harness.productAdmission.context
                )
            )
            kinds.append(try #require(BridgeProductMetadataFrameDecoder().append(delivery.data).first).kind)
        }
        #expect(kinds == ["subscription.batchBegin", "subscription.batchPart", "subscription.batchComplete"])
        try await harness.closeProducer(lease)
    }

    @Test("Comment producer receives the page's accepted E4 handle")
    func commentProducerWaitsForAcceptedScope() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        var open = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        open["subscription"] = ["subscriptionKind": "file.annotations"]
        open["subscriptionId"] = "comment-scope-wait-1"
        try await harness.openSubscription(open)
        let waiting = Task {
            await harness.session.awaitAcceptedViewScope(subscriptionId: "comment-scope-wait-1")
        }
        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"comment-scope-wait-request",\
                "requestSequence":3,"subscriptionId":"comment-scope-wait-1",\
                "subscriptionKind":"file.annotations","domain":"default",\
                "handle":"page-comment-handle-1","incarnation":"page-comment-incarnation-1",\
                "scopeRevision":1,"scope":{"kind":"comment","worktreeId":"00000000-0000-7000-8000-000000000011",\
                "sessionIds":[]}}
                """.utf8
            )
        )
        #expect(
            await harness.session.acceptViewScope(scopeRequest, productAdmission: harness.productAdmission.context)
                == nil)
        let accepted = try #require(await waiting.value)
        #expect(accepted.handle == "page-comment-handle-1")
        #expect(accepted.revision == 1)
        #expect(accepted.viewDomain.incarnation == "page-comment-incarnation-1")
        try await harness.closeProducer(lease)
    }

    @Test("a Review snapshot follows an empty Comment batch on the same metadata producer")
    func reviewSnapshotFollowsCommentBatch() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        var commentOpen = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        commentOpen["subscription"] = ["subscriptionKind": "file.annotations"]
        commentOpen["subscriptionId"] = "comment-subscription-before-review"
        try await harness.openSubscription(commentOpen)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context
            )
        )
        let commentView = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-subscription-before-review",
                worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(
            try await harness.session.sealCommentCatalogBatch(
                subscriptionId: "comment-subscription-before-review",
                catalogBatch: .init(
                    handle: commentView.handle, scopeRevision: 0, baseRevision: 0,
                    targetRevision: 1, puts: [], deletes: []
                ),
                mode: .snapshot,
                productAdmission: harness.productAdmission.context
            ) == .completed
        )
        var kinds: [String] = []
        for _ in 0..<2 {
            let delivery = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease, from: harness.session, productAdmission: harness.productAdmission.context
                )
            )
            kinds.append(try #require(BridgeProductMetadataFrameDecoder().append(delivery.data).first).kind)
        }

        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 3, epoch: 2)
        )
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context
            )
        )
        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"review-scope-after-comment","requestSequence":4,\
                "subscriptionId":"review-subscription-1","subscriptionKind":"review.metadata",\
                "domain":"default","handle":"review-handle-after-comment","incarnation":"review-incarnation-after-comment",\
                "scopeRevision":1,"scope":{"kind":"review","interests":[]}}
                """.utf8
            )
        )
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest, productAdmission: harness.productAdmission.context
            ) == nil
        )
        let package = makeReviewPackage(itemCount: 0)
        let publication = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: nil,
                publicationId: reviewMetadataTestPublicationId,
                revision: 1,
                desiredComparison: nil,
                desiredStatus: .ready,
                displayedPackage: package,
                displayedPublicationId: reviewMetadataTestPublicationId,
                displayedComparison: nil
            )
        )
        #expect(
            try await harness.session.sealReviewSnapshot(
                subscriptionId: scopeRequest.subscriptionId,
                snapshot: .init(targetRevision: 1, publication: publication, items: []),
                productAdmission: harness.productAdmission.context
            )
        )
        for _ in 0..<3 {
            let delivery = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease, from: harness.session, productAdmission: harness.productAdmission.context
                )
            )
            kinds.append(try #require(BridgeProductMetadataFrameDecoder().append(delivery.data).first).kind)
        }
        #expect(
            kinds == [
                "subscription.batchBegin", "subscription.batchComplete",
                "subscription.batchBegin", "subscription.batchPart", "subscription.batchComplete",
            ])
        try await harness.closeProducer(lease)
    }

    @Test("a keyed Review publication reaches the live metadata producer as one sealed snapshot")
    func sealedReviewBatchReachesProducerPump() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        )
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"review-scope-test","requestSequence":3,\
                "subscriptionId":"review-subscription-1","subscriptionKind":"review.metadata",\
                "domain":"default","handle":"review-handle-1","incarnation":"review-incarnation-1",\
                "scopeRevision":1,"scope":{"kind":"review","interests":[]}}
                """.utf8
            )
        )
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest,
                productAdmission: harness.productAdmission.context
            ) == nil
        )
        let package = makeReviewPackage(itemCount: 0)
        let publication = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: nil,
                publicationId: reviewMetadataTestPublicationId,
                revision: 1,
                desiredComparison: nil,
                desiredStatus: .ready,
                displayedPackage: package,
                displayedPublicationId: reviewMetadataTestPublicationId,
                displayedComparison: nil
            )
        )
        #expect(
            try await harness.session.sealReviewSnapshot(
                subscriptionId: scopeRequest.subscriptionId,
                snapshot: .init(targetRevision: 1, publication: publication, items: []),
                productAdmission: harness.productAdmission.context
            )
        )
        var kinds: [String] = []
        for _ in 0..<3 {
            let queued = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease,
                    from: harness.session,
                    productAdmission: harness.productAdmission.context
                )
            )
            kinds.append(try #require(BridgeProductMetadataFrameDecoder().append(queued.data).first).kind)
        }
        #expect(kinds == ["subscription.batchBegin", "subscription.batchPart", "subscription.batchComplete"])
        try await harness.closeProducer(lease)
    }

    @Test("native Comment view scope carries the admitted worktree before publication")
    func nativeCommentViewCarriesAdmittedWorktree() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        var open = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        open["subscription"] = ["subscriptionKind": "file.annotations"]
        open["subscriptionId"] = "comment-subscription-1"
        try await harness.openSubscription(open)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context
            )
        )

        let view = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-subscription-1",
                worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(view.viewDomain.viewId == "comment-subscription-1")
        #expect(
            view.scope
                == .object([
                    "kind": .string("comment"), "sessionIds": .array([]), "worktreeId": .string("worktree-1"),
                ]))
        #expect(!view.handle.isEmpty)
        let second = try await harness.session.openNativeCommentView(
            subscriptionId: "unknown-subscription",
            worktreeID: "worktree-2",
            productAdmission: harness.productAdmission.context
        )
        #expect(second?.handle == nil)
        let replacement = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-subscription-1",
                worktreeID: "worktree-2",
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(replacement.handle != view.handle)
        #expect(
            replacement.scope
                == .object([
                    "kind": .string("comment"), "sessionIds": .array([]), "worktreeId": .string("worktree-2"),
                ]))
        #expect(
            try await harness.session.sealCommentCatalogBatch(
                subscriptionId: "comment-subscription-1",
                catalogBatch: .init(
                    handle: replacement.handle, scopeRevision: 0, baseRevision: 0,
                    targetRevision: 1, puts: [], deletes: []
                ),
                mode: .snapshot,
                productAdmission: harness.productAdmission.context
            ) == .completed)
        let replacementBegin = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease, from: harness.session, productAdmission: harness.productAdmission.context
            ))
        #expect(
            try BridgeProductMetadataFrameDecoder().append(replacementBegin.data).first?.kind
                == "subscription.batchBegin")
        #expect(
            await harness.session.viewScopeByDomain.keys.filter {
                $0.viewId == "comment-subscription-1"
            }.count == 1
        )
        try await harness.closeProducer(lease)
    }

    @Test("an empty native Comment snapshot reaches the metadata producer")
    func emptyCommentSnapshotReachesProducer() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        var open = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        open["subscription"] = ["subscriptionKind": "file.annotations"]
        open["subscriptionId"] = "comment-subscription-snapshot"
        try await harness.openSubscription(open)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let view = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-subscription-snapshot",
                worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context
            )
        )

        #expect(
            try await harness.session.sealCommentCatalogBatch(
                subscriptionId: "comment-subscription-snapshot",
                catalogBatch: .init(
                    handle: view.handle,
                    scopeRevision: 0,
                    baseRevision: 0,
                    targetRevision: 1,
                    puts: [],
                    deletes: []
                ),
                mode: .snapshot,
                productAdmission: harness.productAdmission.context
            ) == .completed
        )
        var frameKinds: [String] = []
        for _ in 0..<2 {
            let frame = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease,
                    from: harness.session,
                    productAdmission: harness.productAdmission.context
                )
            )
            frameKinds.append(try #require(BridgeProductMetadataFrameDecoder().append(frame.data).first).kind)
        }
        #expect(frameKinds == ["subscription.batchBegin", "subscription.batchComplete"])
        try await harness.closeProducer(lease)
    }

    @Test("retiring a Comment view releases its suspended emission wait")
    func retiredCommentViewReleasesEmissionWaiter() async throws {
        let registered = HeldStep<BridgeProductViewDomainKey>("commentEmissionWaitRegistered")
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            viewEmissionWaiterRegistrationObserver: { viewDomain in
                Task { try? await registered.arrive(viewDomain) }
            }
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        var open = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        open["subscription"] = ["subscriptionKind": "file.annotations"]
        open["subscriptionId"] = "comment-subscription-retire"
        try await harness.openSubscription(open)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let view = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-subscription-retire",
                worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(
            try await harness.session.sealCommentCatalogBatch(
                subscriptionId: "comment-subscription-retire",
                catalogBatch: .init(
                    handle: view.handle,
                    scopeRevision: 0,
                    baseRevision: 0,
                    targetRevision: 1,
                    puts: [],
                    deletes: []
                ),
                mode: .snapshot,
                productAdmission: harness.productAdmission.context
            ) == .completed
        )
        let waiting = Task {
            await harness.session.awaitViewEmissionCompletion(
                for: view.viewDomain,
                handle: view.handle
            )
        }
        #expect(try await registered.firstArrival() == view.viewDomain)

        await harness.session.closeViewDomains(subscriptionId: "comment-subscription-retire")
        #expect(await waiting.value == .retired)
        #expect(await harness.session.viewEmissionWaiterByDomain.isEmpty)
        registered.release()
        try await harness.closeProducer(lease)
    }

    @Test("a same-handle resnapshot releases Comment emission without retiring its view")
    func commentResnapshotReleasesEmissionWaiter() async throws {
        let registered = HeldStep<BridgeProductViewDomainKey>("commentResnapshotWaitRegistered")
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            viewEmissionWaiterRegistrationObserver: { viewDomain in
                Task { try? await registered.arrive(viewDomain) }
            }
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        var open = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        open["subscription"] = ["subscriptionKind": "file.annotations"]
        open["subscriptionId"] = "comment-subscription-resnapshot"
        try await harness.openSubscription(open)
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let view = try #require(
            try await harness.session.openNativeCommentView(
                subscriptionId: "comment-subscription-resnapshot",
                worktreeID: "worktree-1",
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(
            try await harness.session.sealCommentCatalogBatch(
                subscriptionId: "comment-subscription-resnapshot",
                catalogBatch: .init(
                    handle: view.handle, scopeRevision: 0, baseRevision: 0,
                    targetRevision: 1, puts: [], deletes: []
                ),
                mode: .snapshot,
                productAdmission: harness.productAdmission.context
            ) == .completed
        )
        let waiting = Task {
            await harness.session.awaitViewEmissionCompletion(for: view.viewDomain, handle: view.handle)
        }
        #expect(try await registered.firstArrival() == view.viewDomain)

        let requestBytes = try JSONSerialization.data(withJSONObject: [
            "kind": "subscription.resnapshot",
            "wireVersion": 2,
            "paneSessionId": "pane-session-1",
            "workerInstanceId": "worker-instance-1",
            "requestId": "resnapshot-comment-1",
            "requestSequence": 3,
            "subscriptionId": "comment-subscription-resnapshot",
            "subscriptionKind": "file.annotations",
            "domain": view.viewDomain.domain.rawValue,
            "handle": view.handle,
            "incarnation": view.viewDomain.incarnation,
            "scopeRevision": 0,
        ])
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductViewResnapshotRequest.self,
            from: requestBytes
        )
        #expect(
            await harness.session.acceptViewResnapshot(
                request,
                productAdmission: harness.productAdmission.context
            ) == nil
        )
        #expect(await waiting.value == .resnapshotRequired)
        let currentViewScopes = await harness.session.viewScopeByDomain
        let pendingEmissionWaiters = await harness.session.viewEmissionWaiterByDomain
        #expect(currentViewScopes[view.viewDomain]?.handle == view.handle)
        #expect(pendingEmissionWaiters.isEmpty)
        registered.release()
        try await harness.closeProducer(lease)
    }

    @Test("a sealed File batch reaches the live metadata producer without per-frame waiting")
    func sealedFileBatchReachesProducerPump() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2))
        _ = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"file-scope-test","requestSequence":3,\
                "subscriptionId":"file-subscription-1","subscriptionKind":"file.metadata",\
                "domain":"default","handle":"file-handle-1","incarnation":"file-incarnation-1",\
                "scopeRevision":1,"scope":{"kind":"file","changeFilter":{"kind":"none"},"interests":[],"pathScope":[]}}
                """.utf8
            )
        )
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest,
                productAdmission: harness.productAdmission.context
            ) == nil
        )
        let snapshot = try nineRowFileSnapshot()
        try #require(
            try await harness.session.sealFileCapture(
                subscriptionId: scopeRequest.subscriptionId,
                snapshot: snapshot,
                scope: try #require(
                    await harness.session.acceptedViewScope(subscriptionId: scopeRequest.subscriptionId)),
                productAdmission: harness.productAdmission.context
            )
        )
        var deliveredKinds: [String] = []
        for _ in 0..<9 {
            let queued = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease,
                    from: harness.session,
                    productAdmission: harness.productAdmission.context
                )
            )
            let frames = try BridgeProductMetadataFrameDecoder().append(queued.data)
            deliveredKinds.append(try #require(frames.first).kind)
        }
        let acknowledgementBytes = Data(
            """
            {"kind":"subscription.acknowledge","wireVersion":2,"paneSessionId":"pane-session-1",\
            "workerInstanceId":"worker-instance-1","subscriptionId":"file-subscription-1",\
            "domain":"default","handle":"file-handle-1","incarnation":"file-incarnation-1",\
            "receivedThroughDeliverySequence":8}
            """.utf8
        )
        let acknowledgement = try BridgeProductStrictJSON.decode(
            BridgeProductViewAcknowledgementRequest.self,
            from: acknowledgementBytes
        )
        let acknowledged = await harness.session.acknowledgeViewReceipt(
            acknowledgement,
            exactRequestBytes: acknowledgementBytes,
            productAdmission: harness.productAdmission.context
        )
        _ = try #require(acknowledged)
        for _ in 0..<3 {
            let queued = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease,
                    from: harness.session,
                    productAdmission: harness.productAdmission.context
                )
            )
            let frames = try BridgeProductMetadataFrameDecoder().append(queued.data)
            deliveredKinds.append(try #require(frames.first).kind)
        }
        #expect(deliveredKinds.first == "subscription.batchBegin")
        #expect(deliveredKinds.dropFirst().dropLast().allSatisfy { $0 == "subscription.batchPart" })
        #expect(deliveredKinds.last == "subscription.batchComplete")
        #expect(deliveredKinds.count == snapshot.records.count + 3)
        try await assertAbandonedFileReceiptAfterResnapshot(
            harness: harness, scopeRequest: scopeRequest, recordCount: snapshot.records.count
        )
        try await harness.closeProducer(lease)
    }

    private func assertAbandonedFileReceiptAfterResnapshot(
        harness: BridgeProductSessionLifecycleHarness,
        scopeRequest: BridgeProductViewScopeRequest,
        recordCount: Int
    ) async throws {
        let resnapshotBytes = try JSONSerialization.data(withJSONObject: [
            "kind": "subscription.resnapshot",
            "wireVersion": 2,
            "paneSessionId": "pane-session-1",
            "workerInstanceId": "worker-instance-1",
            "requestId": "file-resnapshot-after-credits",
            "requestSequence": 4,
            "subscriptionId": scopeRequest.subscriptionId,
            "subscriptionKind": "file.metadata",
            "domain": "default",
            "handle": scopeRequest.handle,
            "incarnation": scopeRequest.incarnation,
            "scopeRevision": scopeRequest.scopeRevision,
        ])
        let resnapshot = try BridgeProductStrictJSON.decode(
            BridgeProductViewResnapshotRequest.self, from: resnapshotBytes
        )
        #expect(
            await harness.session.acceptViewResnapshot(
                resnapshot, productAdmission: harness.productAdmission.context
            ) == nil)
        let abandonedReceiptBytes = try JSONSerialization.data(withJSONObject: [
            "kind": "subscription.acknowledge",
            "wireVersion": 2,
            "paneSessionId": "pane-session-1",
            "workerInstanceId": "worker-instance-1",
            "subscriptionId": scopeRequest.subscriptionId,
            "domain": "default",
            "handle": scopeRequest.handle,
            "incarnation": scopeRequest.incarnation,
            "receivedThroughDeliverySequence": recordCount + 1,
        ])
        let abandonedReceipt = try BridgeProductStrictJSON.decode(
            BridgeProductViewAcknowledgementRequest.self, from: abandonedReceiptBytes
        )
        #expect(
            await harness.session.acknowledgeViewReceipt(
                abandonedReceipt,
                exactRequestBytes: abandonedReceiptBytes,
                productAdmission: harness.productAdmission.context
            ) != nil)
    }

    @Test("File snapshot seals canonical rows and tombstones without changing their revisions")
    func fileSnapshotPreservesIndexedRecords() throws {
        let row = BridgeWorktreeTreeRowMetadata(
            rowId: "row-source-1",
            path: "Tests/File.swift",
            name: "File.swift",
            parentPath: "Tests",
            depth: 1,
            isDirectory: false,
            fileId: "file-source-1",
            fileClass: .test,
            sizeBytes: 8,
            lineCount: 2,
            changeStatus: "modified"
        )
        let snapshot = BridgeWorktreeFileKeyedSnapshot(
            isEnumerationComplete: true,
            memberStatus: try fileMemberStatusFixture(),
            records: [.init(key: "/workspace/Tests/File.swift", revision: 2, row: row, descriptorOutcome: nil)],
            targetRevision: 3,
            tombstoneRevisionByKey: ["/workspace/Tests/Old.swift": 3],
            absenceFloorRevisionByRange: [:]
        )
        let batch = try BridgeProductFileViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: .init(viewId: "file-subscription-1", domain: .singleDomain, incarnation: "default"),
                handle: "file-handle-1",
                scopeRevision: 1,
                scope: .object([
                    "kind": .string("file"),
                    "changeFilter": .object(["kind": .string("none")]),
                    "interests": .array([]),
                    "pathScope": .array([]),
                ]),
                firstDeliverySequence: 1,
                snapshot: snapshot
            )
        )
        #expect(batch.targetRevision == 3)
        #expect(batch.parts.count == 3)
        guard case .put(let key, let revision, let value) = batch.parts[0] else {
            Issue.record("Expected File row put")
            return
        }
        #expect(key == "/workspace/Tests/File.swift")
        #expect(revision == 2)
        let decoded = try JSONDecoder().decode(BridgeProductFileBatchRow.self, from: JSONEncoder().encode(value))
        #expect(decoded.fileClass == .test)
        #expect(decoded.sizeBytes == 8)
        #expect(decoded.lineCount == 2)
        #expect(decoded.rowId == row.rowId)
        guard case .delete(let deletedKey, let deletionRevision) = batch.parts[1] else {
            Issue.record("Expected File tombstone")
            return
        }
        #expect(deletedKey == "/workspace/Tests/Old.swift")
        #expect(deletionRevision == 3)
        guard case .put(let statusKey, let statusRevision, let statusValue) = batch.parts[2] else {
            Issue.record("Expected File member status")
            return
        }
        #expect(statusKey == BridgeProductFileMemberStatusRecord.recordKey)
        #expect(statusRevision == 1)
        #expect(
            try JSONDecoder().decode(BridgeProductFileMemberStatusRecord.self, from: JSONEncoder().encode(statusValue))
                .status == .loading
        )
    }

}

private func nineRowFileSnapshot() throws -> BridgeWorktreeFileKeyedSnapshot {
    BridgeWorktreeFileKeyedSnapshot(
        isEnumerationComplete: true,
        memberStatus: try fileMemberStatusFixture(),
        records: (1...9).map { ordinal in
            let path = "file-\(ordinal).swift"
            return .init(
                key: "/workspace/\(path)",
                revision: 1,
                row: .init(
                    rowId: "row-\(ordinal)",
                    path: path,
                    name: path,
                    parentPath: nil,
                    depth: 0,
                    isDirectory: false,
                    fileId: "file-\(ordinal)",
                    fileClass: .source,
                    sizeBytes: 1,
                    lineCount: nil,
                    changeStatus: nil
                ),
                descriptorOutcome: nil
            )
        },
        targetRevision: 1,
        tombstoneRevisionByKey: [:],
        absenceFloorRevisionByRange: [:]
    )
}

private func fileMemberStatusFixture() throws -> BridgeWorktreeFileKeyedMemberStatus {
    let source = try BridgeProductFileSourceIdentity(
        repoId: "00000000-0000-4000-8000-000000000001",
        rootRevisionToken: nil,
        sourceCursor: "source-cursor-1",
        sourceId: "source-1",
        subscriptionGeneration: 1,
        worktreeId: "00000000-0000-4000-8000-000000000002"
    )
    return .init(record: .init(source: source), revision: 1)
}
