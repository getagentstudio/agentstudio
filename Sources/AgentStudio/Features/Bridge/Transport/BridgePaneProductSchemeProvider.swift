import AgentStudioCore
import AgentStudioInfrastructure
import CryptoKit
import Foundation

enum BridgePaneSurfaceSelectionStreamAbsenceDisposition: Equatable, Sendable {
    case reject
    case retainForReplay
}

// swiftlint:disable type_body_length
actor BridgePaneProductSchemeProvider: BridgeProductSchemeProvider {
    nonisolated var reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource? {
        refreshWorkAdmissionSource
    }

    let admitReviewPublicationInstallation:
        @MainActor @Sendable (
            BridgeProductReviewInstallAdmissionRequest,
            BridgeProductControlCorrelation,
            BridgeProductAdmissionContext
        ) -> BridgeReviewDisplayInstallAdmissionResult
    let applyActiveViewerModeUpdate:
        @MainActor @Sendable (
            BridgeProductCallRequest,
            BridgeProductControlCorrelation,
            BridgeProductAdmissionContext
        ) async -> Void
    let applyReviewComparisonUpdate:
        @MainActor @Sendable (
            BridgeProductReviewComparisonUpdateRequest,
            Int,
            BridgeProductAdmissionContext
        ) async -> Void
    let applyFileRefreshRetry: @MainActor @Sendable (BridgeProductAdmissionContext) async -> Void
    let applyWorktreeAnnotationCommand:
        @MainActor @Sendable (
            BridgeProductWorktreeAnnotationCommandRequest,
            BridgeProductSurface,
            BridgeProductControlCorrelation,
            BridgeProductAdmissionContext
        ) async -> BridgeProductWorktreeAnnotationCommandOutcomeDTO
    private let annotationOutputSource: BridgePaneProductWorktreeAnnotationOutputSource
    let annotationProjectionSource: BridgeAnnotationProjectionSource
    private let authorizeReviewComparisonTargets:
        @Sendable () async -> BridgeProductReviewComparisonTargetsAuthorization?
    private let contentDemandAdmission: BridgeContentDemandAdmission
    private let fileContentReaderFactory: BridgePaneProductFileContentReaderFactory
    private let fileMetadataSource: any BridgePaneProductFileMetadataProducing
    let handleReviewIntakeReady:
        @MainActor @Sendable (BridgeProductReviewIntakeReadyRequest, BridgeProductAdmissionContext) async -> Void
    let markReviewItemViewed: @MainActor @Sendable (String, BridgeProductAdmissionContext) -> Void
    let metadataCoordinator: BridgePaneProductMetadataCoordinator
    let lifecycleTraceRecorder: (any BridgeProductMetadataLifecycleTraceRecording)?
    let recordReviewPublicationApplication:
        @MainActor @Sendable (
            UUID,
            BridgeProductControlCorrelation,
            BridgeProductAdmissionContext
        ) -> BridgeReviewDisplayedApplicationResult
    nonisolated let refreshWorkAdmissionSource: BridgePaneRefreshWorkAdmissionSource
    private let reviewContentSource: any BridgePaneProductReviewContentProducing
    let reviewComparisonTargetCatalogProducer: any BridgeReviewComparisonTargetCatalogProducing
    let comparisonTargetCatalogTraceRecorder: (any BridgeReviewComparisonTargetCatalogTraceRecording)?
    package var pendingComparisonTargetReservation: BridgeProductReviewComparisonTargetsReservation?
    private var currentWorkerInstanceId: String?
    private var hasSessionOwner = false

    func activateWorkerIdentity(_ workerInstanceId: String) {
        hasSessionOwner = true
        currentWorkerInstanceId = workerInstanceId
    }

    func revokeWorkerIdentity(_ workerInstanceId: String) {
        hasSessionOwner = true
        if currentWorkerInstanceId == workerInstanceId || currentWorkerInstanceId == nil {
            currentWorkerInstanceId = nil
        }
    }

    init(
        annotationSource: BridgePaneAnnotationNotificationSource = .unavailable,
        annotationOutputSource: BridgePaneProductWorktreeAnnotationOutputSource = .unavailable,
        annotationProjectionSource: BridgeAnnotationProjectionSource = .unavailable,
        fileMetadataSource: any BridgePaneProductFileMetadataProducing,
        reviewMetadataSource: any BridgePaneProductReviewMetadataProducing,
        reviewContentSource: any BridgePaneProductReviewContentProducing,
        reviewPublicationReplay:
            @escaping @MainActor @Sendable (BridgeProductAdmissionContext) ->
            BridgeReviewCommittedPublication? = { _ in nil },
        isReviewPublicationCurrent:
            @escaping @MainActor @Sendable (UUID, BridgeProductAdmissionContext) -> Bool = { _, _ in true },
        admitReviewPublicationInstallation:
            @escaping @MainActor @Sendable (
                BridgeProductReviewInstallAdmissionRequest,
                BridgeProductControlCorrelation,
                BridgeProductAdmissionContext
            ) -> BridgeReviewDisplayInstallAdmissionResult = { _, _, _ in .rejected },
        recordReviewPublicationApplication:
            @escaping @MainActor @Sendable (
                UUID,
                BridgeProductControlCorrelation,
                BridgeProductAdmissionContext
            ) -> BridgeReviewDisplayedApplicationResult = { _, _, _ in .rejected },
        markReviewItemViewed: @escaping @MainActor @Sendable (String, BridgeProductAdmissionContext) -> Void,
        handleReviewIntakeReady:
            @escaping @MainActor @Sendable (
                BridgeProductReviewIntakeReadyRequest,
                BridgeProductAdmissionContext
            ) async -> Void = { _, _ in },
        applyActiveViewerModeUpdate:
            @escaping @MainActor @Sendable (
                BridgeProductCallRequest,
                BridgeProductControlCorrelation,
                BridgeProductAdmissionContext
            ) async -> Void = { _, _, _ in },
        applyReviewComparisonUpdate:
            @escaping @MainActor @Sendable (
                BridgeProductReviewComparisonUpdateRequest,
                Int,
                BridgeProductAdmissionContext
            ) async -> Void = { _, _, _ in },
        applyFileRefreshRetry:
            @escaping @MainActor @Sendable (BridgeProductAdmissionContext) async -> Void = { _ in },
        recordCurrentFileRefreshFailure:
            @escaping @MainActor @Sendable (BridgePaneProductFileRefreshFailure?) -> Void = { _ in },
        applyWorktreeAnnotationCommand:
            @escaping @MainActor @Sendable (
                BridgeProductWorktreeAnnotationCommandRequest,
                BridgeProductSurface,
                BridgeProductControlCorrelation,
                BridgeProductAdmissionContext
            ) async -> BridgeProductWorktreeAnnotationCommandOutcomeDTO = { _, surface, correlation, _ in
                BridgeProductWorktreeAnnotationCommandOutcomeDTO(
                    .init(
                        requestID: correlation.requestId,
                        surface: surface,
                        sessionID: nil,
                        status: .failed(.unavailable)
                    )
                )
            },
        authorizeReviewComparisonTargets:
            @escaping @Sendable () async ->
            BridgeProductReviewComparisonTargetsAuthorization? = { nil },
        reviewComparisonTargetCatalogProducer:
            any BridgeReviewComparisonTargetCatalogProducing =
            BridgeUnavailableComparisonTargetCatalogProducer(),
        comparisonTargetCatalogTraceRecorder:
            (any BridgeReviewComparisonTargetCatalogTraceRecording)? = nil,
        initialPanePresentation: BridgePaneProductPresentationSnapshot? = nil,
        refreshWorkAdmissionSource: BridgePaneRefreshWorkAdmissionSource,
        lifecycleTraceRecorder: (any BridgeProductMetadataLifecycleTraceRecording)? = nil,
        contentDemandAdmission: BridgeContentDemandAdmission = BridgeContentDemandAdmission(),
        fileContentReaderFactory: @escaping BridgePaneProductFileContentReaderFactory =
            BridgePaneProductFileContentSource.openReadSession
    ) {
        self.contentDemandAdmission = contentDemandAdmission
        self.annotationOutputSource = annotationOutputSource
        self.annotationProjectionSource = annotationProjectionSource
        self.fileContentReaderFactory = fileContentReaderFactory
        self.fileMetadataSource = fileMetadataSource
        self.handleReviewIntakeReady = handleReviewIntakeReady
        self.metadataCoordinator = BridgePaneProductMetadataCoordinator(
            annotationSource: annotationSource,
            fileMetadataSource: fileMetadataSource,
            reviewMetadataSource: reviewMetadataSource,
            reviewContentSource: reviewContentSource,
            reviewPublicationReplay: reviewPublicationReplay,
            isReviewPublicationCurrent: isReviewPublicationCurrent,
            initialPanePresentation: initialPanePresentation,
            refreshWorkAdmissionSource: refreshWorkAdmissionSource,
            recordCurrentFileRefreshFailure: recordCurrentFileRefreshFailure,
            lifecycleTraceRecorder: lifecycleTraceRecorder
        )
        self.lifecycleTraceRecorder = lifecycleTraceRecorder
        self.markReviewItemViewed = markReviewItemViewed
        self.admitReviewPublicationInstallation = admitReviewPublicationInstallation
        self.recordReviewPublicationApplication = recordReviewPublicationApplication
        self.refreshWorkAdmissionSource = refreshWorkAdmissionSource
        self.reviewContentSource = reviewContentSource
        self.applyActiveViewerModeUpdate = applyActiveViewerModeUpdate
        self.applyFileRefreshRetry = applyFileRefreshRetry
        self.applyReviewComparisonUpdate = applyReviewComparisonUpdate
        self.applyWorktreeAnnotationCommand = applyWorktreeAnnotationCommand
        self.authorizeReviewComparisonTargets = authorizeReviewComparisonTargets
        self.reviewComparisonTargetCatalogProducer = reviewComparisonTargetCatalogProducer
        self.comparisonTargetCatalogTraceRecorder = comparisonTargetCatalogTraceRecorder
    }

    func response(
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext? = nil
    ) async -> BridgeProductControlResponse {
        do {
            switch request {
            case .workerSessionOpen:
                return try .workerSessionAccepted(correlating: request)
            case .productCall(let callRequest):
                return try await productCallResponse(
                    callRequest,
                    request: request,
                    productAdmission: productAdmission
                )
            case .subscriptionOpen(let openRequest):
                guard await metadataCoordinator.hasActiveStream else {
                    return try metadataStreamRequiredError(for: request)
                }
                let subscriptionKind = openRequest.subscription.subscriptionKind
                let worktreeId: String?
                if subscriptionKind == .fileAnnotations || subscriptionKind == .reviewAnnotations {
                    guard let admittedWorktreeId = await metadataCoordinator.annotationSource.admittedWorktreeID(),
                        (try? BridgeProductContractDecoding.validateIdentifier(
                            admittedWorktreeId,
                            codingPath: []
                        )) != nil
                    else {
                        return try .requestError(
                            correlating: request,
                            code: .staleSource,
                            nextExpectedRequestSequence: request.requestSequence + 1,
                            retryAfterMilliseconds: nil,
                            retryable: true,
                            safeMessage: "Comment worktree is unavailable"
                        )
                    }
                    worktreeId = admittedWorktreeId
                } else {
                    worktreeId = nil
                }
                return try .subscriptionOpenAccepted(correlating: request, worktreeId: worktreeId)
            case .subscriptionCancel:
                guard await metadataCoordinator.hasActiveStream else {
                    return try metadataStreamRequiredError(for: request)
                }
                return try .subscriptionCancelAccepted(correlating: request)
            case .viewScope(let scope):
                guard await metadataCoordinator.hasActiveStream else {
                    return try metadataStreamRequiredError(for: request)
                }
                guard let productAdmission else {
                    return try viewControlRejectedError(for: request, code: .staleWorker)
                }
                if let rejection = await metadataCoordinator.acceptViewScope(
                    scope,
                    productAdmission: productAdmission
                ) {
                    return try viewControlRejectedError(for: request, code: rejection)
                }
                return try .viewAccepted(correlating: request)
            case .viewResnapshot(let resnapshot):
                guard await metadataCoordinator.hasActiveStream else {
                    return try metadataStreamRequiredError(for: request)
                }
                guard let productAdmission else {
                    return try viewControlRejectedError(for: request, code: .staleWorker)
                }
                if let rejection = await metadataCoordinator.acceptViewResnapshot(
                    resnapshot,
                    productAdmission: productAdmission
                ) {
                    return try viewControlRejectedError(for: request, code: rejection)
                }
                return try .viewAccepted(correlating: request)
            case .workerSessionResync(let resyncRequest):
                return try .resyncAccepted(
                    correlating: request,
                    metadataStreamSequenceBarrier: resyncRequest.lastAcceptedStreamSequence,
                    nextExpectedRequestSequence: request.requestSequence + 1,
                    reconciliation: []
                )
            }
        } catch {
            preconditionFailure("Bridge product provider could not build a correlated response")
        }
    }

    private func productCallResponse(
        _ callRequest: BridgeProductCallControlRequest,
        request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext?
    ) async throws -> BridgeProductControlResponse {
        switch callRequest.call {
        case .fileAnnotationsProjectionQuery(let queryRequest),
            .reviewAnnotationsProjectionQuery(let queryRequest):
            guard let productAdmission else {
                return try annotationOutputUnavailableError(for: request)
            }
            return try await annotationProjectionQueryResponse(
                queryRequest: queryRequest,
                request: request,
                productAdmission: productAdmission
            )
        case .fileAnnotationsCommand(let annotationRequest):
            guard let productAdmission else {
                return try annotationOutputUnavailableError(for: request)
            }
            let outcome = await applyWorktreeAnnotationCommand(
                annotationRequest,
                .file,
                request.correlation,
                productAdmission
            )
            return try .callCompleted(
                correlating: request,
                result: .fileAnnotationsCommand(.completed(outcome))
            )
        case .fileAnnotationsOutputInspect(let inspectionRequest),
            .reviewAnnotationsOutputInspect(let inspectionRequest):
            return try await annotationOutputInspectionResponse(
                call: callRequest.call,
                inspectionRequest: inspectionRequest,
                request: request
            )
        case .fileSourceCurrent:
            return try await fileSourceCurrentResponse(for: request, source: fileMetadataSource)
        case .fileRefreshRetry:
            return try .callCompleted(correlating: request, result: .fileRefreshRetry)
        case .fileActiveViewerModeUpdate:
            return try .callCompleted(correlating: request, result: .fileActiveViewerModeUpdate)
        case .reviewActiveViewerModeUpdate:
            return try .callCompleted(correlating: request, result: .reviewActiveViewerModeUpdate)
        case .reviewComparisonUpdate:
            return try .callCompleted(correlating: request, result: .reviewComparisonUpdate)
        case .reviewComparisonTargetsQuery:
            return try await reviewComparisonTargetsQueryResponse(
                for: request,
                productAdmission: productAdmission
            )
        case .reviewMarkFileViewed:
            return try .callCompleted(correlating: request, result: .reviewMarkFileViewed)
        case .reviewIntakeReady:
            return try .callCompleted(correlating: request, result: .reviewIntakeReady)
        case .reviewPublicationApplied:
            return try .callCompleted(correlating: request, result: .reviewPublicationApplied)
        case .reviewPublicationInstallAdmission(let admissionRequest):
            let admissionStatus: BridgeProductReviewInstallAdmissionStatus =
                if let productAdmission {
                    switch await admitReviewPublicationInstallation(
                        admissionRequest,
                        request.correlation,
                        productAdmission
                    ) {
                    case .admitted: .admitted
                    case .rejected: .rejected
                    }
                } else {
                    .rejected
                }
            return try .callCompleted(
                correlating: request,
                result: .reviewPublicationInstallAdmission(
                    BridgeProductReviewInstallAdmissionResult(status: admissionStatus)
                )
            )
        case .reviewAnnotationsCommand(let annotationRequest):
            guard let productAdmission else {
                return try annotationOutputUnavailableError(for: request)
            }
            let outcome = await applyWorktreeAnnotationCommand(
                annotationRequest,
                .review,
                request.correlation,
                productAdmission
            )
            return try .callCompleted(
                correlating: request,
                result: .reviewAnnotationsCommand(.completed(outcome))
            )
        }
    }

    private func reviewComparisonTargetsQueryResponse(
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext?
    ) async throws -> BridgeProductControlResponse {
        let authorizationStartedAt = ContinuousClock.now
        guard let authorization = await authorizeReviewComparisonTargets() else {
            recordComparisonTargetCatalogTrace(
                stage: .authorization,
                outcome: .unavailable,
                queryRequestSequence: request.requestSequence,
                duration: authorizationStartedAt.duration(to: ContinuousClock.now)
            )
            return try comparisonTargetsUnavailableError(for: request)
        }
        guard
            let reservation = BridgeProductReviewComparisonTargetsReservation(
                authorization: authorization,
                issuing: request
            )
        else {
            recordComparisonTargetCatalogTrace(
                stage: .authorization,
                outcome: .unavailable,
                queryRequestSequence: request.requestSequence,
                duration: authorizationStartedAt.duration(to: ContinuousClock.now)
            )
            return try comparisonTargetsUnavailableError(for: request)
        }
        guard !hasSessionOwner || currentWorkerInstanceId == reservation.workerInstanceId else {
            return try comparisonTargetsUnavailableError(for: request)
        }
        if let productAdmission {
            guard
                productAdmission.withValidAdmission({
                    pendingComparisonTargetReservation = reservation
                    return true
                }) == true
            else {
                return try comparisonTargetsUnavailableError(for: request)
            }
        } else {
            pendingComparisonTargetReservation = reservation
        }
        recordComparisonTargetCatalogTrace(
            stage: .authorization,
            outcome: .success,
            queryRequestSequence: reservation.queryRequestSequence,
            duration: authorizationStartedAt.duration(to: ContinuousClock.now)
        )
        return try .callCompleted(
            correlating: request,
            result: .reviewComparisonTargetsQuery(
                BridgeProductReviewComparisonTargetsQueryResult(
                    descriptor: reservation.descriptor
                )
            )
        )
    }

    private func comparisonTargetsUnavailableError(
        for request: BridgeProductControlRequest
    ) throws -> BridgeProductControlResponse {
        try .requestError(
            correlating: request,
            code: .internal,
            nextExpectedRequestSequence: request.requestSequence + 1,
            retryAfterMilliseconds: nil,
            retryable: true,
            safeMessage: "Comparison targets are unavailable"
        )
    }

    private func annotationOutputInspectionResponse(
        call: BridgeProductCallRequest,
        inspectionRequest: BridgeProductAnnotationOutputInspectRequest,
        request: BridgeProductControlRequest
    ) async throws -> BridgeProductControlResponse {
        let surface: BridgeProductSurface
        switch call {
        case .fileAnnotationsOutputInspect:
            surface = .file
        case .reviewAnnotationsOutputInspect:
            surface = .review
        default:
            preconditionFailure("Annotation output inspection requires an inspection call")
        }
        guard
            let descriptor = try? await annotationOutputSource.descriptor(
                attemptID: .init(rawValue: inspectionRequest.attemptID),
                surface: surface
            )
        else {
            return try annotationOutputUnavailableError(for: request)
        }
        let result: BridgeProductCallResult =
            switch surface {
            case .file:
                .fileAnnotationsOutputInspect(.init(descriptor: descriptor))
            case .review:
                .reviewAnnotationsOutputInspect(.init(descriptor: descriptor))
            }
        return try .callCompleted(correlating: request, result: result)
    }

    func reserveReviewPublication(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        try await metadataCoordinator.reserveReviewPublication(
            package: package,
            publicationId: publicationId,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
    }

    func deliverReviewPublication(
        _ publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        traceContext: BridgeTraceContext? = nil
    ) async -> BridgeReviewPublicationDeliveryDisposition {
        await metadataCoordinator.deliverReviewPublication(
            publication,
            reservation: reservation,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            traceContext: traceContext
        )
    }

    func suspendForegroundWork() async {
        await metadataCoordinator.suspendForegroundWork()
    }

    func resumeForegroundWork() async {
        await metadataCoordinator.resumeForegroundWork()
    }

    func publishPanePresentation(
        _ snapshot: BridgePaneProductPresentationSnapshot,
        traceContext: BridgeTraceContext? = nil
    ) async {
        await metadataCoordinator.publishPanePresentation(snapshot, traceContext: traceContext)
    }

    func publishPaneSurfaceSelectionRequest(
        _ request: BridgePaneSurfaceSelectionRequest,
        productAdmission: BridgeProductAdmissionContext,
        streamAbsenceDisposition: BridgePaneSurfaceSelectionStreamAbsenceDisposition
    ) async -> Bool {
        await metadataCoordinator.publishPaneSurfaceSelectionRequest(
            request,
            productAdmission: productAdmission,
            streamAbsenceDisposition: streamAbsenceDisposition
        )
    }

    func settlePaneSurfaceSelectionRequest(
        requestId: String,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        await metadataCoordinator.settlePaneSurfaceSelectionRequest(
            requestId: requestId,
            productAdmission: productAdmission
        )
    }

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        do {
            await metadataCoordinator.install(
                request: request,
                lease: lease,
                productAdmission: productAdmission,
                session: session
            )
            let opening = try await session.enqueueRequiredMetadataOpeningFrame(
                for: lease,
                productAdmission: productAdmission
            )
            guard case .enqueued = opening else {
                await metadataCoordinator.uninstall(lease: lease)
                return
            }
            await metadataCoordinator.replaySubscriptionsForInstalledStream()
            await metadataCoordinator.replayPanePresentation()
            await metadataCoordinator.replayPaneSurfaceSelectionRequest()
            await waitForProducerCancellation()
            await metadataCoordinator.uninstall(lease: lease)
        } catch {
            await metadataCoordinator.uninstall(lease: lease)
            return
        }
    }

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession,
        contentWorkAdmission: BridgePaneRefreshWorkAdmission?,
        comparisonTargetReservation: BridgeProductReviewComparisonTargetsReservation? = nil
    ) async {
        guard let foregroundWorkAdmission = contentWorkAdmission else {
            recordClaimedComparisonTargetCancellation(comparisonTargetReservation)
            _ = await beginActivityInvalidatedProducerRetirement(
                lease: lease,
                session: session
            )
            return
        }
        guard
            let invalidationHandlerId = foregroundWorkAdmission.registerInvalidationHandler({
                Task { [weak self] in
                    guard let self else { return }
                    let retirement = await self.beginActivityInvalidatedProducerRetirement(
                        lease: lease,
                        session: session
                    )
                    _ = await retirement.wait()
                }
            })
        else {
            recordClaimedComparisonTargetCancellation(comparisonTargetReservation)
            _ = await beginActivityInvalidatedProducerRetirement(
                lease: lease,
                session: session
            )
            return
        }
        defer {
            foregroundWorkAdmission.removeInvalidationHandler(invalidationHandlerId)
        }
        let interest = await metadataCoordinator.contentDemandInterest(
            for: request,
            productAdmission: productAdmission
        )
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
            recordClaimedComparisonTargetCancellation(comparisonTargetReservation)
            _ = await beginActivityInvalidatedProducerRetirement(
                lease: lease,
                session: session
            )
            return
        }
        do {
            _ = try await contentDemandAdmission.withAdmission(for: interest) {
                try await self.runAdmittedContentProducer(
                    request: request,
                    lease: lease,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    comparisonTargetReservation: comparisonTargetReservation,
                    session: session
                )
            }
        } catch {
            recordClaimedComparisonTargetFailure(error, reservation: comparisonTargetReservation)
        }
        // Join only retirement start: it abandons delivery before this producer may
        // finish, while the retirement task remains free to wait for that finish.
        if foregroundWorkAdmission.withValidAdmission({ true }) == nil {
            _ = await beginActivityInvalidatedProducerRetirement(
                lease: lease,
                session: session
            )
        }
    }

    private func runAdmittedContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        comparisonTargetReservation: BridgeProductReviewComparisonTargetsReservation?,
        session: BridgeProductSession
    ) async throws {
        guard
            isContentAdmissionValid(
                foregroundWorkAdmission,
                reservation: comparisonTargetReservation
            )
        else { return }
        let openingResult = try await session.enqueueRequiredContentOpeningFrame(
            for: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            build: { _ in
                .content(
                    .init(
                        header: .accepted(for: request.admission),
                        payload: Data()
                    )
                )
            }
        )
        guard
            isContentAdmissionValid(
                foregroundWorkAdmission,
                reservation: comparisonTargetReservation
            )
        else { return }
        guard
            case .enqueued = openingResult,
            await session.waitForContentAcknowledgement(
                for: lease,
                sequence: 0,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else {
            recordClaimedComparisonTargetCancellation(comparisonTargetReservation)
            return
        }
        guard
            isContentAdmissionValid(
                foregroundWorkAdmission,
                reservation: comparisonTargetReservation
            )
        else { return }
        switch request {
        case .annotationProjection(let projectionRequest):
            try await runAnnotationProjectionContentProducer(
                request: projectionRequest,
                lease: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
        case .annotationOutput(let outputRequest):
            try await runAnnotationOutputContentProducer(
                request: outputRequest,
                lease: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
        case .fileContent(let fileRequest):
            await runFileContentProducer(
                request: fileRequest,
                lease: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
        case .reviewContent(let reviewRequest):
            try await runReviewContentProducer(
                request: reviewRequest,
                lease: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
        case .reviewComparisonTargets:
            try await runComparisonTargetContentProducer(
                reservation: comparisonTargetReservation,
                lease: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
        }
    }

    private func runReviewContentProducer(
        request: BridgeProductReviewContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
        guard
            let body = try? await reviewContentSource.contentBody(
                for: request,
                productAdmission: productAdmission
            )
        else {
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
            try await enqueueUnavailableContentTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        }
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
        _ = try await runBufferedContentProducer(
            BufferedContentBody(
                data: body.data,
                endOfSource: body.isFinalRange,
                sha256: body.sha256
            ),
            lease: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            session: session
        )
    }

    private func runAnnotationOutputContentProducer(
        request: BridgeProductAnnotationOutputContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws {
        guard let body = try? await annotationOutputSource.body(for: request.descriptor) else {
            try? await enqueueUnavailableContentTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        }
        _ = try await runBufferedContentProducer(
            BufferedContentBody(data: body.data, endOfSource: true, sha256: body.sha256),
            lease: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            session: session
        )
    }

    private func runFileContentProducer(
        request: BridgeProductFileContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
        guard
            let readPlan = await metadataCoordinator.contentReadPlan(
                for: request,
                productAdmission: productAdmission
            ),
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            readPlan.descriptor == request.descriptor
        else {
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
            try? await enqueueSupersededContentTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        }
        let reader: any BridgePaneProductFileContentReading
        do {
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
            reader = try await fileContentReaderFactory(readPlan)
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
                await reader.close()
                return
            }
        } catch {
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
            try? await enqueueSupersededContentTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        }

        do {
            let digest = try await streamFileContentChunks(
                reader: reader,
                descriptor: request.descriptor,
                lease: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            await reader.close()
            guard let digest,
                foregroundWorkAdmission.withValidAdmission({ true }) == true
            else { return }
            guard digest.byteCount == request.descriptor.declaredByteLength,
                digest.sha256 == request.descriptor.expectedSha256
            else {
                guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
                try await enqueueSupersededContentTerminal(
                    for: lease,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    session: session
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
            await reader.close()
        } catch {
            await reader.close()
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
            try? await enqueueSupersededContentTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
        }
    }

    private func streamFileContentChunks(
        reader: any BridgePaneProductFileContentReading,
        descriptor: BridgeProductFileContentDescriptor,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws -> FileContentStreamDigest? {
        var byteCount = 0
        var hasher = SHA256()
        while foregroundWorkAdmission.withValidAdmission({ true }) == true {
            guard
                await session.waitForContentCredit(
                    for: lease,
                    byteCount: BridgeProductContentCreditReadState.maximumReservedFrameByteCount,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission
                )
            else { return nil }
            guard
                let chunk = try await reader.nextChunk(
                    maximumByteCount: AppPolicies.Bridge.contentProducerChunkBytes
                )
            else { break }
            try Task.checkCancellation()
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
                await reader.close()
                return nil
            }
            let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(chunk.count)
            guard !overflowed,
                nextByteCount <= descriptor.declaredByteLength
            else {
                try await enqueueSupersededContentTerminal(
                    for: lease,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    session: session
                )
                return nil
            }
            let chunkOffsetBytes = byteCount
            hasher.update(data: chunk)
            let result = try await session.enqueueContentFrame(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                build: { sequence in
                    .content(
                        .init(
                            header: try .data(
                                contentSequence: sequence,
                                offsetBytes: chunkOffsetBytes
                            ),
                            payload: chunk
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
            guard case .enqueued = result,
                foregroundWorkAdmission.withValidAdmission({ true }) == true
            else { return nil }
            byteCount = nextByteCount
        }
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return nil }
        let sha256 = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return FileContentStreamDigest(byteCount: byteCount, sha256: sha256)
    }

    func closeAndDrain() async {
        pendingComparisonTargetReservation = nil
        await annotationProjectionSource.close()
        await metadataCoordinator.closeAndDrain()
        await contentDemandAdmission.closeAndDrain()
    }

}
