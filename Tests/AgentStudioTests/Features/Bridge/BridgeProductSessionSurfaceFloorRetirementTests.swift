import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session surface floor retirement")
struct BridgeProductSessionSurfaceFloorRetirementTests {
    @Test("a newer-epoch control ends each older subscription on its surface with one epoch_retired reset")
    func newerEpochControlRetiresOlderSubscriptions() async throws {
        // Arrange: a delivered Review subscription at epoch 7 and a File one at epoch 2.
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await openDeliveredSubscription(
            harness,
            object: bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 7),
            lease: lease,
            expectedFrameSequence: 1
        )
        try await openDeliveredSubscription(
            harness,
            object: bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 3, epoch: 2),
            lease: lease,
            expectedFrameSequence: 2
        )
        var replacementOpen = bridgeProductLifecycleReviewSubscriptionOpenObject(
            requestSequence: 4,
            epoch: 8
        )
        replacementOpen["subscriptionId"] = "review-subscription-2"
        let replacementRequest = try bridgeProductLifecycleControlRequest(replacementOpen)

        // Act: the Review replacement opens at epoch 8.
        let replacementToken = try #require(
            floorRetirementExecutionToken(try await harness.begin(replacementRequest))
        )

        // Assert: exactly one terminal, for the older Review subscription only.
        let retirementFrame = try await nextMetadataFrame(harness, lease: lease)
        #expect(retirementFrame.sequence == 3)
        #expect(
            retirementFrame.reset
                == .init(subscriptionId: "review-subscription-1", workerDerivationEpoch: 7, reason: .epochRetired)
        )
        #expect(
            await harness.session.takeFloorRetiredSubscriptions().map(\.subscriptionId)
                == ["review-subscription-1"]
        )
        #expect(await harness.session.takeFloorRetiredSubscriptions().isEmpty)
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: "review-subscription-1") == nil
        )
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: "file-subscription-1") != nil
        )
        #expect(try await deliveryIsGone(harness, lease: lease, subscriptionId: "review-subscription-1"))

        // Act: the control that advanced the floor completes.
        try await completeDeliveredOpen(
            harness,
            request: replacementRequest,
            token: replacementToken
        )

        // Assert: the new-epoch subscription the advance admitted is intact.
        let replacement = try #require(
            await harness.session.subscriptionSnapshot(subscriptionId: "review-subscription-2")
        )
        #expect(replacement.workerDerivationEpoch == 8)
        #expect(try await nextMetadataFrame(harness, lease: lease).sequence == 4)
        try await harness.closeProducer(lease)
    }

    @Test("a newer-epoch content request ends older subscriptions on its surface the same way")
    func newerEpochContentRetiresOlderSubscriptions() async throws {
        // Arrange: a delivered File subscription at epoch 2 and a Review one at epoch 7.
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await openDeliveredSubscription(
            harness,
            object: bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2),
            lease: lease,
            expectedFrameSequence: 1
        )
        try await openDeliveredSubscription(
            harness,
            object: bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 3, epoch: 7),
            lease: lease,
            expectedFrameSequence: 2
        )

        // Act: File content at epoch 3 registers.
        let registration = await harness.session.registerContentProducer(
            request: try bridgeProductFileContentRequest(
                identitySuffix: "floor-retirement",
                workerDerivationEpoch: 3
            ),
            productAdmission: harness.productAdmission.context
        ) { _ in }

        // Assert
        let contentLease = try bridgeProductAcceptedLease(registration)
        let retirementFrame = try await nextMetadataFrame(harness, lease: lease)
        #expect(
            retirementFrame.reset
                == .init(subscriptionId: "file-subscription-1", workerDerivationEpoch: 2, reason: .epochRetired)
        )
        #expect(
            await harness.session.takeFloorRetiredSubscriptions().map(\.subscriptionId)
                == ["file-subscription-1"]
        )
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: "review-subscription-1") != nil
        )
        #expect(try await deliveryIsGone(harness, lease: lease, subscriptionId: "file-subscription-1"))
        #expect((await harness.session.snapshot).workerDerivationEpochBySurface[.file] == 3)
        _ = await harness.session.stopProducer(contentLease)
        try await harness.closeProducer(lease)
    }

    @Test("a resync that advances the floor reports the older subscription for reopen at the new epoch")
    func resyncAdvanceReportsOlderSubscriptionThroughReconciliation() async throws {
        // Arrange: a delivered Review subscription at epoch 7; the worker claims epoch 8.
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        try await openDeliveredSubscription(
            harness,
            object: bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 7),
            lease: lease,
            expectedFrameSequence: 1
        )
        let resyncRequest = try bridgeProductLifecycleControlRequest([
            "activeSubscriptions": [
                [
                    "subscriptionId": "review-subscription-1",
                    "subscriptionKind": "review.metadata",
                    "workerDerivationEpoch": 8,
                ]
            ],
            "kind": "workerSession.resync",
            "lastAcceptedRequestSequence": 2,
            "lastAcceptedStreamSequence": 1,
            "paneSessionId": "pane-session-1",
            "requestId": "request-resync-3",
            "requestSequence": 3,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ])

        // Act
        let resyncToken = try #require(
            floorRetirementExecutionToken(try await harness.begin(resyncRequest))
        )
        let resyncResponse = try await harness.authoritativeResyncResponse(
            request: resyncRequest,
            token: resyncToken
        )
        _ = try await harness.session.completeAdmittedControl(
            token: resyncToken,
            exactResponseBytes: try JSONEncoder().encode(resyncResponse)
        )

        // Assert: the reconciliation, not a hand-off, ends it, and it requires the
        // newer epoch so the worker retires rather than fails its side.
        guard case .resyncAccepted(let accepted) = resyncResponse,
            case .reopenRequired(let reopen)? = accepted.reconciliation.first
        else {
            Issue.record("Expected a reopen-required reconciliation, received \(resyncResponse)")
            try await harness.closeProducer(lease)
            return
        }
        #expect(accepted.reconciliation.count == 1)
        #expect(reopen.subscriptionId == "review-subscription-1")
        #expect(reopen.requiredWorkerDerivationEpoch == 8)
        #expect(await harness.session.takeFloorRetiredSubscriptions().isEmpty)
        #expect(try await deliveryIsGone(harness, lease: lease, subscriptionId: "review-subscription-1"))
        try await harness.closeProducer(lease)
    }

    @Test("the dispatcher hands floor-retired subscriptions to the provider before it executes the advancing control")
    func dispatcherHandsFloorRetiredSubscriptionsToProvider() async throws {
        // Arrange: a Review subscription opened at epoch 1 through the dispatcher.
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes,
            deadlineClock: TestPushClock()
        )
        let provider = FloorRetirementRecordingProvider()
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        try await dispatchFloorRetirementOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        let lease = try await installFloorRetirementMetadataStream(
            in: session,
            productAdmission: productAdmission
        )
        try await dispatchFloorRetirementOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: floorRetirementReviewOpenBody(
                subscriptionId: "review-subscription-epoch-1",
                requestSequence: 2,
                epoch: 1
            ),
            presentedCapability: capabilityHeader
        )

        // Act: a Review open at epoch 2 advances the floor.
        try await dispatchFloorRetirementOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: floorRetirementReviewOpenBody(
                subscriptionId: "review-subscription-epoch-2",
                requestSequence: 3,
                epoch: 2
            ),
            presentedCapability: capabilityHeader
        )

        // Assert
        #expect(
            await provider.events == [
                "response:subscription.open:review-subscription-epoch-1",
                "retire:review-subscription-epoch-1",
                "response:subscription.open:review-subscription-epoch-2",
            ]
        )
        _ = await session.stopProducer(lease)
    }
}

