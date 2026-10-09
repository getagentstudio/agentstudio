import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product metadata activity admission")
struct BridgePaneProductMetadataActivityAdmissionTests {
    @Test("loaded-hidden metadata retains File and Review intent without source or replay work")
    @MainActor
    func loadedHiddenMetadataRetainsIntentWithoutSourceWork() async throws {
        // Arrange
        let context = try await makeActivityMetadataContext(initialActivity: .loadedHidden)
        let fileOpen = try await openActivityMetadataSubscription(
            context: context,
            object: bridgeProductLifecycleFileSubscriptionOpenObject(
                requestSequence: 2,
                epoch: 1
            ),
            subscriptionId: "file-subscription-1"
        )
        let reviewOpen = try await openActivityMetadataSubscription(
            context: context,
            object: bridgeProductLifecycleReviewSubscriptionOpenObject(
                requestSequence: 3,
                epoch: 1
            ),
            subscriptionId: "review-subscription-1"
        )
        // Act
        await applyActivityMetadataEffect(
            .subscriptionCancelled(fileOpen),
            request: context.fileOpenRequest,
            context: context
        )
        await applyActivityMetadataEffect(
            .subscriptionCancelled(reviewOpen),
            request: context.reviewOpenRequest,
            context: context
        )

        // Assert
        #expect(await context.fileSource.openCallCount == 0)
        #expect(await context.fileSource.statusPublicationCallCount == 0)
        #expect(await context.fileSource.descriptorSourceCallCount == 0)
        #expect(await context.reviewSource.openCallCount == 0)
        #expect(await context.reviewSource.reserveCallCount == 0)
        #expect(await context.reviewSource.deliverCallCount == 0)
        #expect(context.reviewReplayProbe.callCount == 0)
        #expect((await context.harness.session.producerSnapshot()).queuedFrameCount == 0)

        // Cancellation reaching both sources proves the hidden effects retained subscription intent.
        #expect(await context.fileSource.cancelledSubscriptionIds == ["file-subscription-1"])
        #expect(await context.reviewSource.cancelledSubscriptionIds == ["review-subscription-1"])
        await finishActivityMetadataContext(context)
    }

    @Test("hiding after metadata source admission suppresses its pending File frame")
    @MainActor
    func hidingBetweenMetadataAdmissionAndEnqueueSuppressesFrame() async throws {
        // Arrange
        let context = try await makeActivityMetadataContext(
            initialActivity: .foreground,
            suspendFileSourceBeforeEmission: true
        )
        let fileOpen = try await openActivityMetadataSubscription(
            context: context,
            object: bridgeProductLifecycleFileSubscriptionOpenObject(
                requestSequence: 2,
                epoch: 1
            ),
            subscriptionId: "file-subscription-1"
        )
        await context.fileSource.waitUntilEmissionReady()
        #expect((await context.harness.session.producerSnapshot()).queuedFrameCount == 0)

        // Act
        context.activityCoordinator.applyActivity(.loadedHidden)
        await context.fileSource.releaseEmission()
        await context.fileSource.waitUntilEmissionFinished()
        let hiddenSnapshot = await context.harness.session.producerSnapshot()

        // Assert
        #expect(await context.fileSource.openCallCount == 1)
        #expect(await context.fileSource.emissionAttemptCount == 1)
        #expect(hiddenSnapshot.queuedFrameCount == 0)
        await applyActivityMetadataEffect(
            .subscriptionCancelled(fileOpen),
            request: context.fileOpenRequest,
            context: context
        )
        await finishActivityMetadataContext(context)
    }
}

@MainActor
private final class ActivityReviewPublicationReplayProbe {
    private(set) var callCount = 0

    func recordCall() -> BridgeReviewCommittedPublication? {
        callCount += 1
        return nil
    }
}

struct ActivityMetadataContext {
    let activityCoordinator: BridgePaneRefreshAdmissionCoordinator
    let fileOpenRequest: BridgeProductControlRequest
    let fileSource: ActivityMetadataFileSource
    let harness: BridgeProductSessionLifecycleHarness
    let lease: BridgeProductProducerLease
    let provider: BridgePaneProductSchemeProvider
    let pump: BridgeProductSchemeFramePump
    let reviewOpenRequest: BridgeProductControlRequest
    fileprivate let reviewReplayProbe: ActivityReviewPublicationReplayProbe
    fileprivate let reviewSource: ActivityMetadataReviewSource
}

