import CryptoKit
import Foundation

extension BridgePaneProductSchemeProvider {
    func annotationProjectionQueryResponse(
        queryRequest: BridgeProductAnnotationProjectionQueryRequest,
        request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeProductControlResponse {
        await recordAnnotationLifecycle(
            operationCorrelationID: queryRequest.operationCorrelationID,
            result: .started,
            sourceGeneration: queryRequest.sourceGeneration,
            stage: .projectionQueryStarted,
            surface: queryRequest.surface
        )
        let descriptor: BridgeProductAnnotationProjectionContentDescriptor
        do {
            descriptor = try await annotationProjectionSource.descriptor(
                for: queryRequest,
                issuing: request,
                productAdmission: productAdmission
            )
        } catch BridgeAnnotationProjectionSourceError.staleSourceGeneration(
            let currentSourceGeneration
        ) {
            await recordAnnotationLifecycle(
                operationCorrelationID: queryRequest.operationCorrelationID,
                result: .stale,
                sourceGeneration: queryRequest.sourceGeneration,
                stage: .projectionQueryTerminal,
                surface: queryRequest.surface
            )
            let staleResult = BridgeProductAnnotationProjectionQueryResult.sourceStale(
                currentSourceGeneration: currentSourceGeneration
            )
            let result: BridgeProductCallResult =
                switch queryRequest.surface {
                case .file: .fileAnnotationsProjectionQuery(staleResult)
                case .review: .reviewAnnotationsProjectionQuery(staleResult)
                }
            return try .callCompleted(correlating: request, result: result)
        } catch let sourceError as BridgeAnnotationProjectionSourceError {
            await recordAnnotationLifecycle(
                operationCorrelationID: queryRequest.operationCorrelationID,
                result: sourceError == .superseded ? .cancelled : .failure,
                sourceGeneration: queryRequest.sourceGeneration,
                stage: .projectionQueryTerminal,
                surface: queryRequest.surface
            )
            return try annotationProjectionError(sourceError, for: request)
        } catch {
            await recordAnnotationLifecycle(
                operationCorrelationID: queryRequest.operationCorrelationID,
                result: .failure,
                sourceGeneration: queryRequest.sourceGeneration,
                stage: .projectionQueryTerminal,
                surface: queryRequest.surface
            )
            return try annotationProjectionUnavailableError(for: request)
        }
        await recordAnnotationLifecycle(
            operationCorrelationID: queryRequest.operationCorrelationID,
            result: .success,
            sourceGeneration: queryRequest.sourceGeneration,
            stage: .projectionQueryTerminal,
            surface: queryRequest.surface
        )
        let result: BridgeProductCallResult =
            switch queryRequest.surface {
            case .file:
                .fileAnnotationsProjectionQuery(.content(descriptor))
            case .review:
                .reviewAnnotationsProjectionQuery(.content(descriptor))
            }
        return try .callCompleted(correlating: request, result: result)
    }

    func runAnnotationProjectionContentProducer(
        request: BridgeProductAnnotationProjectionContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws {
        let operationCorrelationID = request.descriptor.page.operationCorrelationID
        let sourceGeneration = request.descriptor.page.sourceGeneration
        let surface = request.descriptor.surface
        await recordAnnotationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: .started,
            sourceGeneration: sourceGeneration,
            stage: .projectionContentTransferStarted,
            surface: surface
        )
        var page: BridgePaneProductWorktreeAnnotationProjectionPage
        do {
            page = try await annotationProjectionSource.claim(request)
        } catch {
            await recordAnnotationLifecycle(
                operationCorrelationID: operationCorrelationID,
                result: .failure,
                sourceGeneration: sourceGeneration,
                stage: .projectionContentTransferTerminal,
                surface: surface
            )
            try await enqueueUnavailableContentTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        }

        do {
            guard
                let digest = try await streamAnnotationProjectionPage(
                    &page,
                    lease: lease,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    session: session
                )
            else {
                await recordAnnotationLifecycle(
                    operationCorrelationID: operationCorrelationID,
                    result: .cancelled,
                    sourceGeneration: sourceGeneration,
                    stage: .projectionContentTransferTerminal,
                    surface: surface
                )
                return
            }
            _ = try await session.enqueueTerminalContentFrame(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                build: { sequence in
                    .content(
                        .init(
                            header: try .end(
                                contentSequence: sequence,
                                endOfSource: true,
                                observedByteLength: digest.byteCount,
                                observedSha256: digest.sha256
                            ),
                            payload: Data()
                        )
                    )
                }
            )
        } catch is CancellationError {
            await recordAnnotationLifecycle(
                operationCorrelationID: operationCorrelationID,
                result: .cancelled,
                sourceGeneration: sourceGeneration,
                stage: .projectionContentTransferTerminal,
                surface: surface
            )
            return
        } catch {
            await recordAnnotationLifecycle(
                operationCorrelationID: operationCorrelationID,
                result: .failure,
                sourceGeneration: sourceGeneration,
                stage: .projectionContentTransferTerminal,
                surface: surface
            )
            try await enqueueAnnotationProjectionFailureTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        }
        await recordAnnotationLifecycle(
            operationCorrelationID: operationCorrelationID,
            result: .success,
            sourceGeneration: sourceGeneration,
            stage: .projectionContentTransferTerminal,
            surface: surface
        )
    }

    private func streamAnnotationProjectionPage(
        _ page: inout BridgePaneProductWorktreeAnnotationProjectionPage,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws -> (byteCount: Int, sha256: String)? {
        var byteCount = 0
        var hasher = SHA256()
        while let batch = try page.cursor.nextEncodedBatch() {
            try Task.checkCancellation()
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return nil }
            let batchOffset = byteCount
            let enqueueResult = try await session.enqueueContentFrame(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                build: { sequence in
                    .content(
                        .init(
                            header: try .data(
                                contentSequence: sequence,
                                offsetBytes: batchOffset
                            ),
                            payload: batch
                        )
                    )
                },
                overflowReset: { sequence in
                    .content(
                        .init(
                            header: try .reset(
                                contentSequence: sequence,
                                reason: .producerOverflow
                            ),
                            payload: Data()
                        )
                    )
                }
            )
            guard case .enqueued = enqueueResult else { return nil }
            hasher.update(data: batch)
            byteCount += batch.count
        }
        guard byteCount == page.descriptor.maximumBytes else {
            throw BridgeAnnotationProjectionSourceError.descriptorMismatch
        }
        return (
            byteCount,
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func recordAnnotationLifecycle(
        operationCorrelationID: String,
        result: BridgeAnnotationLifecycleTraceEvent.Result,
        sourceGeneration: Int,
        stage: BridgeAnnotationLifecycleTraceEvent.Stage,
        surface: BridgeProductSurface
    ) async {
        await lifecycleTraceRecorder?.record(
            .init(
                operationCorrelationID: operationCorrelationID,
                result: result,
                sourceGeneration: sourceGeneration,
                stage: stage,
                surface: surface
            )
        )
    }

    private func enqueueAnnotationProjectionFailureTerminal(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws {
        _ = try await session.enqueueTerminalContentFrame(
            for: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            build: { sequence in
                .content(
                    .init(
                        header: try .error(
                            contentSequence: sequence,
                            code: .internal,
                            retryable: true,
                            safeMessage: "Annotation projection is unavailable"
                        ),
                        payload: Data()
                    )
                )
            }
        )
    }

    private func annotationProjectionUnavailableError(
        for request: BridgeProductControlRequest
    ) throws -> BridgeProductControlResponse {
        try .requestError(
            correlating: request,
            code: .internal,
            nextExpectedRequestSequence: request.requestSequence + 1,
            retryAfterMilliseconds: nil,
            retryable: true,
            safeMessage: "Annotation projection is unavailable"
        )
    }

    private func annotationProjectionError(
        _ error: BridgeAnnotationProjectionSourceError,
        for request: BridgeProductControlRequest
    ) throws -> BridgeProductControlResponse {
        switch error {
        case .staleSourceGeneration:
            throw error
        case .superseded:
            return try .requestError(
                correlating: request,
                code: .superseded,
                nextExpectedRequestSequence: request.requestSequence + 1,
                retryAfterMilliseconds: nil,
                retryable: true,
                safeMessage: "Annotation projection query was superseded"
            )
        case .initialSourceGenerationUnavailable,
            .projectionCaptureUnavailable,
            .revalidatedSourceGenerationUnavailable,
            .sourceRefreshUnavailable,
            .unavailable:
            return try annotationProjectionUnavailableError(for: request)
        case .descriptorMismatch, .invalidCursor:
            return try .requestError(
                correlating: request,
                code: .invalidRequest,
                nextExpectedRequestSequence: request.requestSequence + 1,
                retryAfterMilliseconds: nil,
                retryable: false,
                safeMessage: "Annotation projection request is invalid"
            )
        }
    }
}
