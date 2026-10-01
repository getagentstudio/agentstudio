import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session protocol lifecycle admission")
struct BridgePaneProductMetadataCoordinatorTests {
    @Test("unavailable File source publishes retryable failure without resetting the subscription")
    func unavailableFileSourcePublishesRetryableFailureWithoutReset() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let currentFileFailure = HeldStep<BridgePaneProductFileRefreshFailure>(
            "current retryable File refresh failure"
        )
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            recordCurrentFileRefreshFailure: { failure in
                guard let failure else { return }
                Task { try? await currentFileFailure.arrive(failure) }
            }
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )

        // Act
        let token = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        let acceptedFrame = try await pullMetadataFrame(from: pump)
        await coordinator.apply(
            effect,
            productAdmission: harness.productAdmission.context
        )
        let currentFailure = try await currentFileFailure.firstArrival()
        let producerSnapshot = await harness.session.producerSnapshot()
        let retainedSubscription = await harness.session.subscriptionSnapshot(
            subscriptionId: "file-subscription-1"
        )

        // Assert
        guard case .subscriptionAccepted(let accepted) = acceptedFrame else {
            Issue.record("Expected accepted File subscription")
            return
        }
        #expect(accepted.frameIdentity.streamSequence == 1)
        #expect(currentFailure == .init(failureKind: .fileSourceUnavailable))
        #expect(currentFailure.retryable)
        #expect(producerSnapshot.queuedFrameCount == 0)
        #expect(retainedSubscription != nil)
        await harness.session.settleControlProviderDispatch(token: token)
        #expect(await pump.cancel())
    }

    @Test("committed File open publishes a sealed snapshot after view-scope acceptance")
    func committedFileOpenPublishesDataAfterAcceptedLifecycle() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let source = CoordinatorFileMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let metadataRequest = try coordinatorMetadataStreamRequest()
        await coordinator.install(
            request: metadataRequest,
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )

        // Act
        let token = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        let acceptedFrame = try await pullMetadataFrame(from: pump)
        await coordinator.apply(
            effect,
            productAdmission: harness.productAdmission.context
        )
        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"file-scope-after-open","requestSequence":3,\
                "subscriptionId":"file-subscription-1","subscriptionKind":"file.metadata",\
                "domain":"default","handle":"file-handle-1","incarnation":"file-incarnation-1",\
                "scopeRevision":1,"scope":{"kind":"file","changeFilter":{"kind":"none"},"interests":[],"pathScope":[]}}
                """.utf8
            )
        )
        #expect(
            await coordinator.acceptViewScope(
                scopeRequest,
                productAdmission: harness.productAdmission.context
            ) == nil
        )
        let beginFrame = try await pullMetadataFrame(from: pump)
        let partFrame = try await pullMetadataFrame(from: pump)
        let completeFrame = try await pullMetadataFrame(from: pump)
        await harness.session.settleControlProviderDispatch(token: token)

        // Assert
        guard case .subscriptionAccepted(let accepted) = acceptedFrame,
            case .batch(.begin(let begin)) = beginFrame,
            case .batch(.part(let part)) = partFrame,
            case .batch(.complete(let complete)) = completeFrame
        else {
            Issue.record("Expected File accepted followed by one sealed snapshot")
            return
        }
        #expect(accepted.frameIdentity.streamSequence == 1)
        #expect(accepted.subscriptionIdentity.subscriptionSequence == 0)
        #expect(begin.identity.frame.streamSequence == 2)
        #expect(begin.identity.subscriptionId == "file-subscription-1")
        #expect(begin.partCount == 1)
        #expect(part.identity.frame.streamSequence == 3)
        #expect(complete.identity.frame.streamSequence == 4)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("committed Review publication seals one batch before its view is installed")
    @MainActor
    func committedReviewPublicationWaitsForExactFinalFrameObservation() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let reviewPackage = try coordinatorReviewPackageFixture()
        let expectedItemIds = BridgePaneProductReviewMetadataSource.orderedItemIds(in: reviewPackage)
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let reviewSource = CoordinatorTrackingReviewMetadataSource()
        let replayProvider = AvailabilityReviewPublicationProvider()
        let traceRecorder = AvailabilityReviewPublicationTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: reviewSource,
            reviewPublicationReplay: { _ in replayProvider.publication },
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )

        // Act
        let token = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        let acceptedFrame = try await pullMetadataFrame(from: pump)
        await coordinator.apply(
            effect,
            productAdmission: harness.productAdmission.context
        )
        #expect((try await traceRecorder.waitUntilReviewBootstrapFinished()).result == .success)
        let scopeRequest = try reviewTestViewScopeRequest(itemIds: expectedItemIds)
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest,
                productAdmission: harness.productAdmission.context
            ) == nil
        )
        let publication = coordinatorCommittedReviewPublication(reviewPackage)
        replayProvider.publication = publication
        let reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage,
            publicationId: publication.publicationId,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
        let deliveryDisposition = await coordinator.deliverReviewPublication(
            publication,
            reservation: reservation,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
        let publicationReceipt = await reviewSource.waitUntilPublicationReceipt()
        var batchFrames: [BridgeProductMetadataFrame] = []
        for _ in 0..<(expectedItemIds.count + 3) {
            batchFrames.append(try await pullMetadataFrame(from: pump))
        }
        await harness.session.settleControlProviderDispatch(token: token)

        // Assert
        let lastBatchFrame = try #require(batchFrames.last)
        guard case .subscriptionAccepted(let accepted) = acceptedFrame,
            case .batch(.begin(let begin)) = batchFrames[0],
            case .batch(.complete(let complete)) = lastBatchFrame
        else {
            Issue.record("Expected Review accepted followed by one sealed batch; observed \(batchFrames.map(\.kind))")
            return
        }
        #expect(accepted.frameIdentity.streamSequence == 1)
        #expect(begin.identity.frame.streamSequence == 2)
        #expect(begin.publicationId == publication.publicationId)
        #expect(begin.partCount == expectedItemIds.count + 1)
        #expect(begin.identity.handle == scopeRequest.handle)
        #expect(complete.identity.batchId == begin.identity.batchId)
        #expect(complete.identity.frame.streamSequence == expectedItemIds.count + 4)
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        #expect(deliveryDisposition == .viewBatchSealed)
        #expect(publicationReceipt.publishedSubscriptions == 1)
        #expect(publicationReceipt.finalFrames.isEmpty)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("Review cancel retires its producer without disturbing the metadata stream")
    func reviewCancelRetiresProducerWithoutDisturbingStream() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let fileSource = CoordinatorFileMetadataSource()
        let reviewSource = CoordinatorReviewMetadataSource(event: try coordinatorReviewSourceAcceptedEvent())
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: fileSource,
            reviewMetadataSource: reviewSource,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        let openToken = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: openToken))
        let openResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let openEffect = try await harness.session.completeAdmittedControl(
            token: openToken,
            exactResponseBytes: try JSONEncoder().encode(openResponse)
        )
        _ = try await pullMetadataFrame(from: pump)
        await coordinator.apply(
            openEffect,
            productAdmission: harness.productAdmission.context
        )
        await harness.session.settleControlProviderDispatch(token: openToken)
        let cancelRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleSubscriptionCancelObject(requestSequence: 3, epoch: 1)
        )

        // Act
        let cancelToken = try #require(controlExecutionToken(try await harness.begin(cancelRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: cancelToken))
        let cancelResponse = try BridgeProductControlResponse.subscriptionCancelAccepted(
            correlating: cancelRequest
        )
        let cancelEffect = try await harness.session.completeAdmittedControl(
            token: cancelToken,
            exactResponseBytes: try JSONEncoder().encode(cancelResponse)
        )
        let cancelledFrame = try await pullMetadataFrame(from: pump)
        await coordinator.apply(
            cancelEffect,
            productAdmission: harness.productAdmission.context
        )
        await harness.session.settleControlProviderDispatch(token: cancelToken)

        // Assert
        guard case .subscriptionCancelled(let cancelled) = cancelledFrame else {
            Issue.record("Expected Review subscription-cancelled lifecycle")
            return
        }
        #expect(cancelled.identity.frameIdentity.streamSequence == 2)
        #expect(await reviewSource.cancelledSubscriptionIds == ["review-subscription-1"])
        #expect(await fileSource.cancelledSubscriptionIds.isEmpty)
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        await coordinator.uninstall(lease: lease)
        #expect(await reviewSource.cancelledSubscriptionIds == ["review-subscription-1"])
        #expect(await fileSource.cancelledSubscriptionIds.isEmpty)
        #expect(await pump.cancel())
    }

    @Test("File and Review accepted subscriptions share one contiguous E3 stream")
    func fileAndReviewSubscriptionsShareOneLifecycleStream() async throws {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session, producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: CoordinatorFileMetadataSource(),
            reviewMetadataSource: CoordinatorReviewMetadataSource(
                event: try coordinatorReviewSourceAcceptedEvent()
            ),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(), lease: lease,
            productAdmission: harness.productAdmission.context, session: harness.session
        )
        let requests = [
            try bridgeProductLifecycleControlRequest(
                bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
            ),
            try bridgeProductLifecycleControlRequest(
                bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 3, epoch: 1)
            ),
        ]
        var acceptedFrames: [BridgeProductMetadataFrame] = []
        for request in requests {
            let token = try #require(controlExecutionToken(try await harness.begin(request)))
            #expect(await harness.session.admitControlProviderExecution(token: token))
            let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
                correlating: request, worktreeId: nil
            )
            let effect = try await harness.session.completeAdmittedControl(
                token: token, exactResponseBytes: try JSONEncoder().encode(response)
            )
            acceptedFrames.append(try await pullMetadataFrame(from: pump))
            await coordinator.apply(effect, productAdmission: harness.productAdmission.context)
            await harness.session.settleControlProviderDispatch(token: token)
        }
        guard case .subscriptionAccepted(let fileAccepted) = acceptedFrames[0],
            case .subscriptionAccepted(let reviewAccepted) = acceptedFrames[1]
        else {
            Issue.record("Expected two E3 subscription acceptances")
            return
        }
        #expect(fileAccepted.frameIdentity.streamSequence == 1)
        #expect(reviewAccepted.frameIdentity.streamSequence == 2)
        #expect(fileAccepted.subscriptionIdentity.subscriptionKind == .fileMetadata)
        #expect(reviewAccepted.subscriptionIdentity.subscriptionKind == .reviewMetadata)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("current Review failure resets Review subscription and leaves File active")
    func currentReviewFailureResetsOnlyReviewSubscription() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: CoordinatorFileMetadataSource(),
            reviewMetadataSource: CoordinatorReviewMetadataSource(
                event: try coordinatorReviewSourceAcceptedEvent()
            ),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        for request in [
            try bridgeProductLifecycleControlRequest(
                bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
            ),
            try bridgeProductLifecycleControlRequest(
                bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 3, epoch: 1)
            ),
        ] {
            let token = try #require(controlExecutionToken(try await harness.begin(request)))
            #expect(await harness.session.admitControlProviderExecution(token: token))
            let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
                correlating: request, worktreeId: nil)
            let effect = try await harness.session.completeAdmittedControl(
                token: token,
                exactResponseBytes: try JSONEncoder().encode(response)
            )
            _ = try await pullMetadataFrame(from: pump)
            await coordinator.apply(effect, productAdmission: harness.productAdmission.context)
            await harness.session.settleControlProviderDispatch(token: token)
        }

        // Act
        await coordinator.resetCurrentReviewSubscriptionsForUnavailableSource(
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
        let resetFrame = try await pullMetadataFrame(from: pump)

        // Assert
        guard case .subscriptionReset(let reset) = resetFrame else {
            Issue.record("Expected a Review subscription reset")
            return
        }
        #expect(reset.identity.subscriptionIdentity.subscriptionId == "review-subscription-1")
        #expect(reset.reason == .staleSource)
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: "file-subscription-1") != nil
        )
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("foreground resume skips a missing deferred subscription and replays the next one")
    @MainActor
    func foregroundResumeContinuesAfterMissingSubscriptionSnapshot() async throws {
        // Arrange
        let activityCoordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .loadedHidden
        )
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let fileSource = CoordinatorFileMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: fileSource,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: activityCoordinator.workAdmissionSource
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        let token = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        _ = try await pullMetadataFrame(from: pump)
        guard case .subscriptionOpened(let activeSubscription) = effect else {
            Issue.record("Expected an opened File subscription effect")
            return
        }
        let missingSubscription = BridgeProductSubscriptionSnapshot(
            subscription: activeSubscription.subscription,
            subscriptionId: "aaa-missing-subscription",
            subscriptionKind: activeSubscription.subscriptionKind,
            workerDerivationEpoch: activeSubscription.workerDerivationEpoch
        )
        await coordinator.apply(
            .subscriptionOpened(missingSubscription),
            productAdmission: harness.productAdmission.context
        )
        await coordinator.apply(
            effect,
            productAdmission: harness.productAdmission.context
        )

        // Act
        activityCoordinator.applyActivity(.foreground)
        await coordinator.resumeForegroundWork()
        #expect(await fileSource.waitUntilOpened() == 1)

        // Assert
        #expect(await fileSource.openCount == 1)
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: activeSubscription.subscriptionId)
                != nil
        )
        await harness.session.settleControlProviderDispatch(token: token)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("control commits publish ordered E3 open and cancel lifecycle frames")
    func committedSubscriptionLifecycleEmitsOrderedFrames() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session, producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        let openToken = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: openToken))
        let openResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil
        )
        _ = try await harness.session.completeAdmittedControl(
            token: openToken, exactResponseBytes: try JSONEncoder().encode(openResponse)
        )
        let acceptedFrame = try await pullMetadataFrame(from: pump)
        await harness.session.settleControlProviderDispatch(token: openToken)

        let cancelRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleSubscriptionCancelObject(requestSequence: 3, epoch: 1)
        )
        let cancelToken = try #require(controlExecutionToken(try await harness.begin(cancelRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: cancelToken))
        let cancelResponse = try BridgeProductControlResponse.subscriptionCancelAccepted(
            correlating: cancelRequest
        )
        _ = try await harness.session.completeAdmittedControl(
            token: cancelToken, exactResponseBytes: try JSONEncoder().encode(cancelResponse)
        )
        let cancelledFrame = try await pullMetadataFrame(from: pump)
        await harness.session.settleControlProviderDispatch(token: cancelToken)

        guard case .subscriptionAccepted(let accepted) = acceptedFrame,
            case .subscriptionCancelled(let cancelled) = cancelledFrame
        else {
            Issue.record("Expected accepted and cancelled E3 lifecycle frames")
            return
        }
        #expect(accepted.frameIdentity.streamSequence == 1)
        #expect(accepted.subscriptionIdentity.subscriptionSequence == 0)
        #expect(cancelled.identity.frameIdentity.streamSequence == 2)
        #expect(cancelled.identity.subscriptionIdentity.subscriptionSequence == 1)
        #expect((await harness.session.snapshot).controlReplay.replayableRequestSequence == 3)
        #expect(await pump.cancel())
    }

}

@Suite("Bridge pane presentation telemetry")
struct BridgePanePresentationCoordinatorTests {
    @Test("pane presentation records when no metadata stream can receive it")
    func panePresentationRecordsMissingMetadataStream() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let traceRecorder = CoordinatorPanePresentationTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        let presentation = coordinatorPanePresentation(
            presentationRevision: 17,
            attempt: .pending(reviewGeneration: 4)
        )

        // Act
        await coordinator.publishPanePresentation(presentation)

        // Assert
        let events = await traceRecorder.presentationEvents
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.stage == .notEnqueued)
        #expect(event.result == .skipped)
        #expect(event.resultReason == .noActiveStream)
        #expect(event.presentationRevision == 17)
        #expect(event.comparisonAttempt == .pending)
        #expect(event.reviewGeneration == 4)
        #expect(event.refreshingReview == true)
        #expect(event.hasActiveStream == false)
    }

    @Test("pane presentation records successful metadata-stream enqueue")
    func panePresentationRecordsSuccessfulMetadataStreamEnqueue() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let traceRecorder = CoordinatorPanePresentationTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let presentation = coordinatorPanePresentation(
            presentationRevision: 18,
            attempt: .settled(reviewGeneration: 5)
        )

        // Act
        await coordinator.publishPanePresentation(presentation)

        // Assert
        let events = await traceRecorder.presentationEvents
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.stage == .enqueued)
        #expect(event.result == .success)
        #expect(event.resultReason == .noReason)
        #expect(event.presentationRevision == 18)
        #expect(event.comparisonAttempt == .settled)
        #expect(event.reviewGeneration == 5)
        #expect(event.refreshingReview == true)
        #expect(event.hasActiveStream == true)
        await coordinator.uninstall(lease: lease)
    }

    @Test("pane presentation overflow emits a retryable resync terminal")
    func panePresentationOverflowEmitsRetryableResyncTerminal() async throws {
        let queueLimits = try BridgeProductProducerQueueLimits(
            maximumQueuedFrameCount: 3,
            maximumQueuedByteCount: BridgeProductWireContract.maximumQueuedStreamBytes,
            maximumEncodedFrameByteCount:
                BridgeProductProducerQueueLimits.maximumProductEncodedFrameByteCount,
            terminalFrameReserve: BridgeProductWireContract.terminalFrameReserve
        )
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            producerQueueLimits: queueLimits
        )
        let lease = try await harness.admitMetadataFrames(through: 0)
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )

        await coordinator.publishPanePresentation(
            coordinatorPanePresentation(
                presentationRevision: 20,
                attempt: .settled(reviewGeneration: 5)
            )
        )
        await coordinator.publishPanePresentation(
            coordinatorPanePresentation(
                presentationRevision: 21,
                attempt: .settled(reviewGeneration: 6)
            )
        )
        await coordinator.publishPanePresentation(
            coordinatorPanePresentation(
                presentationRevision: 22,
                attempt: .settled(reviewGeneration: 7)
            )
        )

        let terminal = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )
        )
        let decoder = try BridgeProductMetadataFrameDecoder()
        let decodedFrames = try decoder.append(terminal.data)
        guard case .metadataStreamError(let error) = try #require(decodedFrames.first)
        else {
            Issue.record("Expected pane presentation overflow to emit metadata.streamError")
            return
        }
        #expect(error.code == .resyncRequired)
        #expect(error.retryable)
        await coordinator.uninstall(lease: lease)
    }
}

private actor CoordinatorPanePresentationTraceRecorder:
    BridgeProductMetadataLifecycleTraceRecording
{
    private(set) var presentationEvents: [BridgePanePresentationTraceEvent] = []

    func record(_: BridgeProductMetadataLifecycleTraceEvent) {}

    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) {}

    func record(_ event: BridgePanePresentationTraceEvent) {
        presentationEvents.append(event)
    }
}

private func coordinatorPanePresentation(
    presentationRevision: Int,
    attempt: BridgePaneReviewComparisonAttempt
) -> BridgePaneProductPresentationSnapshot {
    BridgePaneProductPresentationSnapshot(
        nativeActivity: .foreground,
        presentationRevision: presentationRevision,
        refreshingLanes: [.review],
        reviewComparison: BridgePaneReviewComparisonPresentation(
            activeTarget: .branch(name: "comparison-target"),
            attempt: attempt,
            displayedSnapshot: .absent,
            repositoryDefaultTarget: nil
        )
    )
}