@MainActor
func makeActivityMetadataContext(
    initialActivity: BridgePaneActivity,
    suspendFileSourceBeforeEmission: Bool = false
) async throws -> ActivityMetadataContext {
    let activityCoordinator = BridgePaneRefreshAdmissionCoordinator(
        initialActivity: initialActivity
    )
    let fileSource = ActivityMetadataFileSource(
        suspendBeforeEmission: suspendFileSourceBeforeEmission
    )
    let reviewSource = ActivityMetadataReviewSource()
    let reviewReplayProbe = ActivityReviewPublicationReplayProbe()
    let provider = BridgePaneProductSchemeProvider(
        fileMetadataSource: fileSource,
        reviewMetadataSource: reviewSource,
        reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
        reviewPublicationReplay: { _ in reviewReplayProbe.recordCall() },
        markReviewItemViewed: { _, _ in },
        refreshWorkAdmissionSource: activityCoordinator.workAdmissionSource
    )
    let harness = try await BridgeProductSessionLifecycleHarness.opened()
    let request = try activityMetadataStreamRequest()
    let registration = await harness.session.registerMetadataProducer(
        request: request,
        productAdmission: harness.productAdmission.context
    ) { lease in
        await provider.runMetadataProducer(
            request: request,
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
    }
    let lease = try bridgeProductAcceptedLease(registration)
    let pump = BridgeProductSchemeFramePump(
        session: harness.session,
        producerLease: lease,
        productAdmission: harness.productAdmission.context,
        acknowledgeLifecycle: provider.acknowledgeLifecycle
    )
    let opening = try await requiredActivityMetadataFrame(from: pump)
    guard case .metadataStreamAccepted = opening else {
        throw ActivityMetadataAdmissionTestError.expectedMetadataStreamAccepted
    }
    return ActivityMetadataContext(
        activityCoordinator: activityCoordinator,
        fileOpenRequest: try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        ),
        fileSource: fileSource,
        harness: harness,
        lease: lease,
        provider: provider,
        pump: pump,
        reviewOpenRequest: try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 3, epoch: 1)
        ),
        reviewReplayProbe: reviewReplayProbe,
        reviewSource: reviewSource
    )
}

