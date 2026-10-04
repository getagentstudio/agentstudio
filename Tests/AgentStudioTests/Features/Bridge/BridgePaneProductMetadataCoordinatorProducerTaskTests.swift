import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product metadata coordinator producer task ownership")
struct BridgeMetadataCoordinatorProducerTaskTests {
    @Test("an internal CancellationError publishes retryable failure without resetting the subscription")
    func internallyThrownCancellationErrorPublishesFailureWithoutReset() async throws {
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
        let source = CoordinatorCancellationErrorFileSource()
        let traceRecorder = CoordinatorProducerTaskTraceRecorder()
        let publishedFileFailures = Mutex<[BridgePaneProductFileRefreshFailure?]>([])
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            recordCurrentFileRefreshFailure: { failure in
                publishedFileFailures.withLock { $0.append(failure) }
            },
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try producerTaskMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )

        // Act
        let token = try #require(producerTaskControlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        _ = try await pullProducerTaskMetadataFrame(from: pump)
        await coordinator.apply(
            effect,
            productAdmission: harness.productAdmission.context
        )
        await traceRecorder.waitUntilBootstrapFinished()

        // Assert
        #expect(await source.didAttemptOpen)
        let currentFailure = publishedFileFailures.withLock { $0.compactMap { $0 }.last }
        #expect(currentFailure == .init(failureKind: .fileSourceUnavailable))
        #expect(currentFailure?.retryable == true)
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: try producerTaskFileSubscriptionSnapshot().subscriptionId
            ) != nil
        )
        #expect(
            await traceRecorder.lifecycleEvents.contains {
                $0.stage == .producerFailed && $0.failureReason == .cancellation
            }
        )
        #expect(await source.cancelledSubscriptionIds.isEmpty)
        await harness.session.settleControlProviderDispatch(token: token)
        #expect(await pump.cancel())
    }

    @Test("actual bootstrap task cancellation does not synthesize a reset")
    func actualBootstrapTaskCancellationDoesNotSynthesizeReset() async throws {
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
        let source = CoordinatorReplacementBootstrapFileMetadataSource()
        let traceRecorder = CoordinatorProducerTaskTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try producerTaskMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        let token = try #require(producerTaskControlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        _ = try await pullProducerTaskMetadataFrame(from: pump)
        await coordinator.apply(
            effect,
            productAdmission: harness.productAdmission.context
        )
        await source.waitUntilOpenStarted(openOrdinal: 1)

        // Act
        await coordinator.apply(
            .subscriptionCancelled(try producerTaskFileSubscriptionSnapshot()),
            productAdmission: harness.productAdmission.context
        )
        await source.waitUntilOpenFinished(openOrdinal: 1)
        await traceRecorder.waitUntilBootstrapFinished()

        // Assert
        #expect(await source.openObservedCancellation(openOrdinal: 1))
        #expect(
            await traceRecorder.lifecycleEvents.contains {
                $0.stage == .producerCancelled && $0.failureReason == .taskCancellation
            }
        )
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        await harness.session.settleControlProviderDispatch(token: token)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("an equal-basis duplicate open rests while the current task handle remains active")
    func equalBasisDuplicateOpenRestsWhileCurrentTaskHandleRemainsActive() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let source = CoordinatorReplacementBootstrapFileMetadataSource()
        let traceRecorder = CoordinatorProducerTaskTraceRecorder()
        let reconciler = BridgeFileSurfaceReconciler()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            fileSurfaceReconciler: reconciler,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try producerTaskMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let subscription = try producerTaskFileSubscriptionSnapshot()
        await coordinator.apply(
            .subscriptionOpened(subscription),
            productAdmission: harness.productAdmission.context
        )
        await source.waitUntilOpenStarted(openOrdinal: 1)
        let activeStream = try #require(await coordinator.activeStream)
        let inputBasis = try #require(
            await coordinator.fileSurfaceInputBasis(for: subscription, activeStream: activeStream)
        )
        let initialAttempt = try #require(await reconciler.activeAttempt)
        await coordinator.apply(
            .subscriptionOpened(subscription),
            productAdmission: harness.productAdmission.context
        )

        #expect(await reconciler.beginAttempt(inputBasis: inputBasis) == .rest)
        #expect(await reconciler.activeAttempt == initialAttempt)
        #expect(await source.didStartOpen(openOrdinal: 2) == false)

        // Act: let the original bootstrap finish after the equal-basis rest.
        await source.releaseOpen(openOrdinal: 1)
        await source.waitUntilOpenFinished(openOrdinal: 1)
        await traceRecorder.waitUntilBootstrapFinished()

        // Assert
        #expect(await source.openObservedCancellation(openOrdinal: 1) == false)
        #expect(await reconciler.activeAttempt == nil)
        #expect(await reconciler.currentFailure == nil)
        await coordinator.uninstall(lease: lease)
    }

    @Test("retained File source reopens after a cancelled bootstrap and resumed stream replay")
    func retainedFileSourceReopensAfterCancelledBootstrapAndResumedStreamReplay() async throws {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let firstLease = try await harness.admitMetadataFrames(through: 0)
        let firstPump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: firstLease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let source = CoordinatorReplacementBootstrapFileMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-before-cancel", resumeFromStreamSequence: nil
            ),
            lease: firstLease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        let token = try #require(producerTaskControlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: token))
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest, worktreeId: nil)
        let effect = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        _ = try await pullProducerTaskMetadataFrame(from: firstPump)
        await coordinator.apply(effect, productAdmission: harness.productAdmission.context)
        await source.waitUntilOpenStarted(openOrdinal: 1)

        let resumedLease = BridgeProductProducerLease(id: UUIDv7.generate())
        await coordinator.install(
            request: try bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-after-cancel", resumeFromStreamSequence: 0
            ),
            lease: resumedLease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )

        await coordinator.replaySubscriptionsForInstalledStream()
        await source.waitUntilOpenStarted(openOrdinal: 2)
        #expect(await coordinator.fileSurfaceReconciler.activeAttempt != nil)
        await source.releaseOpen(openOrdinal: 2)
        await source.waitUntilOpenFinished(openOrdinal: 2)
        #expect(await coordinator.fileSurfaceReconciler.currentFailure == nil)

        await coordinator.uninstall(lease: resumedLease)
        #expect(await firstPump.cancel())
    }

    @Test("replacement install does not return until cancelled predecessor open drains")
    func replacementInstallWaitsForCancelledPredecessorOpenToDrain() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let firstHarness = try await BridgeProductSessionLifecycleHarness.opened()
        let firstLease = try await firstHarness.admitMetadataFrames(through: 0)
        let source = CoordinatorDrainControlledReviewMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: source,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try producerTaskMetadataStreamRequest(),
            lease: firstLease,
            productAdmission: firstHarness.productAdmission.context,
            session: firstHarness.session
        )
        await coordinator.apply(
            .subscriptionOpened(try producerTaskReviewSubscriptionSnapshot()),
            productAdmission: firstHarness.productAdmission.context
        )
        await source.waitUntilOpenStarted()

        let replacementHarness = try await BridgeProductSessionLifecycleHarness.opened()
        let replacementLease = try await replacementHarness.admitMetadataFrames(through: 0)
        let replacementRequest = try producerTaskMetadataStreamRequest()
        let completionProbe = CoordinatorReplacementInstallCompletionProbe()
        let replacementInstall = Task {
            await coordinator.install(
                request: replacementRequest,
                lease: replacementLease,
                productAdmission: replacementHarness.productAdmission.context,
                session: replacementHarness.session
            )
            await completionProbe.recordCompletion()
        }

        // Act
        await source.waitUntilCancelledOpenReachedDrainBarrier()
        for _ in 0..<1000 where !(await completionProbe.didComplete) {
            await Task.yield()
        }
        let completedBeforeDrain = await completionProbe.didComplete
        await source.releaseOpenDrain()
        await replacementInstall.value

        // Assert
        #expect(!completedBeforeDrain)
        #expect(await source.openFinished)
        await coordinator.uninstall(lease: replacementLease)
        try await firstHarness.closeProducer(firstLease)
        try await replacementHarness.closeProducer(replacementLease)
    }

    @Test("subscription cancel does not return until its cancelled producer task drains")
    func subscriptionCancelWaitsForCancelledProducerTaskToDrain() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let source = CoordinatorDrainControlledReviewMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: source,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try producerTaskMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let subscription = try producerTaskReviewSubscriptionSnapshot()
        await coordinator.apply(
            .subscriptionOpened(subscription),
            productAdmission: harness.productAdmission.context
        )
        await source.waitUntilOpenStarted()
        let completionProbe = CoordinatorReplacementInstallCompletionProbe()
        let cancellation = Task {
            await coordinator.apply(
                .subscriptionCancelled(subscription),
                productAdmission: harness.productAdmission.context
            )
            await completionProbe.recordCompletion()
        }

        // Act
        await source.waitUntilCancelledOpenReachedDrainBarrier()
        let completedBeforeDrain = await completionProbe.didComplete
        await source.releaseOpenDrain()
        await cancellation.value

        // Assert
        #expect(!completedBeforeDrain)
        #expect(await source.openFinished)
        await coordinator.uninstall(lease: lease)
        try await harness.closeProducer(lease)
    }

    @Test("coordinator close does not return until cancelled producer tasks drain")
    func closeWaitsForCancelledProducerTasksToDrain() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let source = CoordinatorDrainControlledReviewMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: source,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try producerTaskMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        await coordinator.apply(
            .subscriptionOpened(try producerTaskReviewSubscriptionSnapshot()),
            productAdmission: harness.productAdmission.context
        )
        await source.waitUntilOpenStarted()
        let completionProbe = CoordinatorReplacementInstallCompletionProbe()
        let close = Task {
            await coordinator.closeAndDrain()
            await completionProbe.recordCompletion()
        }

        // Act
        await source.waitUntilCancelledOpenReachedDrainBarrier()
        let completedBeforeDrain = await completionProbe.didComplete
        await source.releaseOpenDrain()
        await close.value

        // Assert
        #expect(!completedBeforeDrain)
        #expect(await source.openFinished)
        #expect(!(await coordinator.hasActiveStream))
        try await harness.closeProducer(lease)
    }

    @Test("Review bootstrap failures retain their typed source and producer causes")
    func reviewBootstrapFailuresRetainTypedCauses() async throws {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let expectations: [(CoordinatorReviewBootstrapFailureMode, BridgeProductMetadataProducerFailureReason)] = [
            (.eventConstruction, .reviewEventConstruction),
            (.producerQueueReset, .producerQueueReset),
            (.producerRejection, .producerRejection(.unknownLease)),
            (.sessionEnqueueFailure, .sessionEnqueueFailure),
            (.unexpected, .unexpected),
        ]

        for (failureMode, expectedReason) in expectations {
            let harness = try await BridgeProductSessionLifecycleHarness.opened()
            let lease = try await harness.admitMetadataFrames(through: 0)
            let traceRecorder = CoordinatorProducerTaskTraceRecorder()
            let coordinator = BridgePaneProductMetadataCoordinator(
                fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
                reviewMetadataSource: CoordinatorThrowingReviewMetadataSource(failureMode: failureMode),
                refreshWorkAdmissionSource: refreshWorkAdmission.source,
                lifecycleTraceRecorder: traceRecorder
            )
            await coordinator.install(
                request: try producerTaskMetadataStreamRequest(),
                lease: lease,
                productAdmission: harness.productAdmission.context,
                session: harness.session
            )

            await coordinator.apply(
                .subscriptionOpened(try producerTaskReviewSubscriptionSnapshot()),
                productAdmission: harness.productAdmission.context
            )
            await traceRecorder.waitUntilBootstrapFinished()

            #expect(
                await traceRecorder.lifecycleEvents.contains {
                    $0.stage == .producerFailed && $0.failureReason == expectedReason
                },
                "Expected typed Review bootstrap failure for \(String(describing: failureMode))"
            )
            await coordinator.uninstall(lease: lease)
            try await harness.closeProducer(lease)
        }
    }
}

