import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeProductSchemeControlCompletionEffectsTests {
    @MainActor
    @Test("control replay and producer quiescence do not complete a held Review mode effect")
    func controlReplayQuiescenceDoesNotCompleteReviewModeEffect() async throws {
        // Arrange: the session and dispatcher are real; only the committed effect boundary is held.
        installTestCoreAtomsIfNeeded()
        let reviewModeEffect = HeldStep<CommittedReviewModeEffectInvocation>(
            "native Review mode effect",
            cancellation: .holdThroughCancellation
        )
        defer { reviewModeEffect.release() }
        var committedCallTarget: BridgePaneProductCommittedCallTarget?
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            sessionDeadlineClock: TestPushClock(),
            productSchemeProviderDecorator: { baseProvider, productAdmissionGate in
                let target = BridgePaneProductCommittedCallTarget(
                    productAdmissionGate: productAdmissionGate
                )
                committedCallTarget = target
                return BridgeProductReviewModeEffectDecorator(
                    base: baseProvider,
                    heldReviewModeEffect: reviewModeEffect,
                    committedCallTarget: target
                )
            }
        )
        let target = try #require(committedCallTarget)
        target.controller = fixture.controller

        let session = fixture.productInstallation.session
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: fixture.productControlProvider,
            productAdmission: fixture.productAdmission
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            fixture.productInstallation.capabilityBytes
        )
        let controlRequestBytes = try reviewModeControlRequest(
            installation: fixture.productInstallation,
            viewerModeSessionId: "go24-review-mode-session",
            viewerModeSequence: 1
        )

        // Act: dispatch admits and runs the product operation up to the held native effect.
        guard
            case .response(let admissionBytes) = try await dispatcher.dispatch(
                exactRequestBytes: controlRequestBytes,
                presentedCapability: capabilityHeader
            )
        else {
            Issue.record("Expected the Review mode operation to be admitted")
            await fixture.finish()
            return
        }
        let admitted = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: admissionBytes
        )
        let heldEffect = try await reviewModeEffect.firstArrival()

        // Assert: these are the existing helper's wait predicates; both may pass before native admission.
        #expect(heldEffect.correlation.requestSequence == 2)
        #expect(heldEffect.request.sequence == 1)
        #expect(heldEffect.request.sessionId == "go24-review-mode-session")
        #expect(await session.waitUntilControlReplayIdle(afterRequestSequence: 2))
        #expect(await session.waitUntilProducerFramesQuiescent())
        #expect(fixture.controller.activeViewerModeSignalState.acceptedMode == nil)

        // Act: release and join the exact dispatched operation.
        reviewModeEffect.release()
        await session.waitForOperationExecution(operationId: admitted.operationId)

        // Assert: the real native handler accepted the exact session and sequence before the operation closed.
        #expect(fixture.controller.activeViewerModeSignalState.sessionId == heldEffect.request.sessionId)
        #expect(fixture.controller.activeViewerModeSignalState.lastSequence == heldEffect.request.sequence)
        #expect(fixture.controller.activeViewerModeSignalState.acceptedMode == .review)
        #expect(
            await session.operationTable.entriesById[admitted.operationId]?.settlement?.outcome
                == .succeeded
        )
        await fixture.finish()
    }
}

private struct CommittedReviewModeEffectInvocation: Sendable {
    let request: BridgeProductActiveViewerModeUpdateRequest
    let correlation: BridgeProductControlCorrelation
}

private actor BridgeProductReviewModeEffectDecorator: BridgeProductSchemeProvider {
    private let base: any BridgeProductSchemeProvider
    private let heldReviewModeEffect: HeldStep<CommittedReviewModeEffectInvocation>
    private let committedCallTarget: BridgePaneProductCommittedCallTarget

    init(
        base: any BridgeProductSchemeProvider,
        heldReviewModeEffect: HeldStep<CommittedReviewModeEffectInvocation>,
        committedCallTarget: BridgePaneProductCommittedCallTarget
    ) {
        self.base = base
        self.heldReviewModeEffect = heldReviewModeEffect
        self.committedCallTarget = committedCallTarget
    }

    nonisolated var reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource? {
        base.reviewIntentAdmissionSource
    }

    func response(
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        await base.response(for: request, productAdmission: productAdmission)
    }

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        await base.runMetadataProducer(
            request: request,
            lease: lease,
            productAdmission: productAdmission,
            session: session
        )
    }

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        await base.runContentProducer(
            request: request,
            lease: lease,
            productAdmission: productAdmission,
            session: session
        )
    }

    nonisolated func makeContentProducerOperation(
        request: BridgeProductContentRequest,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) -> BridgeProductProducerRegistry.ProducerOperation {
        base.makeContentProducerOperation(
            request: request,
            productAdmission: productAdmission,
            session: session
        )
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        await base.acknowledgeLifecycle(acknowledgement)
    }

    func invalidatePendingComparisonTargetReservation() async {
        await base.invalidatePendingComparisonTargetReservation()
    }

    func activateWorkerIdentity(_ workerInstanceId: String) async {
        await base.activateWorkerIdentity(workerInstanceId)
    }

    func revokeWorkerIdentity(_ workerInstanceId: String) async {
        await base.revokeWorkerIdentity(workerInstanceId)
    }

    func applyCommittedControlEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        guard case .productCall(let committedCall) = effect,
            case .productCall(let callRequest) = request,
            committedCall == callRequest.call,
            case .reviewActiveViewerModeUpdate(let update) = committedCall
        else {
            await base.applyCommittedControlEffect(
                effect,
                for: request,
                productAdmission: productAdmission
            )
            return
        }

        try? await heldReviewModeEffect.arrive(
            CommittedReviewModeEffectInvocation(
                request: update,
                correlation: callRequest.correlation
            )
        )
        await base.applyCommittedControlEffect(
            effect,
            for: request,
            productAdmission: productAdmission
        )
        await committedCallTarget.applyActiveViewerModeUpdate(
            committedCall,
            correlation: callRequest.correlation,
            productAdmission: productAdmission
        )
    }

    func retireFloorRetiredSubscriptions(
        _ subscriptions: [BridgeProductSubscriptionSnapshot],
        productAdmission: BridgeProductAdmissionContext
    ) async {
        await base.retireFloorRetiredSubscriptions(
            subscriptions,
            productAdmission: productAdmission
        )
    }
}

private func reviewModeControlRequest(
    installation: BridgeProductSessionInstallation,
    viewerModeSessionId: String,
    viewerModeSequence: Int
) throws -> Data {
    let request =
        [
            "call": [
                "method": "review.activeViewerMode.update",
                "request": [
                    "activeSource": NSNull(),
                    "nativeSelectionRequestId": NSNull(),
                    "sequence": viewerModeSequence,
                    "sessionId": viewerModeSessionId,
                ],
            ],
            "kind": "product.call",
            "paneSessionId": installation.bootstrap.paneSessionId,
            "requestId": "go24-review-mode-update",
            "requestSequence": 2,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": 0,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ] as [String: Any]
    return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
}
