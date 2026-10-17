import AgentStudioInfrastructure
import Foundation

struct BridgeProductNativeCommentView: Sendable {
    let handle: String
    let scope: BridgeProductJSONValue
    let viewDomain: BridgeProductViewDomainKey
}

struct BridgeProductAcceptedViewScope: Sendable {
    let handle: String
    let revision: Int
    let admissionSequence: Int
    let scope: BridgeProductJSONValue
}

struct BridgeProductAcceptedViewScopeSnapshot: Sendable {
    let viewDomain: BridgeProductViewDomainKey
    let handle: String
    let revision: Int
    let admissionSequence: Int
    let scope: BridgeProductJSONValue
}

struct BridgeProductViewEmissionWaiter {
    let id: UUID
    let handle: String
    let continuation: CheckedContinuation<BridgeProductViewEmissionOutcome, Never>
}

enum BridgeProductViewEmissionOutcome: Equatable, Sendable {
    case completed
    case resnapshotRequired
    case retired
}

extension BridgeProductSession {
    /// The native subscription owner establishes Comment authority before N10
    /// captures its first range. No page supplied worktree can widen it.
    func openNativeCommentView(
        subscriptionId: String,
        worktreeID: String,
        productAdmission: BridgeProductAdmissionContext
    ) throws -> BridgeProductNativeCommentView? {
        guard lifecycle == .active,
            productAdmission.withValidAdmission({ true }) == true,
            let subscription = subscriptionState.snapshot(subscriptionId: subscriptionId),
            subscription.subscriptionKind == .fileAnnotations
                || subscription.subscriptionKind == .reviewAnnotations
        else { return nil }
        let scope = BridgeProductJSONValue.object([
            "kind": .string("comment"),
            "sessionIds": .array([]),
            "worktreeId": .string(worktreeID),
        ])
        try BridgeProductViewScopeContract.validate(scope, codingPath: [])
        let viewDomain = BridgeProductViewDomainKey(
            viewId: subscriptionId,
            domain: .singleDomain,
            incarnation: UUIDv7.generate().uuidString.lowercased()
        )
        let handle = UUIDv7.generate().uuidString.lowercased()
        for prior in Array(viewScopeByDomain.keys)
        where prior.viewId == subscriptionId && prior.domain == .singleDomain {
            finishViewEmissionWaiter(for: prior, outcome: .retired)
            viewSenderState.close(prior)
            viewScopeByDomain.removeValue(forKey: prior)
            viewAcknowledgementReplayByDomain.removeValue(forKey: prior)
            nextViewDeliverySequenceByDomain.removeValue(forKey: prior)
            pendingFileSnapshotByViewDomain.removeValue(forKey: prior)
            lastSealedFileTargetByViewDomain.removeValue(forKey: prior)
            pendingReviewSnapshotByViewDomain.removeValue(forKey: prior)
        }
        viewSenderState.open(viewDomain, handle: handle, scanGeneration: 0)
        rescheduleViewAcknowledgementDeadline()
        viewScopeByDomain[viewDomain] = .init(
            handle: handle, revision: 0, admissionSequence: 0, scope: scope
        )
        nextViewDeliverySequenceByDomain[viewDomain] = 1
        return .init(handle: handle, scope: scope, viewDomain: viewDomain)
    }

