import Foundation

extension BridgeProductSession {
    func enqueueRequiredMetadataOpeningFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext
    ) throws -> BridgeProductProducerEnqueueResult {
        guard case .metadata(let metadataKey)? = producerRegistry.producersByLeaseId[lease.id]?.key else {
            return .rejected(.unknownLease)
        }
        let admittedRequest = metadataKey.request
        let admittedResumeDisposition = metadataKey.expectedResumeDisposition
        return try enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: productAdmission,
            build: { _ in
                try .metadata(
                    .metadataStreamAccepted(
                        for: admittedRequest,
                        resumeDisposition: admittedResumeDisposition
                    )
                )
            }
        )
    }

    func enqueueSubscriptionReset(
        originatingMetadataLease: BridgeProductProducerLease,
        subscriptionId: String,
        reason: BridgeProductResetReason,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) throws -> BridgeProductProducerEnqueueResult {
        try foregroundWorkAdmission.withValidAdmission {
            try productAdmission.withValidAdmission {
                let target = try activeMetadataFrameTarget()
                guard target.lease == originatingMetadataLease,
                    producerAdmissionMatches(productAdmission, for: target.lease),
                    let delivery = protocolSubscriptionDeliveryById[subscriptionId]
                else {
                    return .rejected(.unknownLease)
                }
                let result = try producerRegistry.enqueueNonterminalFrame(
                    for: target.lease,
                    build: { streamSequence in
                        .metadata(
                            try .subscriptionReset(
                                stream: target.stream,
                                streamSequence: streamSequence,
                                subscription: delivery.correlation,
                                subscriptionSequence: delivery.nextSequence,
                                reason: reason
                            )
                        )
                    },
                    overflowReset: metadataStreamOverflowReset(for: target)
                )
                switch result {
                case .enqueued:
                    terminateProtocolSubscription(subscriptionId: subscriptionId)
                    resumeProducerFrameWaiterIfPossible(for: target.lease, admissionAlreadyHeld: true)
                case .queueReset:
                    terminateAllProtocolSubscriptionsWithDeliveries()
                    resumeProducerFrameWaiterIfPossible(for: target.lease, admissionAlreadyHeld: true)
                case .rejected:
                    break
                }
                return result
            } ?? .rejected(.lifecycleClosed)
        } ?? .rejected(.lifecycleClosed)
    }

    /// Terminates exactly the named subscriptions, for a metadata stream opened fresh
    /// (no resume): the client that owned those ids no longer exists.
    ///
    /// The caller passes the set it captured when the stream was installed rather than
    /// letting this read the session, so a subscription the NEW client opened in the
    /// meantime is never swept up. Terminating an id the session no longer holds is a
    /// no-op.
    ///
    /// Deliberately narrower than `revokeWorker()` or a surface floor advance: the worker
    /// session, its control replay and its producers all survive — only the
    /// subscriptions the new client cannot name are retired.
    func retireSubscriptions(_ subscriptionIds: [String]) {
        for subscriptionId in subscriptionIds {
            terminateProtocolSubscription(subscriptionId: subscriptionId)
        }
    }

    /// Ends the protocol side of subscriptions a surface floor advance retired. Each
    /// delivery is removed and, while a metadata stream is open, answered with an
    /// `epoch_retired` reset so the worker retires its side instead of waiting on
    /// frames that will never come. With no stream open, the next resync reconciles
    /// the missing record instead.
    func endFloorRetiredSubscriptions(_ subscriptions: [BridgeProductSubscriptionSnapshot]) {
        guard !subscriptions.isEmpty else { return }
        let target = try? activeMetadataFrameTarget()
        for subscription in subscriptions {
            closeViewDomains(subscriptionId: subscription.subscriptionId)
            guard
                let delivery = protocolSubscriptionDeliveryById.removeValue(
                    forKey: subscription.subscriptionId
                ),
                let target
            else { continue }
            let result = try? producerRegistry.enqueueNonterminalFrame(
                for: target.lease,
                build: { streamSequence in
                    .metadata(
                        try .subscriptionReset(
                            stream: target.stream,
                            streamSequence: streamSequence,
                            subscription: delivery.correlation,
                            subscriptionSequence: delivery.nextSequence,
                            reason: .epochRetired
                        )
                    )
                },
                overflowReset: metadataStreamOverflowReset(for: target)
            )
            switch result {
            case .enqueued?:
                resumeProducerFrameWaiterIfPossible(for: target.lease, admissionAlreadyHeld: true)
            case .queueReset?:
                terminateAllProtocolSubscriptionsWithDeliveries()
                resumeProducerFrameWaiterIfPossible(for: target.lease, admissionAlreadyHeld: true)
                return
            case .rejected?, nil:
                continue
            }
        }
    }

    private func terminateProtocolSubscription(subscriptionId: String) {
        closeViewDomains(subscriptionId: subscriptionId)
        protocolSubscriptionDeliveryById.removeValue(forKey: subscriptionId)
        subscriptionState.terminate(subscriptionId: subscriptionId)
    }

    private func terminateAllProtocolSubscriptionsWithDeliveries() {
        let subscriptionIds = protocolSubscriptionDeliveryById.keys
        for subscriptionId in subscriptionIds {
            closeViewDomains(subscriptionId: subscriptionId)
            subscriptionState.terminate(subscriptionId: subscriptionId)
        }
        protocolSubscriptionDeliveryById.removeAll(keepingCapacity: false)
    }

    func admitRequiredProtocolLifecycleFrame(
        for effect: BridgeProductSessionCompletionEffect,
        admissionAlreadyHeld: Bool = false
    ) throws {
        switch effect {
        case .noEffect, .productCall, .resynced, .viewScopeAccepted, .viewResnapshotAccepted:
            return
        case .subscriptionOpened(let snapshot):
            try admitSubscriptionOpenedFrame(snapshot, admissionAlreadyHeld: admissionAlreadyHeld)
        case .subscriptionCancelled(let snapshot):
            try admitSubscriptionCancelledFrame(snapshot, admissionAlreadyHeld: admissionAlreadyHeld)
        }
    }

    func reconcileProtocolSubscriptionDeliveries(
        _ result: BridgeProductSubscriptionResyncResult
    ) {
        for subscriptionId in result.revokedNativeOnlySubscriptionIds {
            closeViewDomains(subscriptionId: subscriptionId)
            protocolSubscriptionDeliveryById.removeValue(forKey: subscriptionId)
        }
        for outcome in result.reconciliation {
            switch outcome {
            case .cancelled, .reopenRequired:
                closeViewDomains(subscriptionId: outcome.subscriptionId)
                protocolSubscriptionDeliveryById.removeValue(forKey: outcome.subscriptionId)
            case .retained:
                guard
                    let snapshot = subscriptionState.snapshot(
                        subscriptionId: outcome.subscriptionId
                    ),
                    let correlation = try? Self.subscriptionFrameCorrelation(for: snapshot),
                    var delivery = protocolSubscriptionDeliveryById[outcome.subscriptionId]
                else { continue }
                delivery.correlation = correlation
                protocolSubscriptionDeliveryById[outcome.subscriptionId] = delivery
            }
        }
    }

    private func admitSubscriptionOpenedFrame(
        _ snapshot: BridgeProductSubscriptionSnapshot,
        admissionAlreadyHeld: Bool
    ) throws {
        let target = try activeMetadataFrameTarget()
        let correlation = try Self.subscriptionFrameCorrelation(for: snapshot)
        let streamSequence = try enqueueRequiredProtocolLifecycleFrame(
            target: target,
            admissionAlreadyHeld: admissionAlreadyHeld,
            build: { streamSequence in
                .metadata(
                    try .subscriptionAccepted(
                        stream: target.stream,
                        streamSequence: streamSequence,
                        subscription: correlation
                    )
                )
            }
        )
        protocolSubscriptionDeliveryById[snapshot.subscriptionId] = .init(
            correlation: correlation,
            nextSequence: 1,
            lastEnqueuedStreamSequence: streamSequence
        )
    }

    private func admitSubscriptionCancelledFrame(
        _ snapshot: BridgeProductSubscriptionSnapshot,
        admissionAlreadyHeld: Bool
    ) throws {
        let target = try activeMetadataFrameTarget()
        guard let delivery = protocolSubscriptionDeliveryById[snapshot.subscriptionId] else {
            throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
        }
        try enqueueRequiredProtocolLifecycleFrame(
            target: target,
            admissionAlreadyHeld: admissionAlreadyHeld,
            build: { streamSequence in
                .metadata(
                    try .subscriptionCancelled(
                        stream: target.stream,
                        streamSequence: streamSequence,
                        subscription: delivery.correlation,
                        subscriptionSequence: delivery.nextSequence
                    )
                )
            }
        )
        protocolSubscriptionDeliveryById.removeValue(forKey: snapshot.subscriptionId)
        closeViewDomains(subscriptionId: snapshot.subscriptionId)
    }

    private func activeMetadataFrameTarget() throws -> BridgeProductProtocolMetadataFrameTarget {
        for (leaseId, state) in producerRegistry.producersByLeaseId {
            guard case .metadata(let metadataKey) = state.key,
                state.openingFrameState != .required,
                state.lifecycle == .running
            else { continue }
            return .init(
                lease: .init(id: leaseId),
                stream: metadataKey.request.correlation
            )
        }
        throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
    }

    @discardableResult
    private func enqueueRequiredProtocolLifecycleFrame(
        target: BridgeProductProtocolMetadataFrameTarget,
        admissionAlreadyHeld: Bool,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) throws -> Int {
        let result = try producerRegistry.enqueueNonterminalFrame(
            for: target.lease,
            build: build,
            overflowReset: metadataStreamOverflowReset(for: target)
        )
        guard case .enqueued(let frame) = result else {
            throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
        }
        resumeProducerFrameWaiterIfPossible(
            for: target.lease,
            admissionAlreadyHeld: admissionAlreadyHeld
        )
        return frame.sequence
    }

    private func metadataStreamOverflowReset(
        for target: BridgeProductProtocolMetadataFrameTarget
    ) -> @Sendable (Int) throws -> BridgeProductProducerFrame {
        { streamSequence in
            .metadata(
                try .metadataStreamError(
                    stream: target.stream,
                    streamSequence: streamSequence,
                    code: .resyncRequired,
                    retryable: true,
                    safeMessage: nil
                )
            )
        }
    }

    private static func subscriptionFrameCorrelation(
        for snapshot: BridgeProductSubscriptionSnapshot
    ) throws -> BridgeProductSubscriptionFrameCorrelation {
        try .init(
            subscriptionId: snapshot.subscriptionId,
            subscriptionKind: snapshot.subscriptionKind,
            workerDerivationEpoch: snapshot.workerDerivationEpoch
        )
    }
}

struct BridgeProductProtocolMetadataFrameTarget: Sendable {
    let lease: BridgeProductProducerLease
    let stream: BridgeProductMetadataStreamCorrelation
}

struct BridgeProductProtocolSubscriptionDelivery: Sendable {
    var correlation: BridgeProductSubscriptionFrameCorrelation
    var nextSequence: Int
    var lastEnqueuedStreamSequence: Int
}
