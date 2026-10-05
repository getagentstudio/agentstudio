import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

struct BridgeReviewComparisonHeldEffect: Sendable {
    let effect: BridgeProductSessionCompletionEffect
    let request: BridgeProductControlRequest
}

actor BridgeReviewComparisonEffectHoldingProvider: BridgeProductSchemeProvider {
    private let baseProvider: BridgePaneProductSchemeProvider
    private let heldEffectStepByRequestSequence: [Int: HeldStep<BridgeReviewComparisonHeldEffect>]
    nonisolated let reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource?

    init(
        baseProvider: BridgePaneProductSchemeProvider,
        heldEffectStepByRequestSequence: [Int: HeldStep<BridgeReviewComparisonHeldEffect>]
    ) {
        self.baseProvider = baseProvider
        self.heldEffectStepByRequestSequence = heldEffectStepByRequestSequence
        self.reviewIntentAdmissionSource = baseProvider.reviewIntentAdmissionSource
    }

    func response(
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        await baseProvider.response(for: request, productAdmission: productAdmission)
    }

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        await baseProvider.runMetadataProducer(
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
        await baseProvider.runContentProducer(
            request: request,
            lease: lease,
            productAdmission: productAdmission,
            session: session
        )
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        await baseProvider.acknowledgeLifecycle(acknowledgement)
    }

    func invalidatePendingComparisonTargetReservation() async {
        await baseProvider.invalidatePendingComparisonTargetReservation()
    }

    func activateWorkerIdentity(_ workerInstanceId: String) async {
        await baseProvider.activateWorkerIdentity(workerInstanceId)
    }

    func revokeWorkerIdentity(_ workerInstanceId: String) async {
        await baseProvider.revokeWorkerIdentity(workerInstanceId)
    }

    func applyCommittedControlEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        if let heldEffectStep = heldEffectStepByRequestSequence[request.correlation.requestSequence] {
            do {
                try await heldEffectStep.arrive(
                    BridgeReviewComparisonHeldEffect(effect: effect, request: request)
                )
            } catch {
                return
            }
        }
        await baseProvider.applyCommittedControlEffect(
            effect,
            for: request,
            productAdmission: productAdmission
        )
    }

    func retireFloorRetiredSubscriptions(
        _ subscriptions: [BridgeProductSubscriptionSnapshot],
        productAdmission: BridgeProductAdmissionContext
    ) async {
        await baseProvider.retireFloorRetiredSubscriptions(
            subscriptions,
            productAdmission: productAdmission
        )
    }
}

@MainActor
struct BridgeReviewComparisonControlFixture {
    let controller: BridgePaneController
    let productAdmission: BridgeProductAdmissionContext
    let session: BridgeProductSession
    let provider: BridgeReviewComparisonEffectHoldingProvider
    let dispatcher: BridgeProductSchemeControlDispatcher
    let capabilityHeader: String
    let paneSessionId: String
    let workerInstanceId: String
    let heldEffectStepByRequestSequence: [Int: HeldStep<BridgeReviewComparisonHeldEffect>]

    func openWorkerSession() async throws {
        let dispatchResult = try await dispatcher.dispatch(
            exactRequestBytes: bridgeReviewComparisonWorkerOpenRequestBytes(
                paneSessionId: paneSessionId,
                workerInstanceId: workerInstanceId
            ),
            presentedCapability: capabilityHeader
        )
        let operationResult = try await readOperationResult(for: dispatchResult)
        guard operationResult.outcome == .succeeded else {
            throw BridgeReviewComparisonControlFixtureError.workerSessionDidNotOpen
        }
    }

    func dispatchComparisonUpdate(
        target: WorkspaceReviewContributionTarget,
        requestSequence: Int,
        workerDerivationEpoch: Int
    ) async throws -> BridgeProductSchemeControlDispatchResult {
        try await dispatcher.dispatch(
            exactRequestBytes: bridgeReviewComparisonUpdateRequestBytes(
                target: target,
                requestSequence: requestSequence,
                workerDerivationEpoch: workerDerivationEpoch,
                paneSessionId: paneSessionId,
                workerInstanceId: workerInstanceId
            ),
            presentedCapability: capabilityHeader
        )
    }

    func firstHeldEffect(for requestSequence: Int) async throws -> BridgeReviewComparisonHeldEffect {
        guard let heldEffectStep = heldEffectStepByRequestSequence[requestSequence] else {
            throw BridgeReviewComparisonControlFixtureError.effectWasNotConfiguredToHold
        }
        return try await heldEffectStep.firstArrival()
    }

    func releaseHeldEffect(for requestSequence: Int) {
        heldEffectStepByRequestSequence[requestSequence]?.release()
    }

    func releaseAllHeldEffects() {
        for heldEffectStep in heldEffectStepByRequestSequence.values {
            heldEffectStep.release()
        }
    }

