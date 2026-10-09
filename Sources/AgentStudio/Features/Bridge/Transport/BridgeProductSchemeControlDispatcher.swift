import Foundation
import os.log

private let bridgeProductControlDispatcherLogger = Logger(
    subsystem: "com.agentstudio",
    category: "BridgeProductSchemeControlDispatcher"
)

enum BridgeProductSchemeControlDispatchResult: Equatable, Sendable {
    case admissionClosed
    case rejected(BridgeProductSessionControlRejection)
    case typedRefusal(BridgeProductSessionControlRejection, Data)
    case response(Data)
}

struct BridgeProductSchemeControlDispatcher: Sendable {
    let session: BridgeProductSession
    let provider: any BridgeProductSchemeProvider
    let productAdmission: BridgeProductAdmissionContext

    func dispatch(
        exactRequestBytes: Data,
        presentedCapability: String
    ) async throws -> BridgeProductSchemeControlDispatchResult {
        guard
            (productAdmission.withValidAdmission { true }) == true
        else {
            return try Self.typedRefusal(
                for: .inactiveSession,
                exactRequestBytes: exactRequestBytes
            ) ?? .admissionClosed
        }
        let admission = await session.beginControl(
            exactRequestBytes: exactRequestBytes,
            presentedCapability: presentedCapability,
            productAdmission: productAdmission,
            reviewIntentAdmissionSource: provider.reviewIntentAdmissionSource
        )
        let floorRetiredSubscriptions = await session.takeFloorRetiredSubscriptions()
        switch admission {
        case .admissionClosed:
            return try Self.typedRefusal(
                for: .inactiveSession,
                exactRequestBytes: exactRequestBytes
            ) ?? .admissionClosed
        case .rejected(let rejection):
            guard let request = rejection.request else {
                return try Self.typedRefusal(
                    for: rejection.reason,
                    exactRequestBytes: exactRequestBytes
                ) ?? .rejected(rejection.reason)
            }
            return .response(
                try Self.encode(
                    Self.requestError(for: rejection.reason, request: request)
                )
            )
        case .replay(let exactResponseBytes):
            return .response(exactResponseBytes)
        case .execute(let token, let request):
            return try await dispatchAdmittedControl(
                token: token,
                request: request,
                floorRetiredSubscriptions: floorRetiredSubscriptions
            )
        }
    }

    private func dispatchAdmittedControl(
        token: BridgeProductControlAdmissionToken,
        request: BridgeProductControlRequest,
        floorRetiredSubscriptions: [BridgeProductSubscriptionSnapshot]
    ) async throws -> BridgeProductSchemeControlDispatchResult {
        if Task.isCancelled {
            try await session.abandonControl(token: token)
            throw CancellationError()
        }
        if request.isSlotFreeEscape {
            let response = try BridgeProductControlResponse.subscriptionCancelAccepted(
                correlating: request
            )
            let effect = try await session.completeEscapeControl(token: token, response: response)
            if let effectId = await session.beginEscapeEffect() {
                let effectTask = Task {
                    if !floorRetiredSubscriptions.isEmpty,
                        productAdmission.withValidAdmission({ true }) == true
                    {
                        await provider.retireFloorRetiredSubscriptions(
                            floorRetiredSubscriptions,
                            productAdmission: productAdmission
                        )
                    }
                    await Self.applyCommittedEffect(
                        effect,
                        request: request,
                        provider: provider,
                        productAdmission: productAdmission
                    )
                    await session.finishEscapeEffect(effectId: effectId)
                }
                await session.attachEscapeEffect(effectTask, effectId: effectId)
            }
            return .response(try Self.encode(response))
        }
        let admitted = try await session.admitControlOperation(token: token) { operationId in
            do {
                if !floorRetiredSubscriptions.isEmpty {
                    await provider.retireFloorRetiredSubscriptions(
                        floorRetiredSubscriptions,
                        productAdmission: productAdmission
                    )
                }
                guard
                    try await session.retireMetadataResponseBeforeResync(
                        token: token,
                        acknowledgeLifecycle: { acknowledgement in
                            await provider.acknowledgeLifecycle(acknowledgement)
                        }
                    )
                else {
                    throw BridgeProductSchemeAdapterError.producerRetirementFailed
                }
                guard await session.markOperationDispatched(operationId: operationId) else {
                    return
                }
                let providerResponse = await provider.response(
                    for: request,
                    productAdmission: productAdmission
                )
                if (productAdmission.withValidAdmission { true }) != true {
                    await session.settleControlProviderDispatch(token: token)
                } else {
                    do {
                        let authoritativeResponse = try await session.authoritativeControlResponse(
                            token: token,
                            providerResponse: providerResponse
                        )
                        await completeControl(
                            providerResponse: authoritativeResponse,
                            operationId: operationId,
                            request: request,
                            token: token
                        )
                    } catch {
                        if await session.isOperationSettledUnknown(operationId) {
                            await session.settleOperation(operationId: operationId, response: providerResponse)
                        } else {
                            throw error
                        }
                    }
                }
            } catch {
                await session.settleControlProviderDispatch(token: token)
            }
        }
        return .response(admitted.responseBytes)
    }

