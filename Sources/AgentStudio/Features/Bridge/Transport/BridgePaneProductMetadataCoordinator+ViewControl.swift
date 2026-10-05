import Foundation

extension BridgePaneProductMetadataCoordinator {
    func installViewResnapshotObserver(
        session: BridgeProductSession,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        await session.setViewResnapshotNeededObserver { [weak self] signal in
            await self?.recaptureAcceptedViewResnapshot(
                signal,
                expectedLease: lease,
                productAdmission: productAdmission
            )
        }
    }

    func publishFileViewCapture(
        subscriptionId: String,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> Bool {
        guard let stream = activeStream,
            stream.productAdmission.matches(productAdmission),
            subscriptionKindById[subscriptionId] == .fileMetadata,
            let acceptedScope = await stream.session.acceptedViewScope(subscriptionId: subscriptionId),
            acceptedScope.revision > 0,
            let interestState = try? BridgeProductViewScopeContract.fileDemand(from: acceptedScope.scope),
            let snapshot = await fileMetadataSource.captureKeyedSnapshot(
                subscriptionId: subscriptionId,
                demand: .init(
                    admissionSequence: acceptedScope.admissionSequence,
                    handle: acceptedScope.handle,
                    scopeRevision: acceptedScope.revision,
                    state: interestState
                ),
                productAdmission: productAdmission
            ),
            await stream.session.acceptedViewScope(subscriptionId: subscriptionId)?.revision == acceptedScope.revision,
            activeStream?.lease == stream.lease
        else { return false }
        return try await stream.session.sealFileCapture(
            subscriptionId: subscriptionId,
            snapshot: snapshot,
            scope: acceptedScope,
            productAdmission: productAdmission
        )
    }

    func publishReviewViewSnapshot(
        subscriptionId: String,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> Bool {
        guard let stream = activeStream else { return await deferReviewViewSnapshot(.noActiveStream) }
        guard stream.productAdmission.matches(productAdmission) else {
            return await deferReviewViewSnapshot(.streamAdmissionMismatch)
        }
        guard subscriptionKindById[subscriptionId] == .reviewMetadata else {
            return await deferReviewViewSnapshot(.notReviewMetadata)
        }
        guard let acceptedScope = await stream.session.acceptedViewScope(subscriptionId: subscriptionId) else {
            return await deferReviewViewSnapshot(.noAcceptedScope)
        }
        guard acceptedScope.revision > 0 else { return await deferReviewViewSnapshot(.uninitializedScope) }
        guard let demand = try? BridgeProductViewScopeContract.reviewDemand(from: acceptedScope.scope) else {
            return await deferReviewViewSnapshot(.invalidScope)
        }
        guard let publication = await reviewPublicationReplay(productAdmission) else {
            return await deferReviewViewSnapshot(.noPublication)
        }
        guard
            let capture = try await reviewMetadataSource.applyViewDemand(
                .init(
                    subscriptionId: subscriptionId,
                    handle: acceptedScope.handle,
                    scopeRevision: acceptedScope.revision,
                    admissionSequence: acceptedScope.admissionSequence,
                    demand: demand,
                    expectedPublicationId: publication.publicationId,
                    productAdmission: productAdmission
                ))
        else { return await deferReviewViewSnapshot(.noCapture) }
        guard capture.handle == acceptedScope.handle,
            capture.scopeRevision == acceptedScope.revision,
            capture.publicationId == publication.publicationId
        else { return await deferReviewViewSnapshot(.captureMismatch) }
        guard await stream.session.acceptedViewScope(subscriptionId: subscriptionId)?.revision == acceptedScope.revision
        else { return await deferReviewViewSnapshot(.scopeSuperseded) }
        guard activeStream?.lease == stream.lease else { return await deferReviewViewSnapshot(.streamReplaced) }
        let sealed = try await stream.session.sealReviewSnapshot(
            subscriptionId: subscriptionId,
            snapshot: capture.snapshot,
            productAdmission: productAdmission
        )
        guard sealed else { return await deferReviewViewSnapshot(.sealRefused) }
        return true
    }

    private func deferReviewViewSnapshot(_ reason: BridgeReviewViewSnapshotDeferralReason) async -> Bool {
        await lifecycleTraceRecorder?.record(.viewCaptureDeferred(reason))
        return false
    }

    func acceptViewScope(
        _ request: BridgeProductViewScopeRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeProductRequestErrorCode? {
        guard let activeStream,
            activeStream.productAdmission.matches(productAdmission)
        else { return .staleWorker }
        if request.subscriptionKind == .fileAnnotations || request.subscriptionKind == .reviewAnnotations {
            guard let admittedWorktreeID = await annotationSource.admittedWorktreeID(),
                case .object(let scopeMembers) = request.scope,
                case .string(let scopedWorktreeID)? = scopeMembers["worktreeId"],
                scopedWorktreeID == admittedWorktreeID
            else { return .invalidRequest }
        }
        let priorHandle = await activeStream.session.acceptedViewScope(
            subscriptionId: request.subscriptionId
        )?.handle
        let refusal = await activeStream.session.acceptViewScope(
            request,
            productAdmission: productAdmission
        )
        guard refusal == nil else { return refusal }
        if request.subscriptionKind == .fileAnnotations || request.subscriptionKind == .reviewAnnotations {
            commentViewHandleBySubscriptionId[request.subscriptionId] = request.handle
        }
        if request.subscriptionKind == .fileMetadata {
            // E4 settles at admission. N10 recaptures behind the separate view barrier.
            Task { [weak self] in
                guard let self else { return }
                await self.applyAcceptedFileViewDemand(
                    subscriptionId: request.subscriptionId,
                    expectedHandle: request.handle,
                    expectedRevision: request.scopeRevision,
                    forceRecapture: true,
                    productAdmission: productAdmission
                )
            }
        } else if request.subscriptionKind == .reviewMetadata {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.publishReviewViewSnapshot(
                    subscriptionId: request.subscriptionId,
                    productAdmission: productAdmission
                )
            }
        } else {
            Task { [weak self] in
                if let priorHandle, priorHandle != request.handle {
                    await self?.annotationSource.retireBatchView(handle: priorHandle)
                }
                await self?.applyAcceptedCommentViewScope(request, productAdmission: productAdmission)
            }
        }
        return nil
    }

    func applyAcceptedFileViewDemand(
        subscriptionId: String,
        expectedHandle: String,
        expectedRevision: Int,
        forceRecapture: Bool,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        guard let activeStream,
            activeStream.productAdmission.matches(productAdmission),
            let current = await activeStream.session.acceptedViewScope(subscriptionId: subscriptionId),
            current.handle == expectedHandle,
            current.revision == expectedRevision,
            let subscription = await activeStream.session.subscriptionSnapshot(
                subscriptionId: subscriptionId
            ),
            let source = subscription.subscription.fileMetadataSource,
            let state = try? BridgeProductViewScopeContract.fileDemand(from: current.scope),
            let foregroundWorkAdmission = refreshWorkAdmissionSource.acquire(),
            let fileOutcomeAdmission = refreshWorkAdmissionSource.acquireFileSurfaceOutcome()
        else { return }
        let inputBasis = BridgeFileSurfaceInputBasis.admitted(source: source, scope: current.scope)
        if await fileSurfaceReconciler.currentInputBasis != inputBasis {
            let action = await fileSurfaceReconciler.inputsChanged(to: inputBasis)
            await handleFileSurfaceAction(
                action,
                subscription: subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                fileOutcomeAdmission: fileOutcomeAdmission
            )
            return
        }
        guard await fileSurfaceReconciler.currentFailure == nil else { return }
        let surfaceAttempt: BridgeFileSurfaceReconciler.Attempt?
        let ownsSurfaceAttempt: Bool
        if let activeAttempt = await fileSurfaceReconciler.activeAttempt {
            surfaceAttempt = activeAttempt
            ownsSurfaceAttempt = false
        } else if case .start(let attempt) = await fileSurfaceReconciler.beginAttempt(
            inputBasis: inputBasis
        ) {
            surfaceAttempt = attempt
            ownsSurfaceAttempt = true
        } else {
            surfaceAttempt = nil
            ownsSurfaceAttempt = false
        }

        do {
            try await fileMetadataSource.applyViewDemand(
                subscriptionId: subscriptionId,
                demand: .init(
                    admissionSequence: current.admissionSequence,
                    handle: current.handle,
                    scopeRevision: current.revision,
                    state: state
                ),
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                forceRecapture: forceRecapture
            ) { _ in
                _ = try await self.publishFileViewCapture(
                    subscriptionId: subscriptionId,
                    productAdmission: productAdmission
                )
            }
            _ = try await publishFileViewCapture(
                subscriptionId: subscriptionId,
                productAdmission: productAdmission
            )
            if ownsSurfaceAttempt, let surfaceAttempt {
                let action = await fileSurfaceReconciler.builderFinished(
                    surfaceAttempt,
                    outcome: .built
                )
                await handleFileSurfaceAction(
                    action,
                    subscription: subscription,
                    activeStream: activeStream,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    fileOutcomeAdmission: fileOutcomeAdmission
                )
            }
        } catch {
            await handleFileViewDemandFailure(
                error,
                surfaceAttempt: surfaceAttempt,
                subscription: subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                workAdmissions: (foregroundWorkAdmission, fileOutcomeAdmission)
            )
        }
    }

    private func handleFileViewDemandFailure(
        _ error: any Error,
        surfaceAttempt: BridgeFileSurfaceReconciler.Attempt?,
        subscription: BridgeProductSubscriptionSnapshot,
        activeStream: ActiveStream,
        productAdmission: BridgeProductAdmissionContext,
        workAdmissions: (foreground: BridgePaneRefreshWorkAdmission, outcome: BridgePaneRefreshWorkAdmission)
    ) async {
        let foregroundWorkAdmission = workAdmissions.foreground
        let fileOutcomeAdmission = workAdmissions.outcome
        guard let surfaceAttempt else { return }
        if Task.isCancelled || Self.isForegroundWorkInvalidation(error) {
            let isAutomaticRestartEligible =
                self.activeStream?.lease == activeStream.lease
                && productAdmission.withValidAdmission({ true }) == true
                && foregroundWorkAdmission.withValidAdmission({ true }) == true
            let interruptionAction = await fileSurfaceReconciler.builderCancelled(
                surfaceAttempt,
                phase: .delivery,
                isAutomaticRestartEligible: isAutomaticRestartEligible
            )
            await fileSurfaceReconciler.retirementCompleted(surfaceAttempt)
            await handleFileSurfaceAction(
                interruptionAction,
                subscription: subscription,
                activeStream: activeStream,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                fileOutcomeAdmission: fileOutcomeAdmission
            )
            return
        }
        let newerInputBasis: BridgeFileSurfaceInputBasis?
        if (error as? BridgeWorktreeProductConstructionError) == .invalidated {
            newerInputBasis = await fileSurfaceInputBasis(
                for: subscription,
                activeStream: activeStream
            )
        } else {
            newerInputBasis = nil
        }
        let action = await fileSurfaceReconciler.builderFailed(
            surfaceAttempt,
            error: error,
            phase: .delivery,
            newerInputBasis: newerInputBasis
        )
        await handleFileSurfaceAction(
            action,
            subscription: subscription,
            activeStream: activeStream,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            fileOutcomeAdmission: fileOutcomeAdmission
        )
    }

    private func applyAcceptedCommentViewScope(
        _ request: BridgeProductViewScopeRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        guard let activeStream,
            activeStream.productAdmission.matches(productAdmission),
            let current = await activeStream.session.acceptedViewScope(subscriptionId: request.subscriptionId),
            current.handle == request.handle,
            current.revision == request.scopeRevision,
            case .object(let members) = request.scope,
            case .string(let worktreeID)? = members["worktreeId"],
            case .array? = members["sessionIds"]
        else { return }
        try? await annotationSource.acceptBatchScope(
            handle: request.handle,
            worktreeID: worktreeID,
            scopeRevision: request.scopeRevision
        )
    }

    func acceptViewResnapshot(
        _ request: BridgeProductViewResnapshotRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeProductRequestErrorCode? {
        guard let activeStream,
            activeStream.productAdmission.matches(productAdmission)
        else { return .staleWorker }
        let refusal = await activeStream.session.acceptViewResnapshot(
            request,
            productAdmission: productAdmission
        )
        guard refusal == nil else { return refusal }
        let signal = BridgeProductViewResnapshotSignal(
            viewDomain: .init(
                viewId: request.subscriptionId,
                domain: .singleDomain,
                incarnation: request.incarnation
            ),
            handle: request.handle,
            scopeRevision: request.scopeRevision,
            subscriptionKind: request.subscriptionKind
        )
        Task { [weak self] in
            await self?.recaptureAcceptedViewResnapshot(
                signal,
                expectedLease: activeStream.lease,
                productAdmission: productAdmission
            )
        }
        return nil
    }

    private func recaptureAcceptedViewResnapshot(
        _ signal: BridgeProductViewResnapshotSignal,
        expectedLease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        guard let activeStream,
            activeStream.lease == expectedLease,
            activeStream.productAdmission.matches(productAdmission),
            let accepted = await activeStream.session.acceptedViewScope(
                subscriptionId: signal.viewDomain.viewId
            ),
            accepted.viewDomain == signal.viewDomain,
            accepted.handle == signal.handle,
            accepted.revision == signal.scopeRevision
        else { return }
        if signal.subscriptionKind == .fileAnnotations || signal.subscriptionKind == .reviewAnnotations {
            await annotationSource.requestBatchResnapshot(handle: signal.handle)
        } else if signal.subscriptionKind == .fileMetadata || signal.subscriptionKind == .reviewMetadata {
            if signal.subscriptionKind == .reviewMetadata {
                _ = try? await publishReviewViewSnapshot(
                    subscriptionId: signal.viewDomain.viewId,
                    productAdmission: productAdmission
                )
                return
            }
            await applyAcceptedFileViewDemand(
                subscriptionId: signal.viewDomain.viewId,
                expectedHandle: signal.handle,
                expectedRevision: signal.scopeRevision,
                forceRecapture: true,
                productAdmission: productAdmission
            )
        }
    }
}