private actor CoordinatorReplacementInstallCompletionProbe {
    private(set) var didComplete = false

    func recordCompletion() {
        didComplete = true
    }
}

private actor CoordinatorDrainControlledReviewMetadataSource:
    BridgePaneProductReviewMetadataProducing
{
    private var cancelledOpenReachedDrainBarrier = false
    private var cancelledOpenReachedDrainBarrierWaiters: [CheckedContinuation<Void, Never>] = []
    private var openDrainRelease: CheckedContinuation<Void, Never>?
    private(set) var openFinished = false
    private var openStarted = false
    private var openStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openSuspensionRelease: CheckedContinuation<Void, Never>?

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {
        openStarted = true
        let waiters = openStartedWaiters
        openStartedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            openSuspensionRelease = continuation
        }
        cancelledOpenReachedDrainBarrier = true
        let drainWaiters = cancelledOpenReachedDrainBarrierWaiters
        cancelledOpenReachedDrainBarrierWaiters.removeAll(keepingCapacity: false)
        for waiter in drainWaiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            openDrainRelease = continuation
        }
        openFinished = true
        try Task.checkCancellation()
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgeReviewMetadataPublicationReservation {
        coordinatorReviewReservation(for: package, publicationId: publicationId)
    }

    func deliver(
        publication _: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductReviewMetadataPublicationOutcome {
        .deferred(retained: 0)
    }

    func cancel(subscriptionId _: String) {
        openSuspensionRelease?.resume()
        openSuspensionRelease = nil
    }

    func releaseOpenDrain() {
        openDrainRelease?.resume()
        openDrainRelease = nil
    }

    func waitUntilCancelledOpenReachedDrainBarrier() async {
        guard !cancelledOpenReachedDrainBarrier else { return }
        await withCheckedContinuation { continuation in
            cancelledOpenReachedDrainBarrierWaiters.append(continuation)
        }
    }

    func waitUntilOpenStarted() async {
        guard !openStarted else { return }
        await withCheckedContinuation { continuation in
            openStartedWaiters.append(continuation)
        }
    }
}

