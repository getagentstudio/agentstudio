import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgePaneControllerProductBootstrapDeliveryTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("committed Review survives bootstrap failure and replays after worker replacement")
        func committedReviewSurvivesBootstrapFailureAndReplaysAfterWorkerReplacement() async throws {
            // Arrange
            let paneId = UUIDv7.generate()
            let reviewFixture = makeBootstrapCommittedReviewFixture()
            var deliveredInstallations: [BridgeProductSessionInstallation] = []
            let controller = BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "Sources",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: reviewFixture.sourceProvider,
                initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, installation, _, _ in
                    deliveredInstallations.append(installation)
                    if deliveredInstallations.count == 1 {
                        throw BridgeError.encoding("simulated ambiguous delivery failure")
                    }
                }
            )
            let visibleInstallation = try #require(await controller.productSessionOwner.activeInstallation)
            let visibleAdmission = try #require(controller.productAdmissionGate.acquire())
            let visibleMetadataProducer = try await installRefreshAdmissionMetadataProducer(
                installation: visibleInstallation,
                productProvider: try #require(controller.productSchemeProvider),
                productAdmission: visibleAdmission
            )
            // G2 uses the page's accepted mode after the worker and metadata stream open.
            await sendPageActiveViewerMode(
                .review, controller: controller, productAdmission: visibleAdmission, sequence: 1
            )
            let commandId = UUIDv7.generate()
            let loadResult = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: reviewFixture.headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: commandId,
                correlationId: nil
            )
            #expect(loadResult == .success(commandId: commandId))
            let committedPackage = try #require(controller.paneState.diff.packageMetadata)
            let committedDelta = controller.paneState.diff.packageDelta
            try await closeBridgeProductSessionProducer(visibleMetadataProducer, in: visibleInstallation.session)

            // Act
            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "failed-initial-bootstrap",
                reason: .initial
            )
            let initialInstallation = try #require(deliveredInstallations.first)
            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "retry-initial-bootstrap",
                reason: .initial
            )
            let replacementInstallation = try #require(deliveredInstallations.last)
            #expect(
                (await controller.productSessionOwner.activeInstallation)?.bootstrap.workerInstanceId
                    == replacementInstallation.bootstrap.workerInstanceId
            )
            _ = try await assertRetiredPaneProductCommandRefusal(
                installation: initialInstallation,
                handler: BridgeSchemeHandler(
                    paneId: paneId, appRootURL: testBridgeAppRootURL(),
                    productSessionRouter: await controller.productSessionOwner.schemeRouter
                )
            )
            let productProvider = try #require(controller.productSchemeProvider)
            let replaySubscription = try await openBootstrapReviewReplaySubscription(
                controller: controller,
                installation: replacementInstallation,
                productProvider: productProvider
            )
            let replayPublication = try await consumeBootstrapReviewPublication(
                subscription: replaySubscription,
                installation: replacementInstallation
            )

            // Assert
            #expect(deliveredInstallations.count == 2)
            #expect(
                replacementInstallation.bootstrap.workerInstanceId
                    != initialInstallation.bootstrap.workerInstanceId
            )
            #expect(replacementInstallation.capabilityBytes != initialInstallation.capabilityBytes)
            #expect(controller.paneState.diff.packageMetadata == committedPackage)
            #expect(controller.paneState.diff.packageDelta == committedDelta)
            await #expect(throws: Never.self) {
                _ = try await controller.loadContentForIPC(
                    contentHandleId: reviewFixture.committedHandle.handleId,
                    reviewGeneration: reviewFixture.committedHandle.reviewGeneration.rawValue
                )
            }
            #expect(replayPublication.displayed?.packageId == committedPackage.packageId)
            #expect(replayPublication.displayed?.generation == committedPackage.reviewGeneration.rawValue)
            try await closeBridgeProductSessionProducer(
                replaySubscription.lease,
                in: replacementInstallation.session
            )
            #expect(await controller.beginTeardown().value)
        }

        @Test("pane close suppresses a suspended product bootstrap delivery")
        func paneCloseSuppressesSuspendedProductBootstrapDelivery() async throws {
            // Arrange
            let paneId = UUIDv7.generate()
            let provider = BridgePaneProductSessionProviderGate()
            let productAdmissionGate = BridgeProductAdmissionGate()
            let initialInstallation = BridgePaneController.makeInitialProductSessionInstallation(
                paneSessionId: paneId.uuidString,
                provider: provider,
                productAdmissionGate: productAdmissionGate
            )
            let owner = BridgePaneController.makeProductSessionOwner(
                paneSessionId: paneId.uuidString,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                activeInstallation: initialInstallation
            )
            let deliverySuspension = BridgeProductBootstrapDeliverySuspension()
            var deliveredWorkerInstanceIds: [String] = []
            let controller = BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "close-bootstrap")),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionDependencies: BridgePaneProductSessionDependencies(
                    installation: initialInstallation,
                    owner: owner
                ),
                productSessionBootstrapSink: { _, _, installation, _, productAdmission in
                    await deliverySuspension.suspendDelivery()
                    _ = productAdmission.withValidAdmission {
                        deliveredWorkerInstanceIds.append(installation.bootstrap.workerInstanceId)
                    }
                }
            )

            // Act
            let bootstrapTask = Task { @MainActor in
                await controller.enqueueProductSessionBootstrapRequest(
                    requestId: "suspended-initial-bootstrap",
                    reason: .initial
                )
            }
            await deliverySuspension.waitUntilDeliveryIsSuspended()
            let teardownTask = controller.beginTeardown()
            await deliverySuspension.resumeDelivery()
            await bootstrapTask.value
            let teardownSucceeded = await teardownTask.value
            let ownerSnapshot = await owner.snapshot()

            // Assert
            #expect(deliveredWorkerInstanceIds.isEmpty)
            #expect(teardownSucceeded)
            #expect(ownerSnapshot.hasZeroResidue)
            #expect(productAdmissionGate.diagnosticSnapshot.isOpen == false)
        }

        @Test("surface command queued during replacement binds to the replacement worker")
        func surfaceCommandDuringReplacementBindsToReplacementWorker() async throws {
            // Arrange
            var deliveredInstallations: [BridgeProductSessionInstallation] = []
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .fileViewer,
                    source: .workspace(
                        rootPath: "Sources", baseline: .unstaged
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, installation, _, _ in
                    deliveredInstallations.append(installation)
                }
            )
            controller.hasPublishedProductSessionBootstrap = true
            #expect(await controller.productSessionOwner.retire(reason: .workerReplacement) == .retired)
            #expect(await controller.productSessionOwner.activeBootstrap() == nil)

            // Act: the command is admitted while no worker is active.
            #expect(controller.requestViewerSurface(.review))
            _ = await controller.surfaceSelectionTransitionTail?.value
            let queuedSnapshot = controller.surfaceSelectionAuthority.diagnosticSnapshot

            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "replacement-after-surface-command",
                reason: .workerReplacement
            )

            // Assert: bootstrap activation remints the retained intent for worker B.
            #expect(queuedSnapshot.desiredSurface == .review)
            #expect(queuedSnapshot.needsDelivery)
            #expect(queuedSnapshot.currentRequest == nil)
            let replacement = try #require(deliveredInstallations.last)
            let replacementRequest = try #require(
                controller.surfaceSelectionAuthority.diagnosticSnapshot.currentRequest
            )
            #expect(replacementRequest.surface == .review)
            #expect(replacementRequest.paneSessionId == replacement.bootstrap.paneSessionId)
            #expect(replacementRequest.workerInstanceId == replacement.bootstrap.workerInstanceId)

            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let correlation = try BridgeProductControlCorrelation(
                paneSessionId: replacement.bootstrap.paneSessionId,
                requestId: "replacement-surface-receipt",
                requestSequence: 1,
                workerInstanceId: replacement.bootstrap.workerInstanceId
            )
            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "replacement-viewer-session",
                sequence: 1,
                mode: .review,
                activeSource: nil,
                productAdmission: productAdmission,
                nativeSelectionRequestId: replacementRequest.requestId,
                productCorrelation: correlation
            )
            #expect(
                controller.surfaceSelectionAuthority.diagnosticSnapshot.lastAcceptedRequest
                    == replacementRequest
            )
            #expect(await controller.beginTeardown().value)
        }

        @Test("exact Review command rejected without an active worker cannot replay")
        func rejectedExactReviewCommandCannotReplayAfterReplacement() async throws {
            // Arrange
            var deliveredInstallations: [BridgeProductSessionInstallation] = []
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "Sources", baseline: .unstaged
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, installation, _, _ in
                    deliveredInstallations.append(installation)
                }
            )
            controller.hasPublishedProductSessionBootstrap = true
            #expect(await controller.productSessionOwner.retire(reason: .workerReplacement) == .retired)
            #expect(await controller.productSessionOwner.activeBootstrap() == nil)
            let reviewSource = BridgeProductNavigationReviewSource(
                generation: 1,
                metadataSourceId: "review-query-rejected-during-replacement",
                packageId: "review-package-rejected-during-replacement"
            )
            let reviewTarget = BridgeProductNavigationReviewTarget(
                reviewItemId: "review-item-rejected-during-replacement"
            )

            // Act
            await #expect(throws: CancellationError.self) {
                try await controller.requestReviewTargetAndPublish(
                    source: reviewSource,
                    target: reviewTarget
                )
            }
            let rejectedSnapshot = controller.surfaceSelectionAuthority.diagnosticSnapshot
            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "replacement-after-rejected-exact-review",
                reason: .workerReplacement
            )
            let replacementInstallation = try #require(deliveredInstallations.last)
            let productProvider = try #require(controller.productSchemeProvider)
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let replacementMetadataProducer = try await installRefreshAdmissionMetadataProducer(
                installation: replacementInstallation,
                productProvider: productProvider,
                productAdmission: productAdmission
            )

            // Assert
            #expect(rejectedSnapshot.desiredSurface == nil)
            #expect(rejectedSnapshot.currentRequest == nil)
            #expect(controller.surfaceSelectionAuthority.diagnosticSnapshot.desiredSurface == nil)
            #expect(controller.surfaceSelectionAuthority.diagnosticSnapshot.currentRequest == nil)
            await #expect(throws: BootstrapSurfaceSelectionReplayError.self) {
                try await consumeBootstrapSurfaceSelectionRequest(
                    producerLease: replacementMetadataProducer,
                    installation: replacementInstallation,
                    productAdmission: productAdmission
                )
            }
            try await closeBridgeProductSessionProducer(
                replacementMetadataProducer,
                in: replacementInstallation.session
            )
            #expect(await controller.beginTeardown().value)
        }

        @Test("queued exact Review command keeps ownership across worker replacement")
        func queuedExactReviewCommandKeepsOwnershipAcrossWorkerReplacement() async throws {
            // Arrange
            let transitionSuspension = BridgeProductBootstrapDeliverySuspension()
            let overlapState = BootstrapReplacementOverlapState()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "Sources", baseline: .unstaged
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, installation, _, productAdmission in
                    overlapState.deliveredInstallations.append(installation)
                    do {
                        let activeController = try #require(overlapState.controller)
                        let productProvider = try #require(activeController.productSchemeProvider)
                        overlapState.replacementMetadataProducer =
                            try await installRefreshAdmissionMetadataProducer(
                                installation: installation,
                                productProvider: productProvider,
                                productAdmission: productAdmission
                            )
                    } catch {
                        await transitionSuspension.resumeDelivery()
                        throw error
                    }
                    await transitionSuspension.resumeDelivery()
                }
            )
            overlapState.controller = controller
            controller.hasPublishedProductSessionBootstrap = true
            controller.surfaceSelectionTransitionTail = Task { @MainActor in
                await transitionSuspension.suspendDelivery()
                return true
            }
            await transitionSuspension.waitUntilDeliveryIsSuspended()
            let reviewSource = BridgeProductNavigationReviewSource(
                generation: 1,
                metadataSourceId: "review-query-queued-during-replacement",
                packageId: "review-package-queued-during-replacement"
            )
            let reviewTarget = BridgeProductNavigationReviewTarget(
                reviewItemId: "review-item-queued-during-replacement"
            )

            // Act
            let exactCommandTask = Task { @MainActor in
                do {
                    try await controller.requestReviewTargetAndPublish(
                        source: reviewSource,
                        target: reviewTarget
                    )
                    return true
                } catch {
                    return false
                }
            }
            var exactCommandWasRetained = false
            for _ in 0..<1000 {
                if controller.surfaceSelectionAuthority.diagnosticSnapshot.desiredSurface == .review {
                    exactCommandWasRetained = true
                    break
                }
                await Task.yield()
            }
            #expect(exactCommandWasRetained)
            let bootstrapTask = Task { @MainActor in
                await controller.enqueueProductSessionBootstrapRequest(
                    requestId: "replacement-overlapping-queued-exact-review",
                    reason: .workerReplacement
                )
            }
            let exactCommandSucceeded = await exactCommandTask.value
            await bootstrapTask.value
            let replacementInstallation = try #require(overlapState.deliveredInstallations.last)
            let metadataProducer = try #require(overlapState.replacementMetadataProducer)
            // E1 composes the producer claim with the replacement installation's admission.
            let publishedRequest = try await consumeBootstrapSurfaceSelectionRequest(
                producerLease: metadataProducer,
                installation: replacementInstallation,
                productAdmission: try #require(replacementInstallation.productAdapter.acquireAdmission())
            )

            // Assert
            #expect(exactCommandSucceeded)
            guard
                case .activateReviewTarget(_, _, let publishedSource, let publishedTarget) =
                    publishedRequest.navigationCommand
            else {
                Issue.record("Expected the queued exact Review command on the replacement worker")
                return
            }
            #expect(publishedSource == reviewSource)
            #expect(publishedTarget == reviewTarget)
            try await closeBridgeProductSessionProducer(
                metadataProducer,
                in: replacementInstallation.session
            )
            #expect(await controller.beginTeardown().value)
        }

        @Test("exact Review target replays after the replacement metadata stream opens")
        func exactReviewTargetReplaysAfterReplacementMetadataStreamOpens() async throws {
            // Arrange
            var deliveredInstallations: [BridgeProductSessionInstallation] = []
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "Sources", baseline: .unstaged
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, installation, _, _ in
                    deliveredInstallations.append(installation)
                }
            )
            let initialInstallation = try #require(
                await controller.productSessionOwner.activeInstallation
            )
            let productProvider = try #require(controller.productSchemeProvider)
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let initialMetadataProducer = try await installRefreshAdmissionMetadataProducer(
                installation: initialInstallation,
                productProvider: productProvider,
                productAdmission: productAdmission
            )
            let reviewSource = BridgeProductNavigationReviewSource(
                generation: 1,
                metadataSourceId: "review-query-replacement",
                packageId: "review-package-replacement"
            )
            let reviewTarget = BridgeProductNavigationReviewTarget(
                reviewItemId: "review-item-replacement"
            )
            try await controller.requestReviewTargetAndPublish(
                source: reviewSource,
                target: reviewTarget
            )
            let initialRequest = try await consumeBootstrapSurfaceSelectionRequest(
                producerLease: initialMetadataProducer,
                installation: initialInstallation,
                productAdmission: productAdmission
            )
            try await closeBridgeProductSessionProducer(
                initialMetadataProducer,
                in: initialInstallation.session
            )
            controller.hasPublishedProductSessionBootstrap = true

            // Act
            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "replacement-with-exact-review-target",
                reason: .workerReplacement
            )
            let replacementInstallation = try #require(deliveredInstallations.last)
            let replacementMetadataProducer = try await installRefreshAdmissionMetadataProducer(
                installation: replacementInstallation,
                productProvider: productProvider,
                productAdmission: productAdmission
            )
            let replacementSnapshot = await replacementInstallation.session.producerSnapshot()
            let replacementRequest: BridgeProductPaneSurfaceSelectionRequestedFrame?
            if replacementSnapshot.queuedFrameCount > 0 {
                replacementRequest = try await consumeBootstrapSurfaceSelectionRequest(
                    producerLease: replacementMetadataProducer,
                    installation: replacementInstallation,
                    productAdmission: productAdmission
                )
            } else {
                replacementRequest = nil
            }

            // Assert
            let replayedRequest = try #require(replacementRequest)
            #expect(
                replayedRequest.navigationCommand.commandId
                    == initialRequest.navigationCommand.commandId
            )
            #expect(
                replayedRequest.navigationCommand.bindingRevision
                    > initialRequest.navigationCommand.bindingRevision
            )
            #expect(
                replayedRequest.frameIdentity.workerInstanceId
                    == replacementInstallation.bootstrap.workerInstanceId
            )
            guard
                case .activateReviewTarget(_, _, let replayedSource, let replayedTarget) =
                    replayedRequest.navigationCommand
            else {
                Issue.record("Expected the replacement stream to replay the exact Review target")
                return
            }
            #expect(replayedSource == reviewSource)
            #expect(replayedTarget == reviewTarget)
            try await closeBridgeProductSessionProducer(
                replacementMetadataProducer,
                in: replacementInstallation.session
            )
            #expect(await controller.beginTeardown().value)
        }

        @Test("hidden Review intake never builds", arguments: ["background-warmup", "sequence_gap"])
        func hiddenReviewIntakeKeepsListenerReadinessAndExplicitRequestsInert(reason: String) async throws {
            let nilStream = try await makeBootstrapColdReviewIntakeFixture()
            let currentStream = try await makeBootstrapColdReviewIntakeFixture()
            let staleStream = try await makeBootstrapColdReviewIntakeFixture()
            let fixtures = [nilStream, currentStream, staleStream]
            defer {
                for fixture in fixtures {
                    // fire-and-forget: defer cannot await; cleanup only
                    _ = fixture.controller.beginTeardown()
                }
            }
            // G2 takes visibility from page mode; File mode keeps all Review intake hidden.
            for fixture in fixtures {
                await sendPageActiveViewerMode(
                    .file, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 1
                )
            }
            let nilStreamController = nilStream.controller
            await nilStreamController.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(reason: nil, streamId: nil),
                productAdmission: nilStream.productAdmission
            )
            #expect(nilStreamController.activeReviewRefreshTask == nil)
            #expect(nilStreamController.paneState.diff.packageMetadata == nil)

            await nilStreamController.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(reason: reason, streamId: nil),
                productAdmission: nilStream.productAdmission
            )
            await currentStream.controller.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(
                    reason: reason, streamId: currentStream.controller.reviewProtocolStreamId()
                ), productAdmission: currentStream.productAdmission
            )
            await staleStream.controller.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(reason: reason, streamId: "review:stale-stream"),
                productAdmission: staleStream.productAdmission
            )
            for fixture in fixtures {
                #expect(fixture.controller.activeReviewRefreshTask == nil)
                #expect(fixture.controller.paneState.diff.packageMetadata == nil)
                #expect(await fixture.sourceProvider.recordedComparisonRequestsCount() == 0)
                #expect(await fixture.controller.beginTeardown().value)
            }
        }

        @Test(
            "shown Review accepts nil or current intake and drops stale intake without another build",
            arguments: ["background-warmup", "sequence_gap"]
        )
        func coldReviewIntakeAdmitsNilOrCurrentStreamAndRejectsStaleStream(reason: String) async throws {
            let droppedIntake = BootstrapReviewIntakeTelemetryRecorder()
            let nilStream = try await makeBootstrapColdReviewIntakeFixture()
            let currentStream = try await makeBootstrapColdReviewIntakeFixture()
            let staleStream = try await makeBootstrapColdReviewIntakeFixture(telemetryRecorder: droppedIntake)
            let fixtures = [nilStream, currentStream, staleStream]
            defer {
                for fixture in fixtures {
                    // fire-and-forget: defer cannot await; cleanup only
                    _ = fixture.controller.beginTeardown()
                }
            }
            // G2's accepted Review mode starts the one initial build before intake.
            for fixture in fixtures {
                await sendPageActiveViewerMode(
                    .review, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 1
                )
                await fixture.controller.activeReviewRefreshTask?.value
                #expect(await fixture.sourceProvider.recordedComparisonRequestsCount() == 1)
            }
            let stalePackage = try #require(staleStream.controller.paneState.diff.packageMetadata)
            await nilStream.controller.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(reason: reason, streamId: nil),
                productAdmission: nilStream.productAdmission
            )
            await currentStream.controller.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(
                    reason: reason, streamId: currentStream.controller.reviewProtocolStreamId()
                ), productAdmission: currentStream.productAdmission
            )
            await staleStream.controller.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(reason: reason, streamId: "review:stale-stream"),
                productAdmission: staleStream.productAdmission
            )
            let staleIntakeWasDropped = try await droppedIntake.waitForDroppedIntake()
            #expect(staleIntakeWasDropped)
            #expect(staleStream.controller.activeReviewRefreshTask == nil)
            #expect(await staleStream.sourceProvider.recordedComparisonRequestsCount() == 1)
            #expect(staleStream.controller.paneState.diff.packageMetadata == stalePackage)
            await nilStream.controller.activeReviewRefreshTask?.value
            await currentStream.controller.activeReviewRefreshTask?.value
            #expect(nilStream.controller.paneState.diff.status == .ready)
            #expect(nilStream.controller.paneState.diff.packageMetadata != nil)
            #expect(currentStream.controller.paneState.diff.status == .ready)
            #expect(currentStream.controller.paneState.diff.packageMetadata != nil)
            for fixture in fixtures { #expect(await fixture.controller.beginTeardown().value) }
            try await droppedIntake.finish()
        }
    }
}