actor ActivityMetadataFileSource: BridgePaneProductFileMetadataProducing {
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private let suspendBeforeEmission: Bool
    private var emissionFinished = false
    private var emissionFinishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var emissionReady = false
    private var emissionReadyWaiters: [CheckedContinuation<Void, Never>] = []
    private var emissionReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isEmissionReleased = false
    private(set) var cancelledSubscriptionIds: [String] = []
    private(set) var descriptorSourceCallCount = 0
    private(set) var emissionAttemptCount = 0
    private(set) var openCallCount = 0
    private(set) var statusPublicationCallCount = 0
    private(set) var updateCallCount = 0

    init(suspendBeforeEmission: Bool) {
        self.suspendBeforeEmission = suspendBeforeEmission
    }

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        openCallCount += 1
        await waitBeforeEmissionIfRequired()
        emissionAttemptCount += 1
        defer { finishEmission() }
        try await emit(try activityFileSourceAcceptedEvent())
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        updateCallCount += 1
        descriptorSourceCallCount += 1
        try await emit(try activityFileSourceAcceptedEvent())
    }

    func cancel(subscriptionId: String) {
        cancelledSubscriptionIds.append(subscriptionId)
    }

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] {
        statusPublicationCallCount += 1
        return []
    }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        statusPublicationCallCount += 1
        return []
    }

    func authoritativePath(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> String? {
        descriptorSourceCallCount += 1
        return nil
    }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? {
        descriptorSourceCallCount += 1
        return nil
    }

    func waitUntilEmissionReady() async {
        guard !emissionReady else { return }
        await withCheckedContinuation { continuation in
            emissionReadyWaiters.append(continuation)
        }
    }

    func releaseEmission() {
        isEmissionReleased = true
        let waiters = emissionReleaseWaiters
        emissionReleaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilEmissionFinished() async {
        guard !emissionFinished else { return }
        await withCheckedContinuation { continuation in
            emissionFinishedWaiters.append(continuation)
        }
    }

    private func waitBeforeEmissionIfRequired() async {
        emissionReady = true
        let readyWaiters = emissionReadyWaiters
        emissionReadyWaiters.removeAll(keepingCapacity: false)
        for waiter in readyWaiters { waiter.resume() }
        guard suspendBeforeEmission, !isEmissionReleased else { return }
        await withCheckedContinuation { continuation in
            emissionReleaseWaiters.append(continuation)
        }
    }

    private func finishEmission() {
        emissionFinished = true
        let waiters = emissionFinishedWaiters
        emissionFinishedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private actor ActivityMetadataReviewSource: BridgePaneProductReviewMetadataProducing {
    private(set) var cancelledSubscriptionIds: [String] = []
    private(set) var deliverCallCount = 0
    private(set) var openCallCount = 0
    private(set) var reserveCallCount = 0
    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) {
        openCallCount += 1
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) throws -> BridgeReviewMetadataPublicationReservation {
        reserveCallCount += 1
        return BridgeReviewMetadataPublicationReservation(
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
    ) -> BridgePaneProductReviewMetadataPublicationOutcome {
        deliverCallCount += 1
        return .deferred(retained: 0)
    }

    func cancel(subscriptionId: String) {
        cancelledSubscriptionIds.append(subscriptionId)
    }
}

func openActivityMetadataSubscription(
    context: ActivityMetadataContext,
    object: [String: Any],
    subscriptionId: String
) async throws -> BridgeProductSubscriptionSnapshot {
    let request = try bridgeProductLifecycleControlRequest(object)
    guard case .execute(let token, _) = try await context.harness.begin(request) else {
        throw ActivityMetadataAdmissionTestError.expectedControlExecution
    }
    #expect(await context.harness.session.admitControlProviderExecution(token: token))
    let response = try BridgeProductControlResponse.subscriptionOpenAccepted(correlating: request, worktreeId: nil)
    let effect = try await context.harness.session.completeAdmittedControl(
        token: token,
        exactResponseBytes: try JSONEncoder().encode(response)
    )
    let accepted = try await requiredActivityMetadataFrame(from: context.pump)
    guard case .subscriptionAccepted = accepted else {
        throw ActivityMetadataAdmissionTestError.expectedSubscriptionAccepted
    }
    await context.provider.applyCommittedControlEffect(
        effect,
        for: request,
        productAdmission: context.harness.productAdmission.context
    )
    await context.harness.session.settleControlProviderDispatch(token: token)
    return try #require(
        await context.harness.session.subscriptionSnapshot(subscriptionId: subscriptionId)
    )
}

private func applyActivityMetadataEffect(
    _ effect: BridgeProductSessionCompletionEffect,
    request: BridgeProductControlRequest,
    context: ActivityMetadataContext
) async {
    await context.provider.applyCommittedControlEffect(
        effect,
        for: request,
        productAdmission: context.harness.productAdmission.context
    )
}

func requiredActivityMetadataFrame(
    from pump: BridgeProductSchemeFramePump
) async throws -> BridgeProductMetadataFrame {
    guard case .frame(let delivery) = await pump.nextFrame() else {
        throw ActivityMetadataAdmissionTestError.expectedMetadataFrame
    }
    #expect(await pump.acknowledgeFrameConsumed(delivery.receipt))
    let decoder = try BridgeProductMetadataFrameDecoder()
    return try #require(try decoder.append(delivery.frame.data).first)
}

private func activityFileSourceAcceptedEvent() throws -> BridgePaneProductFileSourceFact {
    .sourceAccepted(
        try .init(
            repoId: "00000000-0000-4000-8000-000000000001",
            rootRevisionToken: "root-token-activity",
            sourceCursor: "source-cursor-activity",
            sourceId: "file-source-activity",
            subscriptionGeneration: 1,
            worktreeId: "00000000-0000-4000-8000-000000000002"
        ))
}

private func activityMetadataStreamRequest() throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-stream-activity",
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: data
    )
}

func finishActivityMetadataContext(_ context: ActivityMetadataContext) async {
    #expect(await context.pump.cancel())
    await context.provider.closeAndDrain()
    #expect((await context.harness.session.producerSnapshot()).hasZeroResidue)
}

enum ActivityMetadataAdmissionTestError: Error {
    case expectedControlExecution
    case expectedMetadataFrame
    case expectedMetadataStreamAccepted
    case expectedSubscriptionAccepted
}