private enum CoordinatorReviewBootstrapFailureMode: Sendable {
    case eventConstruction
    case producerQueueReset
    case producerRejection
    case sessionEnqueueFailure
    case unexpected
}

private actor CoordinatorThrowingReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    private let failureMode: CoordinatorReviewBootstrapFailureMode

    init(failureMode: CoordinatorReviewBootstrapFailureMode) {
        self.failureMode = failureMode
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {
        switch failureMode {
        case .eventConstruction:
            throw BridgePaneProductReviewMetadataSourceError.metadataEventExceedsByteLimit
        case .producerQueueReset:
            throw BridgePaneProductMetadataCoordinatorError.producerQueueReset
        case .producerRejection:
            throw BridgePaneProductMetadataCoordinatorError.producerRejected(.unknownLease)
        case .sessionEnqueueFailure:
            throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
        case .unexpected:
            throw CoordinatorProducerTaskTestError.unexpectedReviewBootstrapFailure
        }
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        BridgeReviewMetadataPublicationReservation(
            reservationId: UUID(),
            packageId: package.packageId,
            publicationId: publicationId,
            reviewGeneration: package.reviewGeneration,
            revision: package.revision,
            projectionPlan: try BridgeReviewMetadataPublicationProjectionPlan.prepare(
                package: package,
                publicationId: publicationId
            )
        )
    }

    func deliver(
        publication _: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        .deferred(retained: 0)
    }

    func cancel(subscriptionId _: String) {}
}