private actor BridgeProductBootstrapDeliverySuspension {
    private var deliveryIsSuspended = false
    private var deliverySuspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var deliveryResumeContinuation: CheckedContinuation<Void, Never>?

    func suspendDelivery() async {
        deliveryIsSuspended = true
        let waiters = deliverySuspendedWaiters
        deliverySuspendedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            deliveryResumeContinuation = continuation
        }
    }

    func waitUntilDeliveryIsSuspended() async {
        guard !deliveryIsSuspended else { return }
        await withCheckedContinuation { continuation in
            deliverySuspendedWaiters.append(continuation)
        }
    }

    func resumeDelivery() {
        deliveryResumeContinuation?.resume()
        deliveryResumeContinuation = nil
    }
}

@MainActor
private func openBootstrapReviewReplaySubscription(
    controller: BridgePaneController,
    installation: BridgeProductSessionInstallation,
    productProvider: BridgePaneProductSchemeProvider
) async throws -> BootstrapReviewReplaySubscription {
    let productAdmission = try #require(controller.productAdmissionGate.acquire())
    let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
        installation.capabilityBytes
    )
    let controlDispatcher = BridgeProductSchemeControlDispatcher(
        session: installation.session,
        provider: productProvider,
        productAdmission: productAdmission
    )
    let workerOpenRequest = try bootstrapReviewWorkerOpenRequest(installation: installation)
    let workerOpenResponse = try await readAdmittedBridgeProductControlResponse(
        try await controlDispatcher.dispatch(
            exactRequestBytes: try bootstrapReviewControlRequestBytes(workerOpenRequest),
            presentedCapability: capabilityHeader
        ),
        installation: installation,
        capabilityHeader: capabilityHeader
    )
    guard case .workerSessionAccepted = workerOpenResponse else {
        throw BootstrapReviewReplayError.expectedWorkerSessionAccepted
    }

    let metadataRequest = try bootstrapReviewMetadataRequest(installation: installation)
    let registration = await installation.session.registerMetadataProducer(
        request: metadataRequest,
        productAdmission: productAdmission
    ) { lease in
        await productProvider.runMetadataProducer(
            request: metadataRequest,
            lease: lease,
            productAdmission: productAdmission,
            session: installation.session
        )
    }
    let metadataLease = try bridgeProductAcceptedLease(registration)
    let metadataOpeningFrame = try bootstrapReviewMetadataFrame(
        from: try #require(
            await consumeNextBridgeProductProducerFrame(
                for: metadataLease,
                from: installation.session,
                productAdmission: productAdmission
            )
        )
    )
    guard case .metadataStreamAccepted = metadataOpeningFrame else {
        throw BootstrapReviewReplayError.expectedMetadataStreamAccepted
    }

    let reviewOpenRequest = try bootstrapReviewSubscriptionOpenRequest(
        installation: installation
    )
    var metadataStreamIsReady = false
    for _ in 0..<1000 {
        if case .subscriptionOpenAccepted = await productProvider.response(for: reviewOpenRequest) {
            metadataStreamIsReady = true
            break
        }
        await Task.yield()
    }
    #expect(metadataStreamIsReady)
    let reviewOpenResponse = try await readAdmittedBridgeProductControlResponse(
        try await controlDispatcher.dispatch(
            exactRequestBytes: try bootstrapReviewControlRequestBytes(reviewOpenRequest),
            presentedCapability: capabilityHeader
        ),
        installation: installation,
        capabilityHeader: capabilityHeader
    )
    guard case .subscriptionOpenAccepted = reviewOpenResponse else {
        Issue.record("Expected Review open acceptance, received \(String(describing: reviewOpenResponse))")
        throw BootstrapReviewReplayError.expectedReviewSubscriptionAccepted
    }
    try await consumeBootstrapReviewSubscriptionAcceptance(
        metadataLease: metadataLease,
        installation: installation,
        productAdmission: productAdmission
    )
    try await admitBootstrapReviewViewScope(
        dispatcher: controlDispatcher, installation: installation, capabilityHeader: capabilityHeader
    )
    return BootstrapReviewReplaySubscription(
        lease: metadataLease,
        productAdmission: productAdmission
    )
}
