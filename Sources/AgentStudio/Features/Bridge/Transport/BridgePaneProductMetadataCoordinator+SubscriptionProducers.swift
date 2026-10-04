import AgentStudioInfrastructure
import Foundation

private struct BridgeWorktreeAnnotationSubscriptionOpenRequest {
    let activeStream: BridgePaneProductMetadataCoordinator.ActiveStream
    let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    let productAdmission: BridgeProductAdmissionContext
    let subscription: BridgeProductSubscriptionSnapshot
    let surface: BridgeProductSurface
}

private struct BridgeFileSurfaceAttemptBootstrapContext: Sendable {
    let attempt: BridgeFileSurfaceReconciler.Attempt
    let subscription: BridgeProductSubscriptionSnapshot
    let activeStream: BridgePaneProductMetadataCoordinator.ActiveStream
    let productAdmission: BridgeProductAdmissionContext
    let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
}

struct BridgePaneProductMetadataNativeAdapter: Sendable {
    typealias Operation =
        @Sendable (
            isolated BridgePaneProductMetadataCoordinator,
            BridgeProductSubscriptionSnapshot,
            BridgePaneProductMetadataCoordinator.ActiveStream,
            BridgeProductAdmissionContext,
            BridgePaneRefreshWorkAdmission,
            BridgeTraceContext?,
            BridgeProductSurface
        ) async throws -> Void
    typealias Cancellation =
        @Sendable (
            isolated BridgePaneProductMetadataCoordinator,
            String
        ) async -> Void

    let open: Operation
    let cancel: Cancellation

    init(
        open: @escaping Operation,
        cancel: @escaping Cancellation
    ) {
        self.open = open
        self.cancel = cancel
    }
}

struct BridgePaneProductMetadataNativeApplication: Sendable {
    let registration: AnyBridgeProductMetadataApplicationProtocol
    let adapter: BridgePaneProductMetadataNativeAdapter
}

struct BridgePaneProductMetadataNativeApplicationRegistry: Sendable {
    static let product: Self = {
        do {
            return try Self(applications: [
                .init(
                    registration: AnyBridgeProductMetadataApplicationProtocol(
                        BridgeProductFileAnnotationsMetadataApplication.self
                    ),
                    adapter: BridgePaneProductMetadataCoordinator.annotationNativeAdapter
                ),
                .init(
                    registration: AnyBridgeProductMetadataApplicationProtocol(
                        BridgeProductFileMetadataApplication.self
                    ),
                    adapter: BridgePaneProductMetadataCoordinator.fileMetadataNativeAdapter
                ),
                .init(
                    registration: AnyBridgeProductMetadataApplicationProtocol(
                        BridgeProductReviewAnnotationsMetadataApplication.self
                    ),
                    adapter: BridgePaneProductMetadataCoordinator.annotationNativeAdapter
                ),
                .init(
                    registration: AnyBridgeProductMetadataApplicationProtocol(
                        BridgeProductReviewMetadataApplication.self
                    ),
                    adapter: BridgePaneProductMetadataCoordinator.reviewMetadataNativeAdapter
                ),
            ])
        } catch {
            preconditionFailure("Invalid static Bridge metadata native application registry: \(error)")
        }
    }()

    let schemaRegistry: BridgeProductMetadataApplicationRegistry
    private let applicationByKind: [BridgeProductSubscriptionKind: BridgePaneProductMetadataNativeApplication]

    init(applications: [BridgePaneProductMetadataNativeApplication]) throws {
        self.schemaRegistry = try BridgeProductMetadataApplicationRegistry(
            registrations: applications.map(\.registration)
        )
        self.applicationByKind = Dictionary(
            uniqueKeysWithValues: applications.map { ($0.registration.kind, $0) }
        )
    }

    func application(
        for kind: BridgeProductSubscriptionKind
    ) throws -> BridgePaneProductMetadataNativeApplication {
        guard let application = applicationByKind[kind] else {
            throw BridgeProductMetadataApplicationRegistryError.unknownKind(kind)
        }
        return application
    }
}