private actor CoordinatorReplacementBootstrapFileMetadataSource:
    BridgePaneProductFileMetadataProducing
{
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private var finishedOpenOrdinals: Set<Int> = []
    private var finishedOpenWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var nextOpenOrdinal = 1
    private var observedCancellationByOpenOrdinal: [Int: Bool] = [:]
    private var openReleaseByOrdinal: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedOpenOrdinals: Set<Int> = []
    private var startedOpenWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        let openOrdinal = nextOpenOrdinal
        nextOpenOrdinal += 1
        startedOpenOrdinals.insert(openOrdinal)
        for waiter in startedOpenWaiters.removeValue(forKey: openOrdinal) ?? [] {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            openReleaseByOrdinal[openOrdinal] = continuation
        }
        observedCancellationByOpenOrdinal[openOrdinal] = Task.isCancelled
        finishedOpenOrdinals.insert(openOrdinal)
        for waiter in finishedOpenWaiters.removeValue(forKey: openOrdinal) ?? [] {
            waiter.resume()
        }
        try Task.checkCancellation()
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func cancel(subscriptionId _: String) {
        let releases = openReleaseByOrdinal.values
        openReleaseByOrdinal.removeAll(keepingCapacity: false)
        for release in releases { release.resume() }
    }

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] { [] }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }

    func openObservedCancellation(openOrdinal: Int) -> Bool {
        observedCancellationByOpenOrdinal[openOrdinal] ?? false
    }

    func didStartOpen(openOrdinal: Int) -> Bool {
        startedOpenOrdinals.contains(openOrdinal)
    }

    func releaseOpen(openOrdinal: Int) {
        openReleaseByOrdinal.removeValue(forKey: openOrdinal)?.resume()
    }

    func waitUntilOpenFinished(openOrdinal: Int) async {
        guard !finishedOpenOrdinals.contains(openOrdinal) else { return }
        await withCheckedContinuation { continuation in
            finishedOpenWaiters[openOrdinal, default: []].append(continuation)
        }
    }

    func waitUntilOpenStarted(openOrdinal: Int) async {
        guard !startedOpenOrdinals.contains(openOrdinal) else { return }
        await withCheckedContinuation { continuation in
            startedOpenWaiters[openOrdinal, default: []].append(continuation)
        }
    }
}