private func dispatchFloorRetirementOperation(
    dispatcher: BridgeProductSchemeControlDispatcher,
    session: BridgeProductSession,
    exactRequestBytes: Data,
    presentedCapability: String
) async throws {
    let dispatch = try await dispatcher.dispatch(
        exactRequestBytes: exactRequestBytes,
        presentedCapability: presentedCapability
    )
    guard case .response(let responseBytes) = dispatch else {
        Issue.record("Expected a Bridge product operation admission")
        return
    }
    let admitted = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: responseBytes
    )
    await session.waitForOperationExecution(operationId: admitted.operationId)
    #expect(
        await session.operationTable.entriesById[admitted.operationId]?.settlement?.outcome
            == .succeeded
    )
}

private struct FloorRetirementReset: Equatable {
    let subscriptionId: String
    let workerDerivationEpoch: Int
    let reason: BridgeProductResetReason
}

private struct FloorRetirementFrame {
    let sequence: Int
    let reset: FloorRetirementReset?
}

private func floorRetirementExecutionToken(
    _ admission: BridgeProductSessionControlAdmission
) -> BridgeProductControlAdmissionToken? {
    guard case .execute(let token, _) = admission else { return nil }
    return token
}

/// Opens a subscription the way the dispatcher does, so native holds a delivery
/// for it and its accepted frame is queued and consumed.
private func openDeliveredSubscription(
    _ harness: BridgeProductSessionLifecycleHarness,
    object: [String: Any],
    lease: BridgeProductProducerLease,
    expectedFrameSequence: Int
) async throws {
    let request = try bridgeProductLifecycleControlRequest(object)
    let token = try #require(floorRetirementExecutionToken(try await harness.begin(request)))
    try await completeDeliveredOpen(harness, request: request, token: token)
    #expect(try await nextMetadataFrame(harness, lease: lease).sequence == expectedFrameSequence)
}

