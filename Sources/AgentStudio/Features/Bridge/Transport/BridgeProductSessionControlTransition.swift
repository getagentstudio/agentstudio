import Foundation

struct BridgeProductSessionControlTransition: Sendable {
    let subscriptionState: BridgeProductSubscriptionState
    let effect: BridgeProductSessionCompletionEffect
}

enum BridgeProductSessionControlTransitionBuilder {
    static func validateResponseShape(
        request: BridgeProductControlRequest,
        response: BridgeProductControlResponse
    ) throws {
        if case .requestError(let errorResponse) = response {
            guard
                errorResponse.nextExpectedRequestSequence
                    == request.correlation.requestSequence + 1
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
            return
        }

        switch (request, response) {
        case (.workerSessionOpen, .workerSessionAccepted):
            return
        case (.productCall(let callRequest), .callCompleted(let callResponse)):
            guard callResponse.call.method == callRequest.call.method else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
        case (.subscriptionOpen(let openRequest), .subscriptionOpenAccepted(let openResponse)):
            var emptySubscriptions = BridgeProductSubscriptionState()
            let receipt = try emptySubscriptions.open(openRequest)
            guard openResponse.subscriptionId == receipt.subscriptionId,
                openResponse.subscriptionKind == receipt.subscriptionKind
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
        case (
            .subscriptionCancel(let cancelRequest),
            .subscriptionCancelAccepted(let cancelResponse)
        ):
            guard cancelResponse.subscriptionId == cancelRequest.subscriptionId,
                cancelResponse.subscriptionKind == cancelRequest.subscriptionKind
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
        case (.viewScope(let scopeRequest), .viewAccepted(let accepted)):
            guard accepted == BridgeProductViewAcceptedResponse(correlating: scopeRequest) else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
        case (.viewResnapshot(let resnapshotRequest), .viewAccepted(let accepted)):
            guard accepted == BridgeProductViewAcceptedResponse(correlating: resnapshotRequest) else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
        case (.workerSessionResync(let resyncRequest), .resyncAccepted(let resyncResponse)):
            let reconciliationMatchesActiveSubscriptions = zip(
                resyncResponse.reconciliation,
                resyncRequest.activeSubscriptions
            ).allSatisfy { outcome, activeSubscription in
                outcome.subscriptionId == activeSubscription.subscriptionId
                    && outcome.subscriptionKind == activeSubscription.subscriptionKind
            }
            guard
                resyncResponse.nextExpectedRequestSequence
                    == resyncRequest.correlation.requestSequence + 1,
                resyncResponse.metadataStreamSequenceBarrier
                    >= resyncRequest.lastAcceptedStreamSequence,
                resyncResponse.reconciliation.count == resyncRequest.activeSubscriptions.count,
                reconciliationMatchesActiveSubscriptions
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
        default:
            throw BridgeProductSessionError.mismatchedControlResponse
        }
    }

    static func prepare(
        request: BridgeProductControlRequest,
        response: BridgeProductControlResponse,
        subscriptionState: BridgeProductSubscriptionState,
        resyncEpochs: [BridgeProductSurface: Int],
        currentEpochs: [BridgeProductSurface: Int],
        snapshotRequiredSubscriptionIds: [String] = []
    ) throws -> BridgeProductSessionControlTransition {
        try validateResponseShape(request: request, response: response)
        if case .requestError = response {
            return .init(subscriptionState: subscriptionState, effect: .noEffect)
        }

        var candidateSubscriptions = subscriptionState
        switch (request, response) {
        case (.workerSessionOpen, .workerSessionAccepted):
            return .init(subscriptionState: candidateSubscriptions, effect: .noEffect)

        case (.productCall(let callRequest), .callCompleted(let callResponse)):
            guard callResponse.call.method == callRequest.call.method else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
            return .init(
                subscriptionState: candidateSubscriptions,
                effect: .productCall(callRequest.call)
            )

        case (.subscriptionOpen(let openRequest), .subscriptionOpenAccepted(let openResponse)):
            let receipt = try candidateSubscriptions.open(openRequest)
            guard openResponse.subscriptionId == receipt.subscriptionId,
                openResponse.subscriptionKind == receipt.subscriptionKind
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
            guard
                let openedSubscription = candidateSubscriptions.snapshot(
                    subscriptionId: receipt.subscriptionId
                )
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
            return .init(
                subscriptionState: candidateSubscriptions,
                effect: .subscriptionOpened(openedSubscription)
            )

        case (
            .subscriptionCancel(let cancelRequest),
            .subscriptionCancelAccepted(let cancelResponse)
        ):
            let cancelledSubscription = try candidateSubscriptions.cancel(cancelRequest)
            guard cancelResponse.subscriptionId == cancelRequest.subscriptionId,
                cancelResponse.subscriptionKind == cancelRequest.subscriptionKind
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
            return .init(
                subscriptionState: candidateSubscriptions,
                effect: cancelledSubscription.map(BridgeProductSessionCompletionEffect.subscriptionCancelled)
                    ?? .noEffect
            )

        case (.viewScope(let scopeRequest), .viewAccepted):
            return .init(
                subscriptionState: candidateSubscriptions,
                effect: .viewScopeAccepted(scopeRequest)
            )

        case (.viewResnapshot(let resnapshotRequest), .viewAccepted):
            return .init(
                subscriptionState: candidateSubscriptions,
                effect: .viewResnapshotAccepted(resnapshotRequest)
            )

        case (.workerSessionResync(let resyncRequest), .resyncAccepted(let resyncResponse)):
            guard
                resyncResponse.nextExpectedRequestSequence
                    == resyncRequest.correlation.requestSequence + 1,
                resyncResponse.metadataStreamSequenceBarrier
                    >= resyncRequest.lastAcceptedStreamSequence
            else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
            for (surface, epoch) in resyncEpochs
            where epoch > currentEpochs[surface, default: 0] {
                candidateSubscriptions.retireSubscriptions(on: surface, belowWorkerDerivationEpoch: epoch)
            }
            let resyncResult = try candidateSubscriptions.reconcile(
                activeSubscriptions: resyncRequest.activeSubscriptions,
                snapshotRequiredSubscriptionIds: snapshotRequiredSubscriptionIds
            )
            guard resyncResponse.reconciliation == resyncResult.reconciliation else {
                throw BridgeProductSessionError.mismatchedControlResponse
            }
            return .init(
                subscriptionState: candidateSubscriptions,
                effect: .resynced(resyncResult)
            )

        default:
            throw BridgeProductSessionError.mismatchedControlResponse
        }
    }

}
