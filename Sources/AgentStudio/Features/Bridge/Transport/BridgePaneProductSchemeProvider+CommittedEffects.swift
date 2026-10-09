import AgentStudioCore
import AgentStudioGit
import Foundation

extension BridgePaneProductSchemeProvider {
    func publishFileStatus(
        _ status: GitWorkingTreeStatus,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        operationCorrelationID: String,
        operationStageAttempt: Int
    ) async -> BridgePaneProductFileRefreshPublicationDisposition {
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: .started,
            stage: .filePrepareStarted,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: .started,
            stage: .metadataEnqueueStarted,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        let disposition = await metadataCoordinator.publish(
            status: status,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: Self.operationResult(for: disposition),
            stage: .metadataEnqueueTerminal,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: Self.operationResult(for: disposition),
            stage: .filePrepareTerminal,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        return disposition
    }

    func publishFileChangeset(
        _ changeset: FileChangeset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        operationCorrelationID: String,
        operationStageAttempt: Int
    ) async -> BridgePaneProductFileRefreshPublicationDisposition {
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: .started,
            stage: .filePrepareStarted,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: .started,
            stage: .metadataEnqueueStarted,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        let disposition = await metadataCoordinator.publish(
            changeset: changeset,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: Self.operationResult(for: disposition),
            stage: .metadataEnqueueTerminal,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: Self.operationResult(for: disposition),
            stage: .filePrepareTerminal,
            stageAttempt: operationStageAttempt,
            surface: .file
        )
        return disposition
    }

    func recordOperationLifecycle(
        operationCorrelationID: String,
        result: BridgeOperationLifecycleTraceEvent.Result,
        stage: BridgeOperationLifecycleTraceEvent.Stage,
        stageAttempt: Int,
        surface: BridgeProductSurface
    ) async {
        await metadataCoordinator.recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: result,
            stage: stage,
            stageAttempt: stageAttempt,
            surface: surface
        )
    }

    func recordOperationLifecycle(_ event: BridgeOperationLifecycleTraceEvent) async {
        await metadataCoordinator.recordOperationLifecycle(event)
    }

    private static func operationResult(
        for disposition: BridgePaneProductFileRefreshPublicationDisposition
    ) -> BridgeOperationLifecycleTraceEvent.Result {
        switch disposition {
        case .applied, .notRequired:
            .success
        case .failed:
            .failure
        case .stale, .streamResetRequired:
            .stale
        }
    }

    func resetCurrentReviewSubscriptionsForUnavailableSource(
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async {
        await metadataCoordinator.resetCurrentReviewSubscriptionsForUnavailableSource(
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        _ = acknowledgement
        return true
    }

    func applyCommittedControlEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        if case .productCall(let committedProductCall) = effect,
            case .productCall(let callRequest) = request,
            committedProductCall == callRequest.call
        {
            guard (productAdmission.withValidAdmission { true }) == true else { return }
            switch committedProductCall {
            case .fileAnnotationsCommand, .reviewAnnotationsCommand:
                break
            case .fileAnnotationsOutputInspect, .reviewAnnotationsOutputInspect,
                .fileAnnotationsProjectionQuery, .reviewAnnotationsProjectionQuery:
                break
            case .fileSourceCurrent:
                break
            case .fileRefreshRetry:
                await applyFileRefreshRetry(productAdmission)
                await metadataCoordinator.retryFailedFileSurface(productAdmission: productAdmission)
            case .fileActiveViewerModeUpdate, .reviewActiveViewerModeUpdate:
                await applyActiveViewerModeUpdate(
                    committedProductCall,
                    request.correlation,
                    productAdmission
                )
            case .reviewComparisonUpdate(let updateRequest):
                await applyReviewComparisonUpdate(
                    updateRequest,
                    callRequest.workerDerivationEpoch,
                    productAdmission
                )
            case .reviewComparisonTargetsQuery:
                break
            case .reviewMarkFileViewed(let markRequest):
                await markReviewItemViewed(markRequest.itemId, productAdmission)
            case .reviewIntakeReady(let intakeRequest):
                await handleReviewIntakeReady(intakeRequest, productAdmission)
            case .reviewPublicationApplied(let appliedRequest):
                _ = await recordReviewPublicationApplication(
                    appliedRequest.publicationId,
                    request.correlation,
                    productAdmission
                )
            case .reviewPublicationInstallAdmission:
                break
            }
            return
        }
        await metadataCoordinator.apply(
            effect,
            productAdmission: productAdmission
        )
    }

    func retireFloorRetiredSubscriptions(
        _ subscriptions: [BridgeProductSubscriptionSnapshot],
        productAdmission: BridgeProductAdmissionContext
    ) async {
        // Native ended these subscriptions exactly as a committed cancel does, so
        // their producers stop through the same metadata-coordinator path.
        for subscription in subscriptions {
            await metadataCoordinator.apply(
                .subscriptionCancelled(subscription),
                productAdmission: productAdmission
            )
        }
    }

    func replayCommittedReviewPublicationIfPresent(
        productAdmission: BridgeProductAdmissionContext,
        traceContext: BridgeTraceContext? = nil
    ) async {
        guard let foregroundWorkAdmission = refreshWorkAdmissionSource.acquire() else { return }
        await metadataCoordinator.replayCommittedReviewPublicationIfPresent(
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            traceContext: traceContext
        )
    }

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        let comparisonTargetReservation = claimComparisonTargetReservation(for: request)
        let contentWorkAdmission: BridgePaneRefreshWorkAdmission?
        switch request {
        case .annotationOutput, .annotationProjection:
            contentWorkAdmission = refreshWorkAdmissionSource.acquire()
        case .fileContent:
            contentWorkAdmission = refreshWorkAdmissionSource.acquire()
        case .reviewContent:
            contentWorkAdmission = refreshWorkAdmissionSource.acquireReviewContentContinuation()
        case .reviewComparisonTargets:
            contentWorkAdmission = refreshWorkAdmissionSource.acquire()
        }
        await runContentProducer(
            request: request,
            lease: lease,
            productAdmission: productAdmission,
            session: session,
            contentWorkAdmission: contentWorkAdmission,
            comparisonTargetReservation: comparisonTargetReservation
        )
    }

    nonisolated func makeContentProducerOperation(
        request: BridgeProductContentRequest,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) -> BridgeProductProducerRegistry.ProducerOperation {
        switch request {
        case .annotationOutput, .annotationProjection:
            return { lease in
                await self.runContentProducer(
                    request: request,
                    lease: lease,
                    productAdmission: productAdmission,
                    session: session
                )
            }
        case .fileContent:
            return { lease in
                await self.runContentProducer(
                    request: request,
                    lease: lease,
                    productAdmission: productAdmission,
                    session: session
                )
            }
        case .reviewContent:
            let contentWorkAdmission =
                refreshWorkAdmissionSource.acquireReviewContentContinuation()
            return { lease in
                await self.runContentProducer(
                    request: request,
                    lease: lease,
                    productAdmission: productAdmission,
                    session: session,
                    contentWorkAdmission: contentWorkAdmission
                )
            }
        case .reviewComparisonTargets:
            return { lease in
                await self.runContentProducer(
                    request: request,
                    lease: lease,
                    productAdmission: productAdmission,
                    session: session
                )
            }
        }
    }
}