private func completeDeliveredOpen(
    _ harness: BridgeProductSessionLifecycleHarness,
    request: BridgeProductControlRequest,
    token: BridgeProductControlAdmissionToken
) async throws {
    #expect(await harness.session.admitControlProviderExecution(token: token))
    let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
        correlating: request,
        worktreeId: nil
    )
    _ = try await harness.session.completeAdmittedControl(
        token: token,
        exactResponseBytes: try JSONEncoder().encode(response)
    )
    await harness.session.settleControlProviderDispatch(token: token)
}

private func nextMetadataFrame(
    _ harness: BridgeProductSessionLifecycleHarness,
    lease: BridgeProductProducerLease
) async throws -> FloorRetirementFrame {
    let queued = try #require(
        await consumeNextBridgeProductProducerFrame(
            for: lease,
            from: harness.session,
            productAdmission: harness.productAdmission.context
        )
    )
    let frames = try BridgeProductMetadataFrameDecoder().append(queued.data)
    guard case .subscriptionReset(let reset)? = frames.first else {
        return .init(sequence: queued.sequence, reset: nil)
    }
    let identity = reset.identity.subscriptionIdentity
    return .init(
        sequence: queued.sequence,
        reset: .init(
            subscriptionId: identity.subscriptionId,
            workerDerivationEpoch: identity.workerDerivationEpoch,
            reason: reset.reason
        )
    )
}

/// A producer can no longer deliver anything for the subscription once native
/// removed its delivery.
private func deliveryIsGone(
    _ harness: BridgeProductSessionLifecycleHarness,
    lease: BridgeProductProducerLease,
    subscriptionId: String
) async throws -> Bool {
    let foregroundWork = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
    let result = try await harness.session.enqueueSubscriptionReset(
        originatingMetadataLease: lease,
        subscriptionId: subscriptionId,
        reason: .staleSource,
        productAdmission: harness.productAdmission.context,
        foregroundWorkAdmission: foregroundWork.admission
    )
    return result == .rejected(.unknownLease)
}

private func installFloorRetirementMetadataStream(
    in session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductProducerLease {
    let operation = HeldStep<BridgeProductProducerLease>("floorRetirementMetadataProducer")
    let request = try bridgeProductMetadataStreamRequest(
        metadataStreamId: "metadata-floor-retirement-\(UUIDv7.generate().uuidString)",
        resumeFromStreamSequence: nil
    )
    let registration = await session.registerMetadataProducer(
        request: request,
        productAdmission: productAdmission
    ) { lease in
        try? await operation.arrive(lease)
    }
    guard case .accepted(let lease) = registration else {
        throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
    }
    let startedLease = try await operation.firstArrival()
    #expect(startedLease == lease)
    _ = try await session.enqueueRequiredProducerOpeningFrame(
        for: lease,
        productAdmission: productAdmission,
        build: { sequence in
            try producerRegistryMetadataOpeningFrame(for: request, sequence: sequence)
        }
    )
    return lease
}

private func floorRetirementReviewOpenBody(
    subscriptionId: String,
    requestSequence: Int,
    epoch: Int
) -> Data {
    Data(
        """
        {
          "kind":"subscription.open",
          "wireVersion":2,
          "paneSessionId":"\(bridgeProductTestPaneSessionId)",
          "workerDerivationEpoch":\(epoch),
          "workerInstanceId":"\(bridgeProductTestWorkerInstanceId)",
          "requestId":"request-floor-retirement-open-\(requestSequence)",
          "requestSequence":\(requestSequence),
          "subscriptionId":"\(subscriptionId)",
          "subscription":{"subscriptionKind":"review.metadata"}
        }
        """.utf8
    )
}

private actor FloorRetirementRecordingProvider: BridgeProductSchemeProvider {
    private(set) var events: [String] = []

    func response(
        for request: BridgeProductControlRequest,
        productAdmission _: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        do {
            switch request {
            case .workerSessionOpen:
                return try .workerSessionAccepted(correlating: request)
            case .subscriptionOpen(let openRequest):
                events.append("response:subscription.open:\(openRequest.subscriptionId)")
                return try .subscriptionOpenAccepted(correlating: request, worktreeId: nil)
            case .productCall, .subscriptionCancel,
                .viewScope, .viewResnapshot, .workerSessionResync:
                preconditionFailure("Unexpected floor-retirement control request")
            }
        } catch {
            preconditionFailure("Could not build floor-retirement control response")
        }
    }

    func retireFloorRetiredSubscriptions(
        _ subscriptions: [BridgeProductSubscriptionSnapshot],
        productAdmission _: BridgeProductAdmissionContext
    ) async {
        events.append(contentsOf: subscriptions.map { "retire:\($0.subscriptionId)" })
    }

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        _ = (request, lease, productAdmission, session)
    }

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        _ = (request, lease, productAdmission, session)
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        _ = acknowledgement
        return true
    }
}