    private func completeControl(
        providerResponse: BridgeProductControlResponse,
        operationId: String,
        request: BridgeProductControlRequest,
        token: BridgeProductControlAdmissionToken
    ) async {
        do {
            let providerResponseBytes = try Self.encode(providerResponse)
            let completionEffect = try await session.completeControl(
                token: token,
                exactResponseBytes: providerResponseBytes
            )
            await Self.applyCommittedEffect(
                completionEffect,
                request: request,
                provider: provider,
                productAdmission: productAdmission
            )
            guard productAdmission.withValidAdmission({ true }) == true else {
                await session.settleControlProviderDispatch(token: token)
                return
            }
            await session.settleOperation(operationId: operationId, response: providerResponse)
        } catch {
            if await session.isOperationSettledUnknown(operationId) {
                await session.settleOperation(operationId: operationId, response: providerResponse)
                return
            }
            // These enums contain only closed reason cases and bounded sequence
            // integers. Never log an arbitrary provider error or request payload.
            let failureReason = (error as? BridgeProductSessionError).map(String.init(describing:)) ?? "unexpected"
            bridgeProductControlDispatcherLogger.error(
                "Product control completion failed kind=\(request.kind, privacy: .public) sequence=\(request.requestSequence) reason=\(failureReason, privacy: .public)"
            )
            await session.settleControlProviderDispatch(token: token)
        }
    }

    private static func applyCommittedEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        request: BridgeProductControlRequest,
        provider: any BridgeProductSchemeProvider,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        guard effect != .noEffect else { return }
        guard
            (productAdmission.withValidAdmission { true }) == true
        else { return }
        await provider.applyCommittedControlEffect(
            effect,
            for: request,
            productAdmission: productAdmission
        )
    }

    private static func encode(_ response: BridgeProductControlResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(response)
    }

    private static func typedRefusal(
        for reason: BridgeProductSessionControlRejection,
        exactRequestBytes: Data
    ) throws -> BridgeProductSchemeControlDispatchResult? {
        guard
            let request = try? BridgeProductStrictJSON.decode(
                BridgeProductControlRequest.self,
                from: exactRequestBytes
            )
        else { return nil }
        return try .typedRefusal(
            reason,
            encode(requestError(for: reason, request: request))
        )
    }

    private static func requestError(
        for rejection: BridgeProductSessionControlRejection,
        request: BridgeProductControlRequest
    ) throws -> BridgeProductControlResponse {
        let code: BridgeProductRequestErrorCode
        let nextExpectedRequestSequence: Int?
        let retryable: Bool
        switch rejection {
        case .inactiveSession:
            code = .resyncRequired
            nextExpectedRequestSequence = nil
            retryable = true
        case .invalidRequest:
            code = .invalidRequest
            nextExpectedRequestSequence = nil
            retryable = false
        case .unknownSubscription:
            code = .unknownSubscription
            nextExpectedRequestSequence = request.requestSequence
            retryable = false
        case .payloadTooLarge:
            code = .payloadTooLarge
            nextExpectedRequestSequence = nil
            retryable = false
        case .resultCapacityExhausted:
            code = .resultCapacityExhausted
            nextExpectedRequestSequence = request.requestSequence
            retryable = true
        case .mutationWatchCapacityExhausted:
            code = .mutationWatchCapacityExhausted
            nextExpectedRequestSequence = request.requestSequence
            retryable = true
        case .requestInFlight(let nextExpected):
            code = .sequenceConflict
            nextExpectedRequestSequence = nextExpected
            retryable = true
        case .revoked, .staleWorker:
            code = .staleWorker
            nextExpectedRequestSequence = nil
            retryable = false
        case .sequenceExhausted(let nextExpected),
            .sequenceConflict(let nextExpected):
            code = .sequenceConflict
            nextExpectedRequestSequence = nextExpected
            retryable = true
        case .staleDerivationEpoch, .streamSequenceConflict:
            code = .resyncRequired
            nextExpectedRequestSequence = nil
            retryable = true
        case .unauthorized:
            code = .unauthorized
            nextExpectedRequestSequence = nil
            retryable = false
        }
        return try .requestError(
            correlating: request,
            code: code,
            nextExpectedRequestSequence: nextExpectedRequestSequence,
            retryAfterMilliseconds: nil,
            retryable: retryable,
            safeMessage: nil
        )
    }
}
