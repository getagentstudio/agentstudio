import AgentStudioInfrastructure
import Foundation

struct BridgeProductViewResnapshotSignal: Equatable, Sendable {
    let viewDomain: BridgeProductViewDomainKey
    let handle: String
    let scopeRevision: Int
    let subscriptionKind: BridgeProductSubscriptionKind
}

enum BridgeProductContentAcknowledgementDisposition: Equatable {
    case accepted
    case refused(BridgeProductContentAcknowledgementRefusalReason)
}

actor BridgeProductSession {
    typealias ProducerLifecycleAcknowledger =
        @Sendable (BridgeProductProducerLifecycleAcknowledgement) async -> Bool
    typealias ProducerFrameWaiterRegistrationObserver = @Sendable (BridgeProductProducerLease) -> Void
    typealias ResultWaiterRegistrationObserver = @Sendable (String) -> Void
    typealias ViewEmissionWaiterRegistrationObserver = @Sendable (BridgeProductViewDomainKey) -> Void
    typealias ViewResnapshotNeededObserver = @Sendable (BridgeProductViewResnapshotSignal) async -> Void

    nonisolated let capabilityAuthenticator: BridgeProductCapabilityAuthenticator
    private let maximumRequestOrResponseBytes: Int
    let deadlineClock: any Clock<Duration> & Sendable
    let viewDeadlineElapsed: @Sendable () -> Duration
    let operationDelay: AsyncDelay
    let paneSessionId: String
    let producerFrameWaiterRegistrationObserver: ProducerFrameWaiterRegistrationObserver?
    let resultWaiterRegistrationObserver: ResultWaiterRegistrationObserver?
    let viewEmissionWaiterRegistrationObserver: ViewEmissionWaiterRegistrationObserver?
    var producerRegistry: BridgeProductProducerRegistry {
        didSet { resumeProducerFrameQuiescenceWaitersIfReady() }
    }
    var producerFrameQuiescenceWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var contentCreditsByProducerLease: [BridgeProductProducerLease: BridgeProductContentCreditReadState] = [:]
    var contentCreditWaitersByProducerLease: [BridgeProductProducerLease: BridgeProductContentCreditWaiter] = [:]
    private var revocationState = BridgeProductSessionRevocationState.idle
    let workerInstanceId: String
    var contentAdmissionByProducerLease: [BridgeProductProducerLease: BridgeProductContentAdmission] = [:]
    var productAdmissionByProducerLease: [BridgeProductProducerLease: BridgeProductAdmissionContext] = [:]
    var producerFrameObservationByLease: [BridgeProductProducerLease: BridgeProductSessionProducerFrameObservation] =
        [:]
    var producerFrameWaitersByLease: [BridgeProductProducerLease: BridgeProductSessionProducerFrameWaiter] = [:]
    var producerRetirementStateByLease: [BridgeProductProducerLease: BridgeProductSessionProducerRetirementState] = [:]
    var controlReplay: BridgeProductControlReplayCache {
        didSet { resumeControlReplayIdleWaitersIfReady() }
    }
    var controlReplayIdleWaiters: [UUID: BridgeProductSessionControlIdleWaiter] = [:]
    var lifecycle: BridgeProductSessionLifecycle = .awaitingOpen
    var activeLifecycleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var pendingControl: BridgeProductSessionPendingControl?
    var pendingScopeOperationIdByView: [BridgeProductViewOperationKey: String] = [:]
    var viewSenderState = BridgeProductViewSenderState(
        maximumDirtyKeys: AppPolicies.Bridge.productViewMaximumDirtyKeys,
        creditParts: AppPolicies.Bridge.productViewCreditParts,
        creditBytes: AppPolicies.Bridge.productViewCreditBytes
    )
    var viewScopeByDomain: [BridgeProductViewDomainKey: BridgeProductAcceptedViewScope] = [:]
    var viewScopeWaiterBySubscriptionId: [String: AsyncStream<Void>.Continuation] = [:]
    var viewAcknowledgementReplayByDomain: [BridgeProductViewDomainKey: (requestBytes: Data, responseBytes: Data)] =
        [:]
    var nextViewDeliverySequenceByDomain: [BridgeProductViewDomainKey: Int] = [:]
    var lastSealedFileTargetByViewDomain: [BridgeProductViewDomainKey: Int] = [:]
    typealias FileCaptureBatchSealer =
        @Sendable (BridgeProductFileViewSnapshotInput, Int?) throws -> BridgeProductSealedViewBatch
    let fileCaptureBatchSealer: FileCaptureBatchSealer
    var pendingFileSnapshotByViewDomain: [BridgeProductViewDomainKey: BridgeWorktreeFileKeyedSnapshot] = [:]
    var pendingReviewSnapshotByViewDomain: [BridgeProductViewDomainKey: BridgeProductReviewKeyedSnapshot] = [:]
    var viewEmissionWaiterByDomain: [BridgeProductViewDomainKey: BridgeProductViewEmissionWaiter] = [:]
    var viewAcknowledgementDeadlineTask: Task<Void, Never>?
    var viewAcknowledgementDeadlineGeneration = 0
    var viewResnapshotNeededObserver: ViewResnapshotNeededObserver?
    var operationTable = BridgeProductOperationTable()
    var observationDeadlineTasksByWaiterId: [UUID: Task<Void, Never>] = [:]
    var activeEscapeEffectIds: Set<UUID> = []
    var escapeEffectTasksById: [UUID: Task<Void, Never>] = [:]
    var protocolSubscriptionDeliveryById: [String: BridgeProductProtocolSubscriptionDelivery] = [:]
    var subscriptionState = BridgeProductSubscriptionState()
    var workerDerivationEpochBySurface: [BridgeProductSurface: Int] = [:]
    /// Subscriptions a surface floor advance ended and whose producers still run,
    /// awaiting hand-off through `takeFloorRetiredSubscriptions()`.
    private var floorRetiredSubscriptions: [BridgeProductSubscriptionSnapshot] = []

    init(
        paneSessionId: String,
        workerInstanceId: String,
        capabilityBytes: [UInt8],
        maximumRequestOrResponseBytes: Int = BridgeProductWireContract.maximumRequestBodyBytes,
        maximumMutationWatches: Int = AppPolicies.Bridge.maximumProductMutationWatches,
        deadlineClock: (any Clock<Duration> & Sendable)? = nil,
        producerQueueLimits: BridgeProductProducerQueueLimits = .productContract,
        producerFrameWaiterRegistrationObserver: ProducerFrameWaiterRegistrationObserver? = nil,
        resultWaiterRegistrationObserver: ResultWaiterRegistrationObserver? = nil,
        viewEmissionWaiterRegistrationObserver: ViewEmissionWaiterRegistrationObserver? = nil,
        fileCaptureBatchSealer: FileCaptureBatchSealer? = nil
    ) throws {
        guard maximumRequestOrResponseBytes > 0,
            maximumRequestOrResponseBytes <= BridgeProductWireContract.maximumRequestBodyBytes
        else {
            throw BridgeProductSessionError.invalidRequestOrResponseByteLimit
        }
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: [])
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: [])
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        self.paneSessionId = paneSessionId
        self.workerInstanceId = workerInstanceId
        self.capabilityAuthenticator = BridgeProductCapabilityAuthenticator(
            encodedCapability: capabilityHeader
        )
        self.maximumRequestOrResponseBytes = maximumRequestOrResponseBytes
        let resolvedDeadlineClock: any Clock<Duration> & Sendable = deadlineClock ?? ContinuousClock()
        self.deadlineClock = resolvedDeadlineClock
        self.viewDeadlineElapsed = Self.elapsedClock(resolvedDeadlineClock)
        self.operationDelay = deadlineClock.map(AsyncDelay.clock) ?? .taskSleep
        self.operationTable = BridgeProductOperationTable(maximumMutationWatches: maximumMutationWatches)
        self.producerFrameWaiterRegistrationObserver = producerFrameWaiterRegistrationObserver
        self.resultWaiterRegistrationObserver = resultWaiterRegistrationObserver
        self.viewEmissionWaiterRegistrationObserver = viewEmissionWaiterRegistrationObserver
        self.fileCaptureBatchSealer =
            fileCaptureBatchSealer ?? { input, base in
                if let base { return try BridgeProductFileViewBatchFactory.sealChange(input, baseRevision: base) }
                return try BridgeProductFileViewBatchFactory.sealSnapshot(input)
            }
        self.producerRegistry = BridgeProductProducerRegistry(
            limits: producerQueueLimits,
            deadlineClock: resolvedDeadlineClock
        )
        self.controlReplay = .init(
            maximumRequestOrResponseBytes: maximumRequestOrResponseBytes
        )
    }

    private static func elapsedClock<ClockValue: Clock & Sendable>(
        _ clock: ClockValue
    ) -> @Sendable () -> Duration where ClockValue.Duration == Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }

    func setViewResnapshotNeededObserver(_ observer: ViewResnapshotNeededObserver?) {
        viewResnapshotNeededObserver = observer
    }

    var snapshot: BridgeProductSessionSnapshot {
        .init(
            controlReplay: controlReplay.snapshot,
            lifecycle: lifecycle,
            pendingRequestKind: pendingControl?.request.kind,
            workerDerivationEpochBySurface: workerDerivationEpochBySurface
        )
    }

    /// Returns, once, the subscriptions a surface floor advance has ended since the
    /// last call. The caller that admitted the advancing control or content request
    /// hands them to the provider, which stops their producers the way a cancel does.
    func takeFloorRetiredSubscriptions() -> [BridgeProductSubscriptionSnapshot] {
        defer { floorRetiredSubscriptions.removeAll(keepingCapacity: false) }
        return floorRetiredSubscriptions
    }

    func registerMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        productAdmission: BridgeProductAdmissionContext,
        operation: @escaping @Sendable (BridgeProductProducerLease) async -> Void
    ) -> BridgeProductProducerRegistration {
        productAdmission.withValidAdmission {
            guard lifecycle == .active else { return .rejected(.inactiveSession) }
            if let pendingControl, case .workerSessionResync = pendingControl.request {
                return .rejected(.closing)
            }
            guard request.paneSessionId == paneSessionId,
                request.workerInstanceId == workerInstanceId
            else {
                return .rejected(.staleWorker)
            }
            let registration = producerRegistry.registerMetadataProducer(
                request: request,
                operation: operation,
                completion: producerCompletion
            )
            if case .accepted(let lease) = registration {
                productAdmissionByProducerLease[lease] = productAdmission
            }
            return registration
        } ?? .rejected(.closing)
    }

    func registerContentProducer(
        request: BridgeProductContentRequest,
        productAdmission: BridgeProductAdmissionContext,
        operation: @escaping @Sendable (BridgeProductProducerLease) async -> Void
    ) -> BridgeProductProducerRegistration {
        productAdmission.withValidAdmission {
            let admission = request.admission
            guard lifecycle == .active else { return .rejected(.inactiveSession) }
            guard admission.paneSessionId == paneSessionId,
                admission.workerInstanceId == workerInstanceId
            else {
                return .rejected(.staleWorker)
            }

            let surface = admission.identity.surface
            let currentEpoch = workerDerivationEpochBySurface[surface, default: 0]
            guard admission.workerDerivationEpoch >= currentEpoch else {
                return .rejected(.staleSurfaceEpoch(currentFloor: currentEpoch))
            }
            advanceSurfaceFloorIfNeeded(
                surface: surface,
                workerDerivationEpoch: admission.workerDerivationEpoch
            )
            let registration = producerRegistry.registerContentProducer(
                request: request,
                operation: operation,
                completion: producerCompletion
            )
            if case .accepted(let lease) = registration {
                contentAdmissionByProducerLease[lease] = admission
                productAdmissionByProducerLease[lease] = productAdmission
                contentCreditsByProducerLease[lease] = .init(
                    admission: admission,
                    credits: &viewSenderState.credits
                )
            }
            return registration
        } ?? .rejected(.closing)
    }

    func enqueueRequiredProducerOpeningFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) throws -> BridgeProductProducerEnqueueResult {
        try productAdmission.withValidAdmission {
            guard producerAdmissionMatches(productAdmission, for: lease) else {
                return .rejected(.unknownLease)
            }
            let result = try producerRegistry.enqueueRequiredOpeningFrame(
                for: lease,
                build: build
            )
            if case .enqueued(let frame) = result,
                contentCreditsByProducerLease[lease] != nil
            {
                precondition(
                    contentCreditsByProducerLease[lease]?.admit(
                        sequence: frame.sequence,
                        byteCount: frame.data.count,
                        credits: &viewSenderState.credits
                    ) == true, "Opening content frame exceeded its empty credit window")
            }
            resumeProducerFrameWaiterIfPossible(for: lease, admissionAlreadyHeld: true)
            return result
        } ?? .rejected(.lifecycleClosed)
    }

    func enqueueRequiredContentOpeningFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) throws -> BridgeProductProducerEnqueueResult {
        try foregroundWorkAdmission.withValidAdmission {
            try enqueueRequiredProducerOpeningFrame(
                for: lease,
                productAdmission: productAdmission,
                build: build
            )
        } ?? .rejected(.lifecycleClosed)
    }

    func enqueueProducerFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame,
        overflowReset: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) throws -> BridgeProductProducerEnqueueResult {
        try productAdmission.withValidAdmission {
            guard producerAdmissionMatches(productAdmission, for: lease) else {
                return .rejected(.unknownLease)
            }
            let result = try producerRegistry.enqueueNonterminalFrame(
                for: lease,
                build: build,
                overflowReset: overflowReset
            )
            resumeProducerFrameWaiterIfPossible(for: lease, admissionAlreadyHeld: true)
            return result
        } ?? .rejected(.lifecycleClosed)
    }

    func enqueueTerminalProducerFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) throws -> BridgeProductProducerEnqueueResult {
        try productAdmission.withValidAdmission {
            guard producerAdmissionMatches(productAdmission, for: lease) else {
                return .rejected(.unknownLease)
            }
            let result = try producerRegistry.enqueueTerminalFrame(for: lease, build: build)
            resumeProducerFrameWaiterIfPossible(for: lease, admissionAlreadyHeld: true)
            return result
        } ?? .rejected(.lifecycleClosed)
    }

    func enqueueTerminalContentFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) async throws -> BridgeProductProducerEnqueueResult {
        try foregroundWorkAdmission.withValidAdmission {
            try enqueueTerminalProducerFrame(
                for: lease,
                productAdmission: productAdmission,
                build: build
            )
        } ?? .rejected(.lifecycleClosed)
    }

    func stopProducer(
        _ lease: BridgeProductProducerLease
    ) async -> Bool {
        guard let stopRequest = producerRegistry.requestStop([lease]).first else {
            return false
        }
        await stopRequest.task?.value
        return producerRegistry.producerIsStopped(lease)
    }

    func unregisterProducer(
        _ lease: BridgeProductProducerLease
    ) -> BridgeProductProducerLifecycleAcknowledgement? {
        guard lifecycle != .revoked,
            producerRetirementStateByLease[lease] == nil
        else { return nil }
        return producerRegistry.unregister(lease)
    }

    func acknowledgeProducerLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) -> Bool {
        guard lifecycle != .revoked else { return false }
        let acknowledged = producerRegistry.acknowledgeLifecycle(acknowledgement)
        if acknowledged {
            contentAdmissionByProducerLease.removeValue(
                forKey: acknowledgement.producerLease
            )
            productAdmissionByProducerLease.removeValue(
                forKey: acknowledgement.producerLease
            )
            contentCreditsByProducerLease.removeValue(forKey: acknowledgement.producerLease)?
                .close(credits: &viewSenderState.credits)
            cancelContentCreditWaiter(for: acknowledgement.producerLease)
        }
        return acknowledged
    }

    func producerSnapshot() -> BridgeProductProducerRegistrySnapshot {
        producerRegistry.snapshot().includingSessionAdmissionResidue(
            contentAdmissionCount: contentAdmissionByProducerLease.count,
            productAdmissionCount: productAdmissionByProducerLease.count
        )
    }

    func hasContentAdmission(contentRequestId: String, leaseId: String) -> Bool {
        contentAdmissionByProducerLease.values.contains {
            $0.contentRequestId == contentRequestId && $0.leaseId == leaseId
        }
    }

    // Nil means live or unowned residue, empty means clear, and nonempty contains only
    // the existing barriers for metadata producers whose retirement is already in flight.
    func metadataRetirementBarriersForReload() -> [BridgeProductProducerRetirementBarrier]? {
        let metadataProducerLeases = producerRegistry.metadataProducerLeases
        guard !metadataProducerLeases.isEmpty else { return [] }
        var retirementBarriers: [BridgeProductProducerRetirementBarrier] = []
        for lease in metadataProducerLeases {
            guard let retirementBarrier = producerRetirementStateByLease[lease]?.barrier else {
                return nil
            }
            retirementBarriers.append(retirementBarrier)
        }
        return retirementBarriers
    }

    func subscriptionSnapshots() -> [BridgeProductSubscriptionSnapshot] {
        subscriptionState.snapshots()
    }

    private var producerCompletion: BridgeProductProducerRegistry.ProducerCompletion {
        { [weak self] lease in
            await self?.producerOperationFinished(lease)
        }
    }

    func producerAdmissionMatches(
        _ productAdmission: BridgeProductAdmissionContext,
        for lease: BridgeProductProducerLease
    ) -> Bool {
        productAdmissionByProducerLease[lease]?.matches(productAdmission) == true
    }

    func authorizes(presentedCapability: String) -> Bool {
        guard lifecycle != .revoked else { return false }
        return capabilityMatches(presentedCapability)
    }

    /// A retired command still needs authenticated ingress so admission can
    /// return a correlated refusal; it cannot execute after lifecycle fencing.
    func authenticatesControlCapability(_ presentedCapability: String) -> Bool {
        capabilityMatches(presentedCapability)
    }

    func acknowledgeContentFrameObservation(
        _ acknowledgement: BridgeProductContentFrameAcknowledgement,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        contentAcknowledgementDisposition(
            acknowledgement,
            productAdmission: productAdmission
        ) == .accepted
    }

    func contentAcknowledgementDisposition(
        _ acknowledgement: BridgeProductContentFrameAcknowledgement,
        productAdmission: BridgeProductAdmissionContext
    ) -> BridgeProductContentAcknowledgementDisposition {
        productAdmission.withValidAdmission {
            guard lifecycle == .active,
                acknowledgement.paneSessionId == paneSessionId,
                acknowledgement.workerInstanceId == workerInstanceId
            else {
                return .refused(.invalidReadIdentity)
            }
            guard
                let entry = contentAdmissionByProducerLease.first(where: {
                    $0.value.contentRequestId == acknowledgement.contentRequestId
                })
            else { return .refused(.unknownRead) }
            let (lease, admission) = entry
            guard admission.leaseId == acknowledgement.leaseId,
                admission.paneSessionId == acknowledgement.paneSessionId,
                admission.workerInstanceId == acknowledgement.workerInstanceId,
                producerAdmissionMatches(productAdmission, for: lease)
            else { return .refused(.invalidReadIdentity) }
            guard
                contentCreditsByProducerLease[lease]?.acknowledge(
                    through: acknowledgement.receivedThroughContentSequence,
                    credits: &viewSenderState.credits
                ) == true
            else { return .refused(.invalidSequence) }
            resumeContentCreditWaiterIfPossible(for: lease)
            return .accepted
        } ?? .refused(.invalidReadIdentity)
    }

    func beginControl(
        exactRequestBytes: Data,
        presentedCapability: String,
        productAdmission: BridgeProductAdmissionContext,
        reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource? = nil
    ) -> BridgeProductSessionControlAdmission {
        guard capabilityMatches(presentedCapability) else { return .rejected(.unauthorized) }
        guard
            (productAdmission.withValidAdmission { true }) == true
        else {
            return .admissionClosed
        }
        guard exactRequestBytes.count <= maximumRequestOrResponseBytes else {
            return .rejected(.payloadTooLarge)
        }
        guard
            let request = try? BridgeProductStrictJSON.decode(
                BridgeProductControlRequest.self,
                from: exactRequestBytes
            )
        else {
            return .rejected(.invalidRequest)
        }
        guard request.paneSessionId == paneSessionId,
            request.workerInstanceId == workerInstanceId
        else {
            return .rejected(.init(reason: .staleWorker, request: request))
        }

        return productAdmission.withValidAdmission {
            beginValidatedControl(
                exactRequestBytes: exactRequestBytes,
                request: request,
                productAdmission: productAdmission,
                reviewIntentAdmissionSource: reviewIntentAdmissionSource
            )
        } ?? .admissionClosed
    }

    private func beginValidatedControl(
        exactRequestBytes: Data,
        request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext,
        reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource?
    ) -> BridgeProductSessionControlAdmission {
        guard lifecycle != .revoked else { return .rejected(.revoked) }
        if pendingControl != nil {
            return .rejected(
                .init(
                    reason: .requestInFlight(
                        nextExpectedRequestSequence: controlReplay.snapshot.nextExpectedRequestSequence
                    ),
                    request: request
                )
            )
        }
        if request.requestSequence == controlReplay.snapshot.nextExpectedRequestSequence,
            !request.isSlotFreeEscape,
            !operationTable.hasCapacity(for: operationWaitKind(for: request))
        {
            return .rejected(.init(reason: .resultCapacityExhausted, request: request))
        }
        if request.requestSequence == controlReplay.snapshot.nextExpectedRequestSequence,
            operationIsMutation(request),
            !operationTable.hasMutationWatchCapacity
        {
            return .rejected(.init(reason: .mutationWatchCapacityExhausted, request: request))
        }

        switch controlReplay.begin(
            requestSequence: request.requestSequence,
            exactRequestBytes: exactRequestBytes
        ) {
        case .replay(let exactResponseBytes):
            return .replay(exactResponseBytes: exactResponseBytes)
        case .rejected(let rejection):
            return .rejected(
                .init(
                    reason: .init(replayRejection: rejection),
                    request: request
                )
            )
        case .execute(let token):
            if let viewSubscription = request.viewControlSubscription,
                subscriptionState.snapshot(subscriptionId: viewSubscription.id)?.subscriptionKind
                    != viewSubscription.kind
            {
                try? controlReplay.abandon(token: token)
                return .rejected(.init(reason: .unknownSubscription, request: request))
            }
            if let streamProgressRejection = streamProgressRejection(for: request) {
                try? controlReplay.abandon(token: token)
                return .rejected(
                    .init(reason: streamProgressRejection, request: request)
                )
            }
            guard
                let deferredResyncEpochs = prepare(
                    request: request,
                    productAdmission: productAdmission,
                    reviewIntentAdmissionSource: reviewIntentAdmissionSource
                )
            else {
                try? controlReplay.abandon(token: token)
                return rejectionForUnpreparedRequest(request)
            }
            pendingControl = .init(
                deferredResyncEpochs: deferredResyncEpochs,
                productAdmission: productAdmission,
                request: request,
                token: token
            )
            return .execute(token: token, request: request)
        }
    }

    func completeControl(
        token: BridgeProductControlAdmissionToken,
        exactResponseBytes: Data
    ) async throws -> BridgeProductSessionCompletionEffect {
        guard let operation = operationTable.entry(for: token), operation.settlement == nil else {
            throw BridgeProductSessionError.invalidAdmissionToken
        }
        let pendingControl = operation.admission
        guard
            (pendingControl.productAdmission.withValidAdmission { true }) == true
        else {
            return .noEffect
        }
        guard exactResponseBytes.count <= maximumRequestOrResponseBytes,
            let response = try? BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: exactResponseBytes
            )
        else {
            throw BridgeProductSessionError.invalidControlResponse
        }
        guard response.correlation == pendingControl.request.correlation else {
            throw BridgeProductSessionError.mismatchedControlResponse
        }
        try BridgeProductSessionControlTransitionBuilder.validateResponseShape(
            request: pendingControl.request,
            response: response
        )

        if lifecycle == .revoked || pendingControlIsStale(pendingControl) {
            return .noEffect
        }

        let transition: BridgeProductSessionControlTransition
        do {
            transition = try BridgeProductSessionControlTransitionBuilder.prepare(
                request: pendingControl.request,
                response: response,
                subscriptionState: subscriptionState,
                resyncEpochs: pendingControl.deferredResyncEpochs,
                currentEpochs: workerDerivationEpochBySurface,
                snapshotRequiredSubscriptionIds: subscriptionsRequiringSnapshot(for: pendingControl.request)
            )
        } catch let stateError as BridgeProductSubscriptionStateError {
            throw BridgeProductSessionError.subscriptionStateRejected(stateError)
        }

        let committedEffect = try pendingControl.productAdmission.withValidAdmission {
            if case .resynced = transition.effect {
                // The resync reconciliation reports every subscription this floor
                // retires, and the provider stops their producers from that outcome.
                for (surface, epoch) in pendingControl.deferredResyncEpochs {
                    advanceSurfaceFloorIfNeeded(
                        surface: surface,
                        workerDerivationEpoch: epoch,
                        endsRetiredSubscriptions: false
                    )
                }
            }
            try admitRequiredProtocolLifecycleFrame(
                for: transition.effect,
                admissionAlreadyHeld: true
            )
            subscriptionState = transition.subscriptionState
            if case .resynced(let resyncResult) = transition.effect {
                reconcileProtocolSubscriptionDeliveries(resyncResult)
            }
            applyCompletedLifecycle(
                request: pendingControl.request,
                response: response
            )
            return transition.effect
        }
        return committedEffect ?? .noEffect
    }

    func settleControlProviderDispatch(
        token: BridgeProductControlAdmissionToken
    ) async {
        guard let operation = operationTable.entry(for: token), operation.settlement == nil else {
            return
        }
        if lifecycle != .revoked, case .workerSessionOpen = operation.admission.request {
            lifecycle = .awaitingOpen
        }
        let outcome: BridgeProductOperationSettlement =
            operation.isMutation && operation.didDispatchMutation ? .outcomeUnknown : .failed
        _ = operationTable.settle(.init(operationId: operation.operationId, outcome: outcome))
    }

    func abandonControl(token: BridgeProductControlAdmissionToken) throws {
        guard let pendingControl, pendingControl.token == token else {
            throw BridgeProductSessionError.invalidAdmissionToken
        }
        try controlReplay.abandon(token: token)
        if case .workerSessionOpen = pendingControl.request {
            lifecycle = .awaitingOpen
        }
        self.pendingControl = nil
    }

    func revoke(
        acknowledgeLifecycle: @escaping ProducerLifecycleAcknowledger
    ) -> BridgeProductSessionRevocationBarrier {
        switch revocationState {
        case .idle:
            break
        case .inFlight(let barrier):
            return barrier
        case .succeeded(let id):
            return BridgeProductSessionRevocationBarrier(id: id, completedResult: true)
        }
        lifecycle = .revoked
        viewAcknowledgementDeadlineTask?.cancel()
        viewAcknowledgementDeadlineTask = nil
        viewResnapshotNeededObserver = nil
        finishAllViewEmissionWaiters()
        let controlIdleWaiters = Array(controlReplayIdleWaiters.values)
        controlReplayIdleWaiters.removeAll(keepingCapacity: false)
        for waiter in controlIdleWaiters { waiter.continuation.resume(returning: false) }
        let frameWaiters = Array(producerFrameQuiescenceWaiters.values)
        producerFrameQuiescenceWaiters.removeAll(keepingCapacity: false)
        for waiter in frameWaiters { waiter.resume(returning: false) }
        let activeWaiters = Array(activeLifecycleWaiters.values)
        activeLifecycleWaiters.removeAll(keepingCapacity: false)
        for waiter in activeWaiters { waiter.resume(returning: false) }
        for lease in contentCreditWaitersByProducerLease.keys {
            cancelContentCreditWaiter(for: lease)
        }
        for readState in contentCreditsByProducerLease.values {
            readState.close(credits: &viewSenderState.credits)
        }
        contentCreditsByProducerLease.removeAll(keepingCapacity: false)
        if let pendingControl {
            try? controlReplay.abandon(token: pendingControl.token)
            self.pendingControl = nil
        }
        operationTable.cancelAndForgetAllOperations()
        for deadlineTask in observationDeadlineTasksByWaiterId.values { deadlineTask.cancel() }
        observationDeadlineTasksByWaiterId.removeAll(keepingCapacity: false)
        for task in escapeEffectTasksById.values { task.cancel() }
        subscriptionState.revokeWorker()
        protocolSubscriptionDeliveryById.removeAll(keepingCapacity: false)
        let producerResidueLeases = producerRegistry.lifecycleResidueLeases()
        let stopRequests = producerRegistry.requestStopEveryProducer(revoking: true)
        let stopRequestByLease = Dictionary(
            uniqueKeysWithValues: stopRequests.map { ($0.lease, $0) }
        )
        let retirementBarriers = producerResidueLeases.map { lease in
            beginProducerRetirement(
                lease,
                acknowledgeLifecycle: acknowledgeLifecycle,
                stopRequest: stopRequestByLease[lease],
                abandonOutstandingDelivery: true
            )
        }
        let revocationId = UUID()
        let barrier = BridgeProductSessionRevocationBarrier(
            id: revocationId,
            task: Task { [self] in
                var didRevoke = true
                for retirementBarrier in retirementBarriers {
                    guard await retirementBarrier.wait() else {
                        didRevoke = false
                        break
                    }
                }
                didRevoke = didRevoke && producerRegistry.snapshot().hasZeroResidue
                revocationState = didRevoke ? .succeeded(id: revocationId) : .idle
                return didRevoke
            }
        )
        revocationState = .inFlight(barrier)
        return barrier
    }

    private func prepare(
        request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext,
        reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource?
    ) -> [BridgeProductSurface: Int]? {
        switch request {
        case .workerSessionOpen:
            guard lifecycle == .awaitingOpen else { return nil }
            lifecycle = .opening
            return [:]
        case .workerSessionResync(let resyncRequest):
            guard lifecycle == .active,
                resyncRequest.lastAcceptedRequestSequence
                    < BridgeProductWireContract.maximumSafeInteger,
                resyncRequest.lastAcceptedRequestSequence + 1 == request.requestSequence
            else {
                return nil
            }
            return preflightResyncEpochs(resyncRequest.activeSubscriptions)
        case .viewScope, .viewResnapshot:
            guard lifecycle == .active,
                let viewSubscription = request.viewControlSubscription,
                let subscription = subscriptionState.snapshot(subscriptionId: viewSubscription.id),
                let surface = request.surface,
                subscription.workerDerivationEpoch >= workerDerivationEpochBySurface[surface, default: 0]
            else { return nil }
            return [surface: subscription.workerDerivationEpoch]
        case .productCall, .subscriptionOpen, .subscriptionCancel:
            guard lifecycle == .active,
                let surface = request.surface,
                let workerDerivationEpoch = request.workerDerivationEpoch
            else {
                return nil
            }
            let currentEpoch = workerDerivationEpochBySurface[surface, default: 0]
            guard workerDerivationEpoch >= currentEpoch else { return nil }
            advanceSurfaceFloorIfNeeded(
                surface: surface,
                workerDerivationEpoch: workerDerivationEpoch
            )
            if case .productCall(let productCallRequest) = request,
                case .reviewComparisonUpdate = productCallRequest.call,
                surface == .review
            {
                reviewIntentAdmissionSource?.admitReviewComparisonIntent(
                    workerDerivationEpoch: workerDerivationEpoch,
                    productAdmission: productAdmission
                )
            }
            return [:]
        }
    }

    private func pendingControlIsStale(
        _ pendingControl: BridgeProductSessionPendingControl
    ) -> Bool {
        if let surface = pendingControl.request.surface,
            let admittedEpoch = pendingControl.request.workerDerivationEpoch
        {
            return admittedEpoch < workerDerivationEpochBySurface[surface, default: 0]
        }
        return pendingControl.deferredResyncEpochs.contains { surface, admittedEpoch in
            admittedEpoch < workerDerivationEpochBySurface[surface, default: 0]
        }
    }

    private func producerOperationFinished(_ lease: BridgeProductProducerLease) {
        producerRegistry.producerOperationFinished(lease)
        resumeProducerFrameWaiterIfPossible(for: lease)
    }

    /// Raises the surface floor. Native refuses controls below it from then on, so
    /// every subscription admitted below it ends here: its record and delivery go,
    /// an `epoch_retired` reset tells the worker, and the admitting caller hands it
    /// to the provider to stop its producers. Nothing is dropped silently.
    private func advanceSurfaceFloorIfNeeded(
        surface: BridgeProductSurface,
        workerDerivationEpoch: Int,
        endsRetiredSubscriptions: Bool = true
    ) {
        let currentEpoch = workerDerivationEpochBySurface[surface, default: 0]
        guard workerDerivationEpoch > currentEpoch else { return }

        workerDerivationEpochBySurface[surface] = workerDerivationEpoch
        let retiredSubscriptions = subscriptionState.retireSubscriptions(
            on: surface,
            belowWorkerDerivationEpoch: workerDerivationEpoch
        )
        if endsRetiredSubscriptions {
            endFloorRetiredSubscriptions(retiredSubscriptions)
            floorRetiredSubscriptions.append(contentsOf: retiredSubscriptions)
        }
        let staleLeases = contentAdmissionByProducerLease.compactMap { entry -> BridgeProductProducerLease? in
            let (lease, admission) = entry
            guard admission.identity.surface == surface,
                admission.workerDerivationEpoch < workerDerivationEpoch
            else {
                return nil
            }
            return lease
        }
        for staleLease in staleLeases {
            abandonProducerFrameDelivery(for: staleLease)
        }
        _ = producerRegistry.requestStop(staleLeases)
    }

}

extension BridgeProductSession {
    private func applyCompletedLifecycle(
        request: BridgeProductControlRequest,
        response: BridgeProductControlResponse
    ) {
        switch (request, response) {
        case (.workerSessionOpen, .workerSessionAccepted):
            lifecycle = .active
            let activeWaiters = Array(activeLifecycleWaiters.values)
            activeLifecycleWaiters.removeAll(keepingCapacity: false)
            for waiter in activeWaiters { waiter.resume(returning: true) }
        case (.workerSessionOpen, .requestError):
            lifecycle = .awaitingOpen
        case (.workerSessionResync, .resyncAccepted):
            break
        default:
            break
        }
    }

    private func capabilityMatches(_ presentedCapability: String) -> Bool {
        capabilityAuthenticator.matches(presentedCapability)
    }
}