    func readOperationResult(
        for dispatchResult: BridgeProductSchemeControlDispatchResult
    ) async throws -> BridgeProductOperationResultResponse {
        guard case .response(let admissionBytes) = dispatchResult else {
            throw BridgeReviewComparisonControlFixtureError.expectedOperationAdmission
        }
        let admitted = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: admissionBytes
        )
        await session.waitForOperationExecution(operationId: admitted.operationId)
        let operationResultRequestBytes = try JSONSerialization.data(withJSONObject: [
            "kind": "operation.result",
            "operationId": admitted.operationId,
            "paneSessionId": admitted.correlation.paneSessionId,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": admitted.correlation.workerInstanceId,
        ])
        let operationResultRequest = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultRequest.self,
            from: operationResultRequestBytes
        )
        return try #require(
            await session.readOperationResult(
                operationResultRequest,
                productAdmission: productAdmission
            )
        )
    }

    func finish() async {
        releaseAllHeldEffects()
        let revocation = await session.revoke(
            acknowledgeLifecycle: { acknowledgement in
                await provider.acknowledgeLifecycle(acknowledgement)
            }
        )
        _ = await revocation.wait()
        let teardown = controller.beginTeardown()
        _ = await teardown.value
    }
}

@MainActor
func makeBridgeReviewComparisonControlFixture(
    controller: BridgePaneController,
    heldRequestSequences: Set<Int> = []
) async throws -> BridgeReviewComparisonControlFixture {
    let productAdmission = try #require(controller.productAdmissionGate.acquire())
    let committedCallTarget = BridgePaneProductCommittedCallTarget(
        productAdmissionGate: controller.productAdmissionGate
    )
    committedCallTarget.controller = controller
    let baseProvider = BridgePaneProductSchemeProvider(
        fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
        reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
        reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
        markReviewItemViewed: { _, _ in },
        applyReviewComparisonUpdate: committedCallTarget.applyReviewComparisonUpdate,
        refreshWorkAdmissionSource: controller.refreshAdmissionCoordinator.workAdmissionSource
    )
    let heldEffectStepByRequestSequence = Dictionary(
        uniqueKeysWithValues: heldRequestSequences.map { requestSequence in
            (
                requestSequence,
                HeldStep<BridgeReviewComparisonHeldEffect>(
                    "Review comparison effect at request sequence \(requestSequence)"
                )
            )
        }
    )
    let provider = BridgeReviewComparisonEffectHoldingProvider(
        baseProvider: baseProvider,
        heldEffectStepByRequestSequence: heldEffectStepByRequestSequence
    )
    let paneSessionId = controller.paneId.uuidString
    let workerInstanceId = UUIDv7.generate().uuidString
    let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
    let session = try BridgeProductSession(
        paneSessionId: paneSessionId,
        workerInstanceId: workerInstanceId,
        capabilityBytes: capabilityBytes,
        deadlineClock: TestPushClock()
    )
    let dispatcher = BridgeProductSchemeControlDispatcher(
        session: session,
        provider: provider,
        productAdmission: productAdmission
    )
    await provider.activateWorkerIdentity(workerInstanceId)
    return BridgeReviewComparisonControlFixture(
        controller: controller,
        productAdmission: productAdmission,
        session: session,
        provider: provider,
        dispatcher: dispatcher,
        capabilityHeader: try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes),
        paneSessionId: paneSessionId,
        workerInstanceId: workerInstanceId,
        heldEffectStepByRequestSequence: heldEffectStepByRequestSequence
    )
}

private func bridgeReviewComparisonWorkerOpenRequestBytes(
    paneSessionId: String,
    workerInstanceId: String
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "kind": "workerSession.open",
            "paneSessionId": paneSessionId,
            "request": NSNull(),
            "requestId": "review-comparison-worker-open",
            "requestSequence": 1,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": workerInstanceId,
        ], options: [.sortedKeys])
}

private func bridgeReviewComparisonUpdateRequestBytes(
    target: WorkspaceReviewContributionTarget,
    requestSequence: Int,
    workerDerivationEpoch: Int,
    paneSessionId: String,
    workerInstanceId: String
) throws -> Data {
    let call = BridgeProductCallRequest.reviewComparisonUpdate(
        BridgeProductReviewComparisonUpdateRequest(target: target)
    )
    let encodedCall = try JSONSerialization.jsonObject(with: JSONEncoder().encode(call))
    return try JSONSerialization.data(
        withJSONObject: [
            "call": encodedCall,
            "kind": "product.call",
            "paneSessionId": paneSessionId,
            "requestId": "review-comparison-update-\(requestSequence)",
            "requestSequence": requestSequence,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": workerDerivationEpoch,
            "workerInstanceId": workerInstanceId,
        ], options: [.sortedKeys])
}

private enum BridgeReviewComparisonControlFixtureError: Error {
    case effectWasNotConfiguredToHold
    case expectedOperationAdmission
    case workerSessionDidNotOpen
}