private actor CoordinatorCancellationErrorFileSource:
    BridgePaneProductFileMetadataProducing
{
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private(set) var didAttemptOpen = false
    private(set) var cancelledSubscriptionIds: [String] = []

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        didAttemptOpen = true
        throw CancellationError()
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func cancel(subscriptionId: String) {
        cancelledSubscriptionIds.append(subscriptionId)
    }

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] { [] }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }
}

private actor CoordinatorProducerTaskTraceRecorder: BridgeProductMetadataLifecycleTraceRecording {
    private var bootstrapFinished = false
    private var bootstrapFinishedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lifecycleEvents: [BridgeProductMetadataLifecycleTraceEvent] = []

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) {
        lifecycleEvents.append(event)
        guard event.stage == .bootstrapFinished else { return }
        bootstrapFinished = true
        let waiters = bootstrapFinishedWaiters
        bootstrapFinishedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) {}

    func waitUntilBootstrapFinished() async {
        guard !bootstrapFinished else { return }
        await withCheckedContinuation { continuation in
            bootstrapFinishedWaiters.append(continuation)
        }
    }
}

private enum CoordinatorProducerTaskTestError: Error {
    case expectedMetadataFrame
    case invalidFileSubscription
    case invalidReviewSubscription
    case unexpectedReviewBootstrapFailure
}

private func pullProducerTaskMetadataFrame(
    from pump: BridgeProductSchemeFramePump
) async throws -> BridgeProductMetadataFrame {
    guard case .frame(let delivery) = await pump.nextFrame() else {
        throw CoordinatorProducerTaskTestError.expectedMetadataFrame
    }
    #expect(await pump.acknowledgeFrameConsumed(delivery.receipt))
    let decoder = try BridgeProductMetadataFrameDecoder()
    return try #require(try decoder.append(delivery.frame.data).first)
}

private func producerTaskControlExecutionToken(
    _ admission: BridgeProductSessionControlAdmission
) -> BridgeProductControlAdmissionToken? {
    guard case .execute(let token, _) = admission else { return nil }
    return token
}

private func producerTaskFileSubscriptionSnapshot() throws -> BridgeProductSubscriptionSnapshot {
    let request = try bridgeProductLifecycleControlRequest(
        bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
    )
    guard case .subscriptionOpen(let openRequest) = request else {
        throw CoordinatorProducerTaskTestError.invalidFileSubscription
    }
    var state = BridgeProductSubscriptionState()
    _ = try state.open(openRequest)
    guard let snapshot = state.snapshot(subscriptionId: openRequest.subscriptionId) else {
        throw CoordinatorProducerTaskTestError.invalidFileSubscription
    }
    return snapshot
}

private func producerTaskReviewSubscriptionSnapshot() throws -> BridgeProductSubscriptionSnapshot {
    let request = try bridgeProductLifecycleControlRequest(
        bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
    )
    guard case .subscriptionOpen(let openRequest) = request else {
        throw CoordinatorProducerTaskTestError.invalidReviewSubscription
    }
    var state = BridgeProductSubscriptionState()
    _ = try state.open(openRequest)
    guard let snapshot = state.snapshot(subscriptionId: openRequest.subscriptionId) else {
        throw CoordinatorProducerTaskTestError.invalidReviewSubscription
    }
    return snapshot
}

private func producerTaskMetadataStreamRequest() throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-stream-producer-task",
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}