extension BridgeProductMetadataApplicationRegistry {
    static var product: Self {
        BridgePaneProductMetadataNativeApplicationRegistry.product.schemaRegistry
    }
}

extension BridgePaneProductMetadataCoordinator {
    func startSubscriptionOpen(
        _ subscription: BridgeProductSubscriptionSnapshot,
        activeStream: ActiveStream,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        fileSurfaceAttempt suppliedFileSurfaceAttempt: BridgeFileSurfaceReconciler.Attempt? = nil
    ) async {
        var fileSurfaceAttempt = suppliedFileSurfaceAttempt
        if subscription.subscriptionKind == .fileMetadata, fileSurfaceAttempt == nil,
            let inputBasis = await fileSurfaceInputBasis(
                for: subscription,
                activeStream: activeStream
            )
        {
            let action: BridgeFileSurfaceReconciler.Action
            if await fileSurfaceReconciler.currentInputBasis == inputBasis {
                action = await fileSurfaceReconciler.beginAttempt(inputBasis: inputBasis)
            } else {
                action = await fileSurfaceReconciler.inputsChanged(to: inputBasis)
            }
            switch action {
            case .start(let attempt), .restart(_, let attempt):
                fileSurfaceAttempt = attempt
            case .completed, .rest, .failed:
                return
            }
        }
        let selectedFileSurfaceAttempt = fileSurfaceAttempt
        let fileSurfaceAttemptContext = selectedFileSurfaceAttempt.map {
            BridgeFileSurfaceAttemptBootstrapContext(
                attempt: $0,
                subscription: subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        }
        openedSourceSubscriptionIds.remove(subscription.subscriptionId)
        producerTaskLifecycle.startBootstrapTask(
            subscriptionId: subscription.subscriptionId,
            subscriptionKind: subscription.subscriptionKind,
            executionContext: .init(
                foregroundWorkAdmission: foregroundWorkAdmission,
                metadataLease: activeStream.lease,
                productAdmission: productAdmission,
                session: activeStream.session,
                fileSurfaceAttempt: selectedFileSurfaceAttempt
            ),
            taskFinished: { [weak self] subscriptionId, taskId, completion, error in
                guard let self else { return }
                await self.bootstrapProducerTaskFinished(
                    subscriptionId: subscriptionId,
                    taskId: taskId,
                    completion: completion,
                    error: error,
                    fileSurfaceAttemptContext: fileSurfaceAttemptContext
                )
            },
            operation: { traceContext in
                guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
                    throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
                }
                let application = try self.nativeApplicationRegistry.application(
                    for: subscription.subscriptionKind
                )
                try await application.adapter.open(
                    self,
                    subscription,
                    activeStream,
                    productAdmission,
                    foregroundWorkAdmission,
                    traceContext,
                    application.registration.surface
                )
                guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
                    throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
                }
                await self.recordSourceOpened(
                    subscriptionId: subscription.subscriptionId,
                    activeStream: activeStream,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission
                )
                if subscription.subscriptionKind == .fileMetadata {
                    if let scope = await activeStream.session.acceptedViewScope(
                        subscriptionId: subscription.subscriptionId
                    ) {
                        await self.applyAcceptedFileViewDemand(
                            subscriptionId: subscription.subscriptionId,
                            expectedHandle: scope.handle,
                            expectedRevision: scope.revision,
                            forceRecapture: true,
                            productAdmission: productAdmission
                        )
                    }
                } else if subscription.subscriptionKind == .reviewMetadata {
                    _ = try await self.publishReviewViewSnapshot(
                        subscriptionId: subscription.subscriptionId,
                        productAdmission: productAdmission
                    )
                }
            }
        )
    }

    func fileSurfaceInputBasis(
        for subscription: BridgeProductSubscriptionSnapshot,
        activeStream: ActiveStream
    ) async -> BridgeFileSurfaceInputBasis? {
        guard let source = subscription.subscription.fileMetadataSource else { return nil }
        let acceptedScope = await activeStream.session.acceptedViewScope(
            subscriptionId: subscription.subscriptionId
        )
        return .admitted(source: source, scope: acceptedScope?.scope)
    }

    func retryFailedFileSurface(productAdmission: BridgeProductAdmissionContext) async {
        guard let activeStream,
            activeStream.productAdmission.matches(productAdmission),
            productAdmission.withValidAdmission({ true }) == true,
            let subscriptionId = subscriptionKindById.keys.sorted().first(where: {
                subscriptionKindById[$0] == .fileMetadata
            }),
            let subscription = await activeStream.session.subscriptionSnapshot(
                subscriptionId: subscriptionId
            ),
            let foregroundWorkAdmission = refreshWorkAdmissionSource.acquire()
        else { return }
        guard case .start(let attempt) = await fileSurfaceReconciler.retry() else { return }
        await startSubscriptionOpen(
            subscription,
            activeStream: activeStream,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            fileSurfaceAttempt: attempt
        )
    }

    private func openWorktreeAnnotationSubscription(
        _ request: BridgeWorktreeAnnotationSubscriptionOpenRequest
    ) async throws {
        let producerID = UUIDv7.generate()
        guard let worktreeID = await annotationSource.admittedWorktreeID(),
            let view = await request.activeStream.session.awaitAcceptedViewScope(
                subscriptionId: request.subscription.subscriptionId
            ),
            case .object(let scopeMembers) = view.scope,
            case .string(worktreeID)? = scopeMembers["worktreeId"],
            case .array? = scopeMembers["sessionIds"]
        else { throw WorktreeAnnotationServiceError.unavailable }
        try await annotationSource.acceptBatchScope(
            handle: view.handle,
            worktreeID: worktreeID,
            scopeRevision: view.revision
        )
        let session = request.activeStream.session
        let subscriptionID = request.subscription.subscriptionId
        let productAdmission = request.productAdmission
        let foregroundWorkAdmission = request.foregroundWorkAdmission
        do {
            try await annotationSource.openBatch(handle: view.handle, producerID: producerID) { catalogBatch, mode in
                guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
                    throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
                }
                guard
                    try await session.sealCommentCatalogBatch(
                        subscriptionId: subscriptionID,
                        catalogBatch: catalogBatch,
                        mode: mode,
                        productAdmission: productAdmission
                    )
                else { throw WorktreeAnnotationServiceError.staleSourceEpoch }
                await annotationSource.recordSealedCommentCatalogBatch(
                    handle: view.handle,
                    producerID: producerID,
                    batch: catalogBatch
                )
                switch await session.awaitViewEmissionCompletion(for: view.viewDomain, handle: view.handle) {
                case .completed, .resnapshotRequired:
                    return
                case .retired:
                    throw WorktreeAnnotationServiceError.staleSourceEpoch
                }
            }
        } catch {
            await annotationSource.releaseProducerBatchScope(handle: view.handle, producerID: producerID)
            throw error
        }
        await annotationSource.releaseProducerBatchScope(handle: view.handle, producerID: producerID)
    }

    private func openFileMetadataSubscription(
        _ subscription: BridgeProductSubscriptionSnapshot,
        activeStream: ActiveStream,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        traceContext: BridgeTraceContext?
    ) async throws {
        try await fileMetadataSource.open(
            subscription: subscription,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        ) { _ in
            _ = try await self.publishFileViewCapture(
                subscriptionId: subscription.subscriptionId,
                productAdmission: productAdmission
            )
            guard
                let view = await activeStream.session.acceptedViewScope(
                    subscriptionId: subscription.subscriptionId),
                let demand = try? BridgeProductViewScopeContract.fileDemand(from: view.scope),
                let capture = await self.fileMetadataSource.captureKeyedSnapshot(
                    subscriptionId: subscription.subscriptionId,
                    demand: .init(
                        admissionSequence: view.admissionSequence, handle: view.handle,
                        scopeRevision: view.revision, state: demand),
                    productAdmission: productAdmission), capture.isEnumerationComplete
            else { return }
            switch await activeStream.session.awaitViewEmissionCompletion(for: view.viewDomain, handle: view.handle) {
            case .completed:
                return
            case .resnapshotRequired, .retired:
                throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
            }
        }
    }

    private func openReviewMetadataSubscription(
        _ subscription: BridgeProductSubscriptionSnapshot,
        activeStream: ActiveStream,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        traceContext: BridgeTraceContext?
    ) async throws {
        try await reviewMetadataSource.open(
            subscription: subscription,
            productAdmission: productAdmission
        )
        await replayCommittedReviewPublicationIfPresent(
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            traceContext: traceContext
        )
    }

    private func bootstrapProducerTaskFinished(
        subscriptionId: String,
        taskId: UUID,
        completion: BridgePaneProductMetadataProducerCompletion,
        error: (any Error)?,
        fileSurfaceAttemptContext: BridgeFileSurfaceAttemptBootstrapContext?
    ) async {
        let completedCurrentTask = producerTaskLifecycle.bootstrapTaskFinished(
            subscriptionId: subscriptionId,
            taskId: taskId
        )
        guard completedCurrentTask else {
            if let fileSurfaceAttemptContext {
                _ = await fileSurfaceReconciler.builderCancelled(fileSurfaceAttemptContext.attempt)
                await fileSurfaceReconciler.retirementCompleted(fileSurfaceAttemptContext.attempt)
            }
            return
        }
        if completion == .interrupted, subscriptionKindById[subscriptionId] != nil {
            // Acceptance permits concurrent interests, but an interrupted bootstrap
            // may have released its source. Resume must establish that source again.
            openedSourceSubscriptionIds.remove(subscriptionId)
            deferredOpenSubscriptionIds.insert(subscriptionId)
        }
        if let fileSurfaceAttemptContext {
            let fileSurfaceAttempt = fileSurfaceAttemptContext.attempt
            if completion == .interrupted {
                let isAutomaticRestartEligible =
                    activeStream?.lease
                    == fileSurfaceAttemptContext.activeStream.lease
                    && fileSurfaceAttemptContext.productAdmission.withValidAdmission({ true }) == true
                    && fileSurfaceAttemptContext.foregroundWorkAdmission.withValidAdmission({ true }) == true
                let interruptionAction = await fileSurfaceReconciler.builderCancelled(
                    fileSurfaceAttempt,
                    phase: .delivery,
                    isAutomaticRestartEligible: isAutomaticRestartEligible
                )
                await fileSurfaceReconciler.retirementCompleted(fileSurfaceAttempt)
                await handleFileSurfaceAction(
                    interruptionAction,
                    subscription: fileSurfaceAttemptContext.subscription,
                    activeStream: fileSurfaceAttemptContext.activeStream,
                    productAdmission: fileSurfaceAttemptContext.productAdmission,
                    foregroundWorkAdmission: fileSurfaceAttemptContext.foregroundWorkAdmission
                )
            } else {
                let action: BridgeFileSurfaceReconciler.Action
                if let error {
                    let newerInputBasis: BridgeFileSurfaceInputBasis?
                    if (error as? BridgeWorktreeProductConstructionError) == .invalidated {
                        let currentInputBasis = await fileSurfaceReconciler.currentInputBasis
                        newerInputBasis =
                            await fileSurfaceInputBasis(
                                for: fileSurfaceAttemptContext.subscription,
                                activeStream: fileSurfaceAttemptContext.activeStream
                            ) ?? currentInputBasis
                    } else {
                        newerInputBasis = nil
                    }
                    action = await fileSurfaceReconciler.builderFailed(
                        fileSurfaceAttempt,
                        error: error,
                        phase: .build,
                        newerInputBasis: newerInputBasis
                    )
                } else {
                    action = await fileSurfaceReconciler.builderFinished(
                        fileSurfaceAttempt,
                        outcome: .built
                    )
                }
                await handleFileSurfaceAction(
                    action,
                    subscription: fileSurfaceAttemptContext.subscription,
                    activeStream: fileSurfaceAttemptContext.activeStream,
                    productAdmission: fileSurfaceAttemptContext.productAdmission,
                    foregroundWorkAdmission: fileSurfaceAttemptContext.foregroundWorkAdmission,
                    retiringAttemptFinished: true
                )
            }
        }
        if completion == .interrupted,
            let fileSurfaceAttemptContext,
            activeStream?.lease == fileSurfaceAttemptContext.activeStream.lease,
            fileSurfaceAttemptContext.productAdmission.withValidAdmission({ true }) == true
        {
            await resumeForegroundWork()
        }
        if completion == .resetEnqueued {
            await retireSubscriptionAfterReset(subscriptionId: subscriptionId)
        }
    }

    func handleFileSurfaceAction(
        _ action: BridgeFileSurfaceReconciler.Action,
        subscription: BridgeProductSubscriptionSnapshot,
        activeStream: ActiveStream,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        retiringAttemptFinished: Bool = false
    ) async {
        switch action {
        case .completed:
            await recordCurrentFileRefreshFailure(nil)
        case .failed(let failure):
            await recordCurrentFileRefreshFailure(failure.refreshFailure)
        case .start(let attempt):
            await startSubscriptionOpen(
                subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                fileSurfaceAttempt: attempt
            )
        case .restart(let retiring, let starting):
            if retiringAttemptFinished {
                await fileSurfaceReconciler.retirementCompleted(retiring)
            }
            await startSubscriptionOpen(
                subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                fileSurfaceAttempt: starting
            )
        case .rest:
            break
        }
    }

    private func recordSourceOpened(
        subscriptionId: String,
        activeStream: ActiveStream,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true,
            productAdmission.withValidAdmission({ true }) == true,
            self.activeStream?.lease == activeStream.lease,
            subscriptionKindById[subscriptionId] != nil
        else { return }
        openedSourceSubscriptionIds.insert(subscriptionId)
        deferredOpenSubscriptionIds.remove(subscriptionId)
    }

    func cancelRegisteredSource(
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind
    ) async {
        guard let application = try? nativeApplicationRegistry.application(for: subscriptionKind) else { return }
        await application.adapter.cancel(self, subscriptionId)
    }

    static let annotationNativeAdapter = BridgePaneProductMetadataNativeAdapter(
        open: { coordinator, subscription, activeStream, productAdmission, foregroundAdmission, _, surface in
            try await coordinator.openWorktreeAnnotationSubscription(
                .init(
                    activeStream: activeStream,
                    foregroundWorkAdmission: foregroundAdmission,
                    productAdmission: productAdmission,
                    subscription: subscription,
                    surface: surface
                )
            )
        },
        cancel: { _, _ in }
    )

    static let fileMetadataNativeAdapter = BridgePaneProductMetadataNativeAdapter(
        open: { coordinator, subscription, activeStream, productAdmission, foregroundAdmission, traceContext, _ in
            try await coordinator.openFileMetadataSubscription(
                subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundAdmission,
                traceContext: traceContext
            )
        },
        cancel: { coordinator, subscriptionId in
            await coordinator.fileMetadataSource.cancel(subscriptionId: subscriptionId)
        }
    )

    static let reviewMetadataNativeAdapter = BridgePaneProductMetadataNativeAdapter(
        open: { coordinator, subscription, activeStream, productAdmission, foregroundAdmission, traceContext, _ in
            try await coordinator.openReviewMetadataSubscription(
                subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundAdmission,
                traceContext: traceContext
            )
        },
        cancel: { coordinator, subscriptionId in
            await coordinator.reviewMetadataSource.cancel(subscriptionId: subscriptionId)
        }
    )
}