    func sealReviewSnapshot(
        subscriptionId: String,
        snapshot: BridgeProductReviewKeyedSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) throws -> Bool {
        guard let subscription = subscriptionState.snapshot(subscriptionId: subscriptionId),
            subscription.subscriptionKind == .reviewMetadata,
            let viewDomain = viewScopeByDomain.keys.first(where: {
                $0.viewId == subscriptionId && $0.domain == .singleDomain
            }), let current = viewScopeByDomain[viewDomain]
        else { return false }
        if viewSenderState.hasActiveEmission(for: viewDomain) {
            if snapshot.targetRevision >= (pendingReviewSnapshotByViewDomain[viewDomain]?.targetRevision ?? 0) {
                pendingReviewSnapshotByViewDomain[viewDomain] = snapshot
            }
            return true
        }
        let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: viewDomain,
                handle: current.handle,
                scopeRevision: current.revision,
                scope: current.scope,
                firstDeliverySequence: nextViewDeliverySequenceByDomain[viewDomain] ?? 1,
                targetRevision: snapshot.targetRevision,
                publication: snapshot.publication,
                items: snapshot.items
            )
        )
        return try sealViewBatch(batch, productAdmission: productAdmission)
    }

    func sealCommentCatalogBatch(
        subscriptionId: String,
        catalogBatch: BridgeProductCommentCatalogBatch,
        mode: BridgeProductBatchMode,
        productAdmission: BridgeProductAdmissionContext
    ) throws -> BridgeProductViewEmissionOutcome {
        guard lifecycle == .active, productAdmission.withValidAdmission({ true }) == true,
            let subscription = subscriptionState.snapshot(subscriptionId: subscriptionId),
            subscription.subscriptionKind == .fileAnnotations
                || subscription.subscriptionKind == .reviewAnnotations,
            let viewDomain = viewScopeByDomain.keys.first(where: {
                $0.viewId == subscriptionId && $0.domain == .singleDomain
            }),
            let current = viewScopeByDomain[viewDomain],
            current.handle == catalogBatch.handle,
            current.revision >= catalogBatch.scopeRevision
        else { return .retired }
        if mode == .change, case .snapshotRequired = viewSenderState.pending(for: viewDomain) {
            return .resnapshotRequired
        }
        let sealedBatch = try BridgeProductCommentViewBatchFactory.seal(
            .init(
                viewDomain: viewDomain,
                scopeRevision: current.revision,
                scope: current.scope,
                firstDeliverySequence: nextViewDeliverySequenceByDomain[viewDomain] ?? 1,
                mode: mode,
                batch: catalogBatch,
                subscriptionKind: subscription.subscriptionKind
            )
        )
        return try sealViewBatch(sealedBatch, productAdmission: productAdmission) ? .completed : .retired
    }

    /// N10 may capture its next range only after this domain has emitted the
    /// prior sealed batch. Invalidations coalesce in the service while it waits.
    func awaitViewEmissionCompletion(
        for viewDomain: BridgeProductViewDomainKey,
        handle: String
    ) async -> BridgeProductViewEmissionOutcome {
        guard lifecycle == .active,
            viewScopeByDomain[viewDomain]?.handle == handle
        else { return .retired }
        guard
            viewSenderState.hasActiveEmission(for: viewDomain)
                || pendingFileSnapshotByViewDomain[viewDomain] != nil
        else { return .completed }
        let waiterID = UUIDv7.generate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                    viewScopeByDomain[viewDomain]?.handle == handle,
                    viewEmissionWaiterByDomain[viewDomain] == nil
                else {
                    continuation.resume(returning: .retired)
                    return
                }
                viewEmissionWaiterByDomain[viewDomain] = .init(
                    id: waiterID,
                    handle: handle,
                    continuation: continuation
                )
                viewEmissionWaiterRegistrationObserver?(viewDomain)
            }
        } onCancel: {
            Task { await self.cancelViewEmissionWaiter(for: viewDomain, id: waiterID) }
        }
    }

    private func cancelViewEmissionWaiter(for viewDomain: BridgeProductViewDomainKey, id: UUID) {
        guard viewEmissionWaiterByDomain[viewDomain]?.id == id else { return }
        finishViewEmissionWaiter(for: viewDomain, outcome: .retired)
    }

    func finishViewEmissionWaiter(
        for viewDomain: BridgeProductViewDomainKey,
        outcome: BridgeProductViewEmissionOutcome
    ) {
        guard let waiter = viewEmissionWaiterByDomain.removeValue(forKey: viewDomain) else { return }
        let currentOutcome: BridgeProductViewEmissionOutcome =
            viewScopeByDomain[viewDomain]?.handle == waiter.handle ? outcome : .retired
        waiter.continuation.resume(returning: currentOutcome)
    }

    func finishAllViewEmissionWaiters() {
        for viewDomain in Array(viewEmissionWaiterByDomain.keys) {
            finishViewEmissionWaiter(for: viewDomain, outcome: .retired)
        }
    }

    private func finishReadyViewEmissionWaiters() {
        for viewDomain in Array(viewEmissionWaiterByDomain.keys)
        where !viewSenderState.hasActiveEmission(for: viewDomain)
            && pendingFileSnapshotByViewDomain[viewDomain] == nil
        {
            finishViewEmissionWaiter(for: viewDomain, outcome: .completed)
        }
    }

    func rescheduleViewAcknowledgementDeadline() {
        viewAcknowledgementDeadlineTask?.cancel()
        viewAcknowledgementDeadlineTask = nil
        viewAcknowledgementDeadlineGeneration += 1
        guard lifecycle == .active,
            let oldest = viewSenderState.oldestUnacknowledgedPart()
        else { return }
        let remaining = max(
            .zero,
            oldest.admittedAt + AppPolicies.Bridge.productViewAcknowledgementDeadline - viewDeadlineElapsed()
        )
        let generation = viewAcknowledgementDeadlineGeneration
        let delay = operationDelay
        viewAcknowledgementDeadlineTask = Task { [weak self] in
            do { try await delay.wait(remaining) } catch { return }
            await self?.expireViewAcknowledgementDeadline(generation: generation)
        }
    }

    private func expireViewAcknowledgementDeadline(generation: Int) async {
        guard generation == viewAcknowledgementDeadlineGeneration,
            lifecycle == .active,
            let oldest = viewSenderState.oldestUnacknowledgedPart()
        else { return }
        viewAcknowledgementDeadlineTask = nil
        guard viewDeadlineElapsed() >= oldest.admittedAt + AppPolicies.Bridge.productViewAcknowledgementDeadline,
            let scope = viewScopeByDomain[oldest.viewDomain],
            scope.handle == oldest.handle,
            let subscription = subscriptionState.snapshot(subscriptionId: oldest.viewDomain.viewId)
        else {
            rescheduleViewAcknowledgementDeadline()
            return
        }
        viewSenderState.resnapshot(oldest.viewDomain, cause: .recovery)
        pendingFileSnapshotByViewDomain.removeValue(forKey: oldest.viewDomain)
        lastSealedFileTargetByViewDomain.removeValue(forKey: oldest.viewDomain)
        pendingReviewSnapshotByViewDomain.removeValue(forKey: oldest.viewDomain)
        finishViewEmissionWaiter(for: oldest.viewDomain, outcome: .resnapshotRequired)
        rescheduleViewAcknowledgementDeadline()
        for lease in producerRegistry.metadataProducerLeases {
            resumeProducerFrameWaiterIfPossible(for: lease)
        }
        await viewResnapshotNeededObserver?(
            .init(
                viewDomain: oldest.viewDomain,
                handle: oldest.handle,
                scopeRevision: scope.revision,
                subscriptionKind: subscription.subscriptionKind
            )
        )
    }

    func sealViewBatch(
        _ batch: BridgeProductSealedViewBatch,
        productAdmission: BridgeProductAdmissionContext
    ) throws -> Bool {
        guard lifecycle == .active,
            productAdmission.withValidAdmission({ true }) == true,
            let current = viewScopeByDomain[batch.viewDomain],
            current.handle == batch.handle,
            current.revision == batch.scopeRevision
        else { return false }
        try viewSenderState.seal(batch)
        nextViewDeliverySequenceByDomain[batch.viewDomain] =
            batch.firstDeliverySequence + batch.parts.count
        for lease in producerRegistry.metadataProducerLeases {
            resumeProducerFrameWaiterIfPossible(for: lease)
        }
        return true
    }

    /// The registry owns the stream sequence; a candidate sender copy commits
    /// its credit reservation only when the exact frame enters that registry.
    func enqueueNextViewFrameIfAvailable(
        for lease: BridgeProductProducerLease,
        admissionAlreadyHeld: Bool = false
    ) throws {
        guard let target = producerRegistry.pendingMetadataFrameTarget(for: lease) else { return }
        guard let productAdmission = productAdmissionByProducerLease[lease] else { return }
        if admissionAlreadyHeld {
            try enqueueNextViewFrameWithAdmission(for: lease, target: target)
        } else {
            _ = try productAdmission.withValidAdmission {
                try enqueueNextViewFrameWithAdmission(for: lease, target: target)
                return true
            }
        }
    }

    private func enqueueNextViewFrameWithAdmission(
        for lease: BridgeProductProducerLease,
        target: (stream: BridgeProductMetadataStreamCorrelation, nextSequence: Int)
    ) throws {
        guard lifecycle == .active else { return }
        try sealPendingFileSnapshotIfReady()
        try sealPendingReviewSnapshotIfReady()
        var proposedSender = viewSenderState
        guard
            let frame = try proposedSender.nextFrame(
                stream: target.stream,
                streamSequence: target.nextSequence,
                admittedAt: viewDeadlineElapsed()
            )
        else {
            // A pending capture can become a no-op without producing another frame.
            finishReadyViewEmissionWaiters()
            return
        }
        let result = try producerRegistry.enqueueNonterminalFrame(
            for: lease,
            build: { streamSequence in
                guard streamSequence == target.nextSequence else {
                    throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
                }
                return .metadata(frame)
            },
            overflowReset: { streamSequence in
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
        )
        switch result {
        case .enqueued:
            viewSenderState = proposedSender
            if frame.kind == "subscription.batchPart" { rescheduleViewAcknowledgementDeadline() }
            finishReadyViewEmissionWaiters()
        case .queueReset:
            break
        case .rejected:
            throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
        }
    }

    private func sealPendingReviewSnapshotIfReady() throws {
        for (viewDomain, snapshot) in pendingReviewSnapshotByViewDomain {
            guard !viewSenderState.hasActiveEmission(for: viewDomain),
                let current = viewScopeByDomain[viewDomain]
            else { continue }
            let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
                .init(
                    viewDomain: viewDomain,
                    handle: current.handle,
                    scopeRevision: current.revision,
                    scope: current.scope,
                    firstDeliverySequence: nextViewDeliverySequenceByDomain[viewDomain] ?? 1,
                    targetRevision: snapshot.targetRevision,
                    publication: snapshot.publication,
                    items: snapshot.items
                )
            )
            try viewSenderState.seal(batch)
            nextViewDeliverySequenceByDomain[viewDomain] = batch.firstDeliverySequence + batch.parts.count
            pendingReviewSnapshotByViewDomain.removeValue(forKey: viewDomain)
        }
    }

    func closeViewDomains(subscriptionId: String) {
        viewScopeWaiterBySubscriptionId.removeValue(forKey: subscriptionId)?.finish()
        for viewDomain in Array(viewScopeByDomain.keys) where viewDomain.viewId == subscriptionId {
            finishViewEmissionWaiter(for: viewDomain, outcome: .retired)
            viewSenderState.close(viewDomain)
            viewScopeByDomain.removeValue(forKey: viewDomain)
            viewAcknowledgementReplayByDomain.removeValue(forKey: viewDomain)
            nextViewDeliverySequenceByDomain.removeValue(forKey: viewDomain)
            pendingFileSnapshotByViewDomain.removeValue(forKey: viewDomain)
            lastSealedFileTargetByViewDomain.removeValue(forKey: viewDomain)
            pendingReviewSnapshotByViewDomain.removeValue(forKey: viewDomain)
        }
        rescheduleViewAcknowledgementDeadline()
    }

    func acceptedViewScope(
        subscriptionId: String
    ) -> BridgeProductAcceptedViewScopeSnapshot? {
        guard
            let viewDomain = viewScopeByDomain.keys.first(where: {
                $0.viewId == subscriptionId && $0.domain == .singleDomain
            }), let current = viewScopeByDomain[viewDomain]
        else { return nil }
        return .init(
            viewDomain: viewDomain,
            handle: current.handle,
            revision: current.revision,
            admissionSequence: current.admissionSequence,
            scope: current.scope
        )
    }

    func awaitAcceptedViewScope(
        subscriptionId: String
    ) async -> BridgeProductAcceptedViewScopeSnapshot? {
        if let current = acceptedViewScope(subscriptionId: subscriptionId), current.revision > 0 {
            return current
        }
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        viewScopeWaiterBySubscriptionId[subscriptionId]?.finish()
        viewScopeWaiterBySubscriptionId[subscriptionId] = continuation
        defer {
            viewScopeWaiterBySubscriptionId.removeValue(forKey: subscriptionId)?.finish()
        }
        for await _ in stream {
            if let current = acceptedViewScope(subscriptionId: subscriptionId), current.revision > 0 {
                return current
            }
        }
        return nil
    }

    func acceptViewScope(
        _ request: BridgeProductViewScopeRequest,
        productAdmission: BridgeProductAdmissionContext
    ) -> BridgeProductRequestErrorCode? {
        guard lifecycle == .active,
            productAdmission.withValidAdmission({ true }) == true
        else { return .staleWorker }
        guard request.domain == BridgeProductViewDomain.singleDomain.rawValue else { return .invalidRequest }
        guard let subscription = subscriptionState.snapshot(subscriptionId: request.subscriptionId),
            subscription.subscriptionKind == request.subscriptionKind
        else { return .unknownSubscription }
        let viewDomain = BridgeProductViewDomainKey(
            viewId: request.subscriptionId,
            domain: .singleDomain,
            incarnation: request.incarnation
        )
        if viewScopeByDomain.contains(where: { element in
            element.key.viewId == request.subscriptionId
                && element.key.domain == .singleDomain
                && element.value.admissionSequence >= request.correlation.requestSequence
        }) {
            return .superseded
        }
        if let current = viewScopeByDomain[viewDomain],
            request.scopeRevision <= current.revision
        {
            return .superseded
        }
        if let current = viewScopeByDomain[viewDomain],
            current.handle == request.handle,
            !BridgeProductViewScopeContract.hasSameMembershipFilter(current.scope, request.scope),
            case .object(let members) = current.scope,
            members["kind"] == .string("comment")
        {
            return .invalidRequest
        }
        if let current = viewScopeByDomain[viewDomain],
            current.handle == request.handle,
            BridgeProductViewScopeContract.hasSameMembershipFilter(current.scope, request.scope)
        {
            guard
                viewSenderState.relabelScanGenerationPreservingEmission(
                    for: viewDomain, to: request.scopeRevision
                )
            else { return .superseded }
            viewScopeByDomain[viewDomain] = .init(
                handle: request.handle,
                revision: request.scopeRevision,
                admissionSequence: request.correlation.requestSequence,
                scope: request.scope
            )
            _ = viewScopeWaiterBySubscriptionId[request.subscriptionId]?.yield(())
            return nil
        }
        for prior in Array(viewScopeByDomain.keys)
        where prior.viewId == request.subscriptionId && prior.domain == .singleDomain {
            finishViewEmissionWaiter(for: prior, outcome: .retired)
            viewScopeByDomain.removeValue(forKey: prior)
            viewAcknowledgementReplayByDomain.removeValue(forKey: prior)
            nextViewDeliverySequenceByDomain.removeValue(forKey: prior)
            pendingFileSnapshotByViewDomain.removeValue(forKey: prior)
            lastSealedFileTargetByViewDomain.removeValue(forKey: prior)
            pendingReviewSnapshotByViewDomain.removeValue(forKey: prior)
        }
        viewSenderState.open(
            viewDomain,
            handle: request.handle,
            scanGeneration: request.scopeRevision
        )
        rescheduleViewAcknowledgementDeadline()
        viewScopeByDomain[viewDomain] = .init(
            handle: request.handle,
            revision: request.scopeRevision,
            admissionSequence: request.correlation.requestSequence,
            scope: request.scope
        )
        _ = viewScopeWaiterBySubscriptionId[request.subscriptionId]?.yield(())
        return nil
    }

    func acceptViewResnapshot(
        _ request: BridgeProductViewResnapshotRequest,
        productAdmission: BridgeProductAdmissionContext
    ) -> BridgeProductRequestErrorCode? {
        guard lifecycle == .active,
            productAdmission.withValidAdmission({ true }) == true
        else { return .staleWorker }
        guard request.domain == BridgeProductViewDomain.singleDomain.rawValue else { return .invalidRequest }
        guard let subscription = subscriptionState.snapshot(subscriptionId: request.subscriptionId),
            subscription.subscriptionKind == request.subscriptionKind
        else { return .unknownSubscription }
        let viewDomain = BridgeProductViewDomainKey(
            viewId: request.subscriptionId,
            domain: .singleDomain,
            incarnation: request.incarnation
        )
        guard let current = viewScopeByDomain[viewDomain],
            current.handle == request.handle,
            current.revision == request.scopeRevision
        else { return .superseded }
        viewSenderState.resnapshot(viewDomain, cause: .requested)
        rescheduleViewAcknowledgementDeadline()
        finishViewEmissionWaiter(for: viewDomain, outcome: .resnapshotRequired)
        pendingFileSnapshotByViewDomain.removeValue(forKey: viewDomain)
        lastSealedFileTargetByViewDomain.removeValue(forKey: viewDomain)
        pendingReviewSnapshotByViewDomain.removeValue(forKey: viewDomain)
        return nil
    }

    func acknowledgeViewReceipt(
        _ request: BridgeProductViewAcknowledgementRequest,
        exactRequestBytes: Data,
        productAdmission: BridgeProductAdmissionContext
    ) -> Data? {
        guard request.paneSessionId == paneSessionId,
            request.workerInstanceId == workerInstanceId,
            request.domain == BridgeProductViewDomain.singleDomain.rawValue,
            productAdmission.withValidAdmission({ true }) == true,
            lifecycle == .active
        else { return nil }

        let viewDomain = BridgeProductViewDomainKey(
            viewId: request.subscriptionId,
            domain: .singleDomain,
            incarnation: request.incarnation
        )
        if let replay = viewAcknowledgementReplayByDomain[viewDomain],
            replay.requestBytes == exactRequestBytes
        {
            return replay.responseBytes
        }
        let returnedCredit = viewSenderState.acknowledge(
            for: viewDomain,
            handle: request.handle,
            through: request.receivedThroughDeliverySequence
        )
        guard
            returnedCredit
                || viewSenderState.acknowledgementWasAlreadySatisfied(
                    for: viewDomain,
                    handle: request.handle,
                    through: request.receivedThroughDeliverySequence
                )
        else { return nil }
        if returnedCredit { rescheduleViewAcknowledgementDeadline() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let responseBytes = try? encoder.encode(BridgeProductViewAcknowledgedResponse(correlating: request))
        else { return nil }
        viewAcknowledgementReplayByDomain[viewDomain] = (
            requestBytes: exactRequestBytes,
            responseBytes: responseBytes
        )
        for lease in producerRegistry.metadataProducerLeases {
            resumeProducerFrameWaiterIfPossible(for: lease)
        }
        return responseBytes
    }
}
