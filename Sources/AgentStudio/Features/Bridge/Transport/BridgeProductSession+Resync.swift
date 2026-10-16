extension BridgeProductSession {
    func retireMetadataResponseBeforeResync(
        token: BridgeProductControlAdmissionToken,
        acknowledgeLifecycle: @escaping ProducerLifecycleAcknowledger
    ) async throws -> Bool {
        guard let pendingControl = operationTable.entry(for: token)?.admission else {
            throw BridgeProductSessionError.invalidAdmissionToken
        }
        guard case .workerSessionResync = pendingControl.request else { return true }
        guard pendingControl.productAdmission.withValidAdmission({ true }) == true else {
            throw BridgeProductSessionError.admissionClosed
        }
        // Close the old physical response before reporting a resume barrier.
        // Otherwise an old-source enqueue can invalidate that barrier while
        // the worker is opening its replacement response.
        for lease in producerRegistry.metadataProducerLeases {
            let retirement = beginProducerRetirement(
                lease,
                acknowledgeLifecycle: acknowledgeLifecycle,
                stopRequest: nil,
                abandonOutstandingDelivery: true
            )
            guard await retirement.wait() else { return false }
        }
        guard pendingControl.productAdmission.withValidAdmission({ true }) == true else {
            throw BridgeProductSessionError.admissionClosed
        }
        return true
    }

    func authoritativeControlResponse(
        token: BridgeProductControlAdmissionToken,
        providerResponse: BridgeProductControlResponse
    ) throws -> BridgeProductControlResponse {
        guard let pendingControl = operationTable.entry(for: token)?.admission else {
            throw BridgeProductSessionError.invalidAdmissionToken
        }
        guard
            (pendingControl.productAdmission.withValidAdmission { true }) == true
        else {
            throw BridgeProductSessionError.admissionClosed
        }
        guard providerResponse.correlation == pendingControl.request.correlation else {
            throw BridgeProductSessionError.mismatchedControlResponse
        }
        guard case .workerSessionResync(let resyncRequest) = pendingControl.request,
            case .resyncAccepted = providerResponse
        else {
            guard
                (pendingControl.productAdmission.withValidAdmission { true }) == true
            else {
                throw BridgeProductSessionError.admissionClosed
            }
            return providerResponse
        }

        var candidateSubscriptions = subscriptionState
        for (surface, epoch) in pendingControl.deferredResyncEpochs
        where epoch > workerDerivationEpochBySurface[surface, default: 0] {
            candidateSubscriptions.retireSubscriptions(on: surface, belowWorkerDerivationEpoch: epoch)
        }
        let reconciliation: BridgeProductSubscriptionResyncResult
        do {
            reconciliation = try candidateSubscriptions.reconcile(
                activeSubscriptions: resyncRequest.activeSubscriptions,
                snapshotRequiredSubscriptionIds: subscriptionsRequiringSnapshot(for: pendingControl.request)
            )
        } catch let stateError as BridgeProductSubscriptionStateError {
            throw BridgeProductSessionError.subscriptionStateRejected(stateError)
        }
        let nextMetadataStreamSequence = producerRegistry.snapshot().nextMetadataStreamSequence
        let metadataStreamSequenceBarrier = max(
            resyncRequest.lastAcceptedStreamSequence,
            max(0, nextMetadataStreamSequence - 1)
        )
        let response = try BridgeProductControlResponse.resyncAccepted(
            correlating: pendingControl.request,
            metadataStreamSequenceBarrier: metadataStreamSequenceBarrier,
            nextExpectedRequestSequence: pendingControl.request.requestSequence + 1,
            reconciliation: reconciliation.reconciliation
        )
        guard
            (pendingControl.productAdmission.withValidAdmission { true }) == true
        else {
            throw BridgeProductSessionError.admissionClosed
        }
        return response
    }

    func streamProgressRejection(
        for request: BridgeProductControlRequest
    ) -> BridgeProductSessionControlRejection? {
        guard case .workerSessionResync(let resyncRequest) = request else { return nil }
        let nextMetadataStreamSequence = producerRegistry.snapshot().nextMetadataStreamSequence
        guard resyncRequest.lastAcceptedStreamSequence < nextMetadataStreamSequence else {
            return .streamSequenceConflict(
                nextMetadataStreamSequence: nextMetadataStreamSequence
            )
        }
        return nil
    }

    func subscriptionsRequiringSnapshot(
        for request: BridgeProductControlRequest
    ) -> [String] {
        guard case .workerSessionResync(let resyncRequest) = request else { return [] }
        // A physical resume barrier does not restore discarded subscription
        // frames. Preserve an identity only when the worker has its complete
        // admitted history; otherwise the existing fresh-open path owns catch-up.
        return protocolSubscriptionDeliveryById.compactMap { subscriptionId, delivery in
            delivery.lastEnqueuedStreamSequence > resyncRequest.lastAcceptedStreamSequence
                ? subscriptionId : nil
        }
    }

    func preflightResyncEpochs(
        _ activeSubscriptions: [BridgeProductActiveSubscription]
    ) -> [BridgeProductSurface: Int]? {
        var candidateEpochs: [BridgeProductSurface: Int] = [:]
        for subscription in activeSubscriptions {
            let surface = subscription.surface
            if let candidateEpoch = candidateEpochs[surface],
                candidateEpoch != subscription.workerDerivationEpoch
            {
                return nil
            }
            guard
                subscription.workerDerivationEpoch
                    >= workerDerivationEpochBySurface[surface, default: 0]
            else {
                return nil
            }
            candidateEpochs[surface] = subscription.workerDerivationEpoch
        }
        return candidateEpochs
    }
}
