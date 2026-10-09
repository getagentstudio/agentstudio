import Foundation

private struct BridgeReviewPublicationAttemptContext {
    let publication: BridgeReviewCommittedPublication
    let reservation: BridgeReviewMetadataPublicationReservation
    let publishingStream: BridgePaneProductMetadataCoordinator.ActiveStream
    let productAdmission: BridgeProductAdmissionContext
    let producerAdmission: BridgeProductAdmissionContext
    let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    let traceContext: BridgeTraceContext?
    let attempt: Int
}

extension BridgePaneProductMetadataCoordinator {
    func reserveReviewPublication(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
            throw CancellationError()
        }
        return try await reviewMetadataSource.reserve(
            package: package,
            publicationId: publicationId,
            productAdmission: productAdmission
        )
    }

    func replayCommittedReviewPublicationIfPresent(
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        traceContext: BridgeTraceContext?
    ) async {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true,
            let publication = await reviewPublicationReplay(productAdmission),
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            let reservation = try? await reviewMetadataSource.reserve(
                package: publication.package,
                publicationId: publication.publicationId,
                productAdmission: productAdmission
            )
        else { return }
        _ = await deliverReviewPublication(
            publication.retainedReplay,
            reservation: reservation,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            traceContext: traceContext
        )
    }

    func deliverReviewPublication(
        _ publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        traceContext: BridgeTraceContext? = nil
    ) async -> BridgeReviewPublicationDeliveryDisposition {
        guard
            let publishingStream = admittedPanePublicationStream(
                for: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission),
            reservation.publicationId == publication.publicationId
        else { return .deferred }
        let streamProductAdmission = publishingStream.productAdmission
        let retainedSubscriptionCount = reviewSubscriptionIds.count
        await lifecycleTraceRecorder?.record(
            .started(
                retainedSubscriptions: retainedSubscriptionCount,
                traceContext: traceContext
            )
        )
        guard
            isCurrentPanePublicationStream(
                publishingStream, producerAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission)
        else { return .deferred }
        for attempt in 0...1 {
            guard
                isCurrentPanePublicationStream(
                    publishingStream, producerAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission),
                await isReviewPublicationCurrent(
                    publication.publicationId,
                    streamProductAdmission
                ),
                isCurrentPanePublicationStream(
                    publishingStream, producerAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission)
            else { return .deferred }
            do {
                return try await deliverReviewPublicationAttempt(
                    .init(
                        publication: publication,
                        reservation: reservation,
                        publishingStream: publishingStream,
                        productAdmission: streamProductAdmission,
                        producerAdmission: productAdmission,
                        foregroundWorkAdmission: foregroundWorkAdmission,
                        traceContext: traceContext,
                        attempt: attempt
                    )
                )
            } catch {
                if let operationCorrelationID = publication.operationCorrelationID {
                    await recordOperationLifecycle(
                        operationCorrelationID: operationCorrelationID,
                        result: error is CancellationError ? .cancelled : .failure,
                        stage: .metadataEnqueueTerminal,
                        stageAttempt: attempt,
                        surface: .review
                    )
                }
                guard
                    isCurrentPanePublicationStream(
                        publishingStream, producerAdmission: productAdmission,
                        foregroundWorkAdmission: foregroundWorkAdmission),
                    await isReviewPublicationCurrent(
                        publication.publicationId,
                        streamProductAdmission
                    ),
                    isCurrentPanePublicationStream(
                        publishingStream, producerAdmission: productAdmission,
                        foregroundWorkAdmission: foregroundWorkAdmission)
                else { return .deferred }
                await recordReviewPublicationFailure(
                    Self.reviewPublicationFailure(for: error),
                    retainedSubscriptions: retainedSubscriptionCount,
                    traceContext: traceContext
                )
                guard attempt == 0,
                    Self.isRetryableReviewDeliveryFailure(error),
                    isCurrentPanePublicationStream(
                        publishingStream, producerAdmission: productAdmission,
                        foregroundWorkAdmission: foregroundWorkAdmission),
                    await isReviewPublicationCurrent(
                        publication.publicationId,
                        streamProductAdmission
                    ),
                    isCurrentPanePublicationStream(
                        publishingStream, producerAdmission: productAdmission,
                        foregroundWorkAdmission: foregroundWorkAdmission)
                else { return .failed }
            }
        }
        return .failed
    }

    private func deliverReviewPublicationAttempt(
        _ context: BridgeReviewPublicationAttemptContext
    ) async throws -> BridgeReviewPublicationDeliveryDisposition {
        await recordReviewMetadataEnqueue(
            publication: context.publication,
            result: .started,
            stage: .metadataEnqueueStarted,
            stageAttempt: context.attempt
        )
        guard isCurrentReviewPublicationStream(context) else { return .deferred }
        let outcome = try await reviewMetadataSource.deliver(
            publication: context.publication,
            reservation: context.reservation,
            productAdmission: context.productAdmission
        )
        guard isCurrentReviewPublicationStream(context) else { return .deferred }
        await recordReviewMetadataEnqueue(
            publication: context.publication,
            result: .success,
            stage: .metadataEnqueueTerminal,
            stageAttempt: context.attempt
        )
        guard isCurrentReviewPublicationStream(context),
            case .delivered(let receipt) = outcome,
            await isReviewPublicationCurrent(
                context.publication.publicationId,
                context.productAdmission
            ),
            isCurrentReviewPublicationStream(context)
        else { return .deferred }
        var sealedViewCount = 0
        for subscriptionID in reviewSubscriptionIds {
            guard isCurrentReviewPublicationStream(context) else { return .deferred }
            if try await publishReviewViewSnapshot(
                subscriptionId: subscriptionID,
                productAdmission: context.productAdmission
            ) {
                sealedViewCount += 1
            }
            guard isCurrentReviewPublicationStream(context) else { return .deferred }
        }
        await recordReviewMetadataEnqueue(
            publication: context.publication,
            result: .started,
            stage: .metadataDeliveryStarted,
            stageAttempt: context.attempt
        )
        guard isCurrentReviewPublicationStream(context),
            await isReviewPublicationCurrent(context.publication.publicationId, context.productAdmission),
            isCurrentReviewPublicationStream(context)
        else { return .deferred }
        await recordReviewMetadataDeliveryTerminal(
            publication: context.publication,
            result: .success,
            stageAttempt: context.attempt
        )
        guard isCurrentReviewPublicationStream(context) else { return .deferred }
        await lifecycleTraceRecorder?.record(
            .completed(receipt: receipt, traceContext: context.traceContext)
        )
        guard isCurrentReviewPublicationStream(context) else { return .deferred }
        return sealedViewCount > 0 ? .viewBatchSealed : .deferred
    }

    private func isCurrentReviewPublicationStream(_ context: BridgeReviewPublicationAttemptContext) -> Bool {
        isCurrentPanePublicationStream(
            context.publishingStream, producerAdmission: context.producerAdmission,
            foregroundWorkAdmission: context.foregroundWorkAdmission)
    }

    private func recordReviewMetadataEnqueue(
        publication: BridgeReviewCommittedPublication,
        result: BridgeOperationLifecycleTraceEvent.Result,
        stage: BridgeOperationLifecycleTraceEvent.Stage,
        stageAttempt: Int
    ) async {
        guard let operationCorrelationID = publication.operationCorrelationID else { return }
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: result,
            stage: stage,
            stageAttempt: stageAttempt,
            surface: .review
        )
    }

    private func recordReviewMetadataDeliveryTerminal(
        publication: BridgeReviewCommittedPublication,
        result: BridgeOperationLifecycleTraceEvent.Result,
        stageAttempt: Int
    ) async {
        guard let operationCorrelationID = publication.operationCorrelationID else { return }
        await recordOperationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: result,
            stage: .metadataDeliveryTerminal,
            stageAttempt: stageAttempt,
            surface: .review
        )
    }

    func resetCurrentReviewSubscriptionsForUnavailableSource(
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async {
        guard
            let resettingStream = admittedPanePublicationStream(
                for: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
        else { return }

        for subscriptionId in reviewSubscriptionIds {
            guard
                isCurrentPanePublicationStream(
                    resettingStream, producerAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission)
            else { return }
            let resetResult = try? await resettingStream.session.enqueueSubscriptionReset(
                originatingMetadataLease: resettingStream.lease,
                subscriptionId: subscriptionId,
                reason: .staleSource,
                productAdmission: resettingStream.productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
            guard
                isCurrentPanePublicationStream(
                    resettingStream, producerAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission)
            else { return }
            guard case .enqueued = resetResult else { continue }
            await retireSubscriptionAfterReset(subscriptionId: subscriptionId)
            guard
                isCurrentPanePublicationStream(
                    resettingStream, producerAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission)
            else { return }
        }
    }

    private func recordReviewPublicationFailure(
        _ failure: BridgeProductReviewMetadataPublicationFailure,
        retainedSubscriptions: Int,
        traceContext: BridgeTraceContext?
    ) async {
        await lifecycleTraceRecorder?.record(
            .failed(
                failure: failure,
                retainedSubscriptions: retainedSubscriptions,
                traceContext: traceContext
            )
        )
    }
}
