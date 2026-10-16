import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite("Bridge pane product active-viewer mode", .serialized)
    struct BridgePaneProductActiveViewerModeTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("committed File product mode accepts a worktree File source")
        func committedFileProductModeAcceptsWorktreeFileSource() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let activeSource = BridgeActiveViewerSource(
                protocolId: .worktreeFile,
                streamId: "product-file-stream",
                generation: 41
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-session",
                sequence: 1,
                mode: .file,
                activeSource: activeSource,
                productAdmission: productAdmission
            )

            let acceptedSignal = try #require(controller.activeViewerModeSignalState.acceptedSignal)
            #expect(acceptedSignal.mode == .file)
            #expect(acceptedSignal.activeSource == activeSource)
            #expect(acceptedSignal.sequenceFloor == 1)
        }

        @Test("background Review warm-up preserves File authority when no package exists")
        func backgroundReviewWarmupPreservesFileAuthorityWithoutPackage() async throws {
            // Arrange
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let activeSource = BridgeActiveViewerSource(
                protocolId: .worktreeFile,
                streamId: "product-file-stream",
                generation: 41
            )
            controller.activeViewerModeSignalState = BridgeActiveViewerModeSignalState(
                sessionId: "product-session",
                lastSequence: 1,
                acceptedSignal: BridgeActiveViewerModeAcceptedSignal(
                    mode: .file,
                    activeSource: activeSource,
                    sequenceFloor: 1
                )
            )

            // Act
            await controller.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(
                    reason: "background-warmup",
                    streamId: nil
                ),
                productAdmission: productAdmission
            )

            // Assert
            #expect(controller.activeViewerModeSignalState.sessionId == "product-session")
            #expect(controller.activeViewerModeSignalState.lastSequence == 1)
            #expect(controller.activeViewerModeSignalState.acceptedSignal?.mode == .file)
            #expect(controller.activeViewerModeSignalState.acceptedSignal?.activeSource == activeSource)
        }

        @Test("background Review warm-up preserves File authority when a package exists")
        func backgroundReviewWarmupPreservesFileAuthorityWithPackage() async throws {
            // Arrange
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let foregroundWorkAdmission = try #require(
                controller.refreshAdmissionCoordinator.acquireForegroundWork()
            )
            let reviewPackage = try productActiveViewerReviewPackageFixture()
            controller.nextReviewGeneration = reviewPackage.reviewGeneration
            #expect(
                await controller.commitReviewPackageLoad(
                    try await productActiveViewerPreparedLoad(package: reviewPackage, delta: nil),
                    expectedReviewGeneration: reviewPackage.reviewGeneration,
                    productAdmission: productAdmission,
                    traceContext: nil,
                    foregroundWorkAdmission: foregroundWorkAdmission
                ) == .committed(delivery: .deferred)
            )
            let activeSource = BridgeActiveViewerSource(
                protocolId: .worktreeFile,
                streamId: "product-file-stream",
                generation: 41
            )
            controller.activeViewerModeSignalState = BridgeActiveViewerModeSignalState(
                sessionId: "product-session",
                lastSequence: 1,
                acceptedSignal: BridgeActiveViewerModeAcceptedSignal(
                    mode: .file,
                    activeSource: activeSource,
                    sequenceFloor: 1
                )
            )

            // Act
            await controller.handleCommittedProductReviewIntakeReady(
                BridgeProductReviewIntakeReadyRequest(
                    reason: "background-warmup",
                    streamId: nil
                ),
                productAdmission: productAdmission
            )

            // Assert
            #expect(controller.activeViewerModeSignalState.sessionId == "product-session")
            #expect(controller.activeViewerModeSignalState.lastSequence == 1)
            #expect(controller.activeViewerModeSignalState.acceptedSignal?.mode == .file)
            #expect(controller.activeViewerModeSignalState.acceptedSignal?.activeSource == activeSource)
        }

        @Test("closed pane admission suppresses a committed active-viewer mutation")
        func closedPaneAdmissionSuppressesCommittedActiveViewerMutation() async throws {
            // Arrange
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            controller.productAdmissionGate.close()

            // Act
            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "closed-product-session",
                sequence: 1,
                mode: .file,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .worktreeFile,
                    streamId: "closed-file-stream",
                    generation: 1
                ),
                productAdmission: productAdmission
            )

            // Assert
            #expect(controller.activeViewerModeSignalState.sessionId == nil)
            #expect(controller.activeViewerModeSignalState.lastSequence == nil)
            #expect(controller.activeViewerModeSignalState.acceptedSignal == nil)
        }

        @Test("committed Review product mode accepts the current stream and generation")
        func committedReviewProductModeAcceptsCurrentStreamAndGeneration() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let foregroundWorkAdmission = try #require(
                controller.refreshAdmissionCoordinator.acquireForegroundWork()
            )
            let reviewPackage = try productActiveViewerReviewPackageFixture()
            controller.nextReviewGeneration = reviewPackage.reviewGeneration
            #expect(
                await controller.commitReviewPackageLoad(
                    try await productActiveViewerPreparedLoad(package: reviewPackage, delta: nil),
                    expectedReviewGeneration: reviewPackage.reviewGeneration,
                    productAdmission: productAdmission,
                    traceContext: nil,
                    foregroundWorkAdmission: foregroundWorkAdmission
                ) == .committed(delivery: .deferred)
            )
            let activeSource = BridgeActiveViewerSource(
                protocolId: .review,
                streamId: controller.reviewProtocolStreamId(),
                generation: reviewPackage.reviewGeneration.rawValue
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-review-session",
                sequence: 1,
                mode: .review,
                activeSource: activeSource,
                productAdmission: productAdmission
            )

            let acceptedSignal = try #require(controller.activeViewerModeSignalState.acceptedSignal)
            #expect(acceptedSignal.mode == .review)
            #expect(acceptedSignal.activeSource == activeSource)
            #expect(acceptedSignal.sequenceFloor == 1)
        }

        @Test("successor Review source commit invalidates an impossible retained exact target")
        func successorReviewSourceCommitInvalidatesImpossibleRetainedExactTarget() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let foregroundWorkAdmission = try #require(
                controller.refreshAdmissionCoordinator.acquireForegroundWork()
            )
            let initialPackage = try productActiveViewerReviewPackageFixture()
            controller.nextReviewGeneration = initialPackage.reviewGeneration
            #expect(
                await controller.commitReviewPackageLoad(
                    try await productActiveViewerPreparedLoad(package: initialPackage, delta: nil),
                    expectedReviewGeneration: initialPackage.reviewGeneration,
                    productAdmission: productAdmission,
                    traceContext: nil,
                    foregroundWorkAdmission: foregroundWorkAdmission
                ) == .committed(delivery: .deferred)
            )
            _ = try controller.surfaceSelectionAuthority.retainReviewTarget(
                source: BridgeProductNavigationReviewSource(
                    generation: initialPackage.reviewGeneration.rawValue,
                    metadataSourceId: initialPackage.query.queryId,
                    packageId: initialPackage.packageId
                ),
                target: BridgeProductNavigationReviewTarget(
                    reviewItemId: initialPackage.orderedItemIds.first
                )
            )
            #expect(controller.surfaceSelectionAuthority.diagnosticSnapshot.desiredSurface == .review)
            let successorPackage = productActiveViewerSuccessorReviewPackage(from: initialPackage)
            controller.nextReviewGeneration = successorPackage.reviewGeneration

            #expect(
                await controller.commitReviewPackageLoad(
                    try await productActiveViewerPreparedLoad(package: successorPackage, delta: nil),
                    expectedReviewGeneration: successorPackage.reviewGeneration,
                    productAdmission: productAdmission,
                    traceContext: nil,
                    foregroundWorkAdmission: foregroundWorkAdmission
                ) == .committed(delivery: .deferred)
            )

            #expect(controller.surfaceSelectionAuthority.diagnosticSnapshot.desiredSurface == nil)
        }

        @Test("committed Review product mode rejects a stale generation")
        func committedReviewProductModeRejectsStaleGeneration() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let foregroundWorkAdmission = try #require(
                controller.refreshAdmissionCoordinator.acquireForegroundWork()
            )
            let reviewPackage = try productActiveViewerReviewPackageFixture()
            controller.nextReviewGeneration = reviewPackage.reviewGeneration
            #expect(
                await controller.commitReviewPackageLoad(
                    try await productActiveViewerPreparedLoad(package: reviewPackage, delta: nil),
                    expectedReviewGeneration: reviewPackage.reviewGeneration,
                    productAdmission: productAdmission,
                    traceContext: nil,
                    foregroundWorkAdmission: foregroundWorkAdmission
                ) == .committed(delivery: .deferred)
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-review-session",
                sequence: 1,
                mode: .review,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .review,
                    streamId: controller.reviewProtocolStreamId(),
                    generation: reviewPackage.reviewGeneration.rawValue + 1
                ),
                productAdmission: productAdmission
            )

            #expect(controller.activeViewerModeSignalState.lastSequence == 1)
            #expect(controller.activeViewerModeSignalState.acceptedSignal == nil)
        }

        @Test("committed Review product mode rejects a mismatched stream")
        func committedReviewProductModeRejectsMismatchedStream() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let foregroundWorkAdmission = try #require(
                controller.refreshAdmissionCoordinator.acquireForegroundWork()
            )
            let reviewPackage = try productActiveViewerReviewPackageFixture()
            controller.nextReviewGeneration = reviewPackage.reviewGeneration
            #expect(
                await controller.commitReviewPackageLoad(
                    try await productActiveViewerPreparedLoad(package: reviewPackage, delta: nil),
                    expectedReviewGeneration: reviewPackage.reviewGeneration,
                    productAdmission: productAdmission,
                    traceContext: nil,
                    foregroundWorkAdmission: foregroundWorkAdmission
                ) == .committed(delivery: .deferred)
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-review-session",
                sequence: 1,
                mode: .review,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .review,
                    streamId: "stale-review-stream",
                    generation: reviewPackage.reviewGeneration.rawValue
                ),
                productAdmission: productAdmission
            )

            #expect(controller.activeViewerModeSignalState.lastSequence == 1)
            #expect(controller.activeViewerModeSignalState.acceptedSignal == nil)
        }

        @Test("Review package state is installed before product ready publication")
        func reviewPackageStateIsInstalledBeforeProductReadyPublication() async throws {
            // Arrange
            let harness = ProductActiveViewerReviewPublicationHarness.make()
            defer { _ = harness.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let openedSubscription = try await harness.openReviewMetadataSubscription()

            let reviewPackage = try productActiveViewerReviewPackageFixture()
            let reviewDelta = BridgeReviewDelta(
                packageId: reviewPackage.packageId,
                reviewGeneration: reviewPackage.reviewGeneration,
                revision: reviewPackage.revision + 1,
                operations: BridgeReviewDelta.Operations()
            )

            // Act
            let load = try await productActiveViewerPreparedLoad(
                package: reviewPackage,
                delta: reviewDelta
            )
            harness.controller.nextReviewGeneration = reviewPackage.reviewGeneration
            let commitDisposition = await harness.controller.commitReviewPackageLoad(
                load,
                expectedReviewGeneration: load.package.reviewGeneration,
                productAdmission: openedSubscription.productAdmission,
                traceContext: nil,
                foregroundWorkAdmission: openedSubscription.foregroundWorkAdmission
            )
            let observations = await harness.reviewMetadataRecorder.observations

            // Assert
            #expect(commitDisposition == .committed(delivery: .deferred))
            let observation = try #require(observations.last)
            #expect(observations.count == 1)
            #expect(observation.deliveredPackage == load.package)
            #expect(observation.packageMetadata == load.package)
            #expect(observation.packageDelta == reviewDelta)
            #expect(observation.status == .ready)
            try await closeBridgeProductSessionProducer(
                openedSubscription.metadataLease,
                in: harness.installation.session
            )
            #expect((await harness.installation.session.producerSnapshot()).hasZeroResidue)
        }

        @Test("closed admission rejects Review package state publication")
        func closedAdmissionRejectsReviewPackageStatePublication() async throws {
            // Arrange
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let reviewPackage = try productActiveViewerReviewPackageFixture()
            let reviewDelta = BridgeReviewDelta(
                packageId: reviewPackage.packageId,
                reviewGeneration: reviewPackage.reviewGeneration,
                revision: reviewPackage.revision + 1,
                operations: BridgeReviewDelta.Operations()
            )
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let foregroundWorkAdmission = try #require(
                controller.refreshAdmissionCoordinator.acquireForegroundWork()
            )
            controller.productAdmissionGate.close()
            controller.nextReviewGeneration = reviewPackage.reviewGeneration

            // Act
            let commitDisposition = await controller.commitReviewPackageLoad(
                try await productActiveViewerPreparedLoad(
                    package: reviewPackage,
                    delta: reviewDelta
                ),
                expectedReviewGeneration: reviewPackage.reviewGeneration,
                productAdmission: productAdmission,
                traceContext: nil,
                foregroundWorkAdmission: foregroundWorkAdmission
            )

            // Assert
            #expect(commitDisposition == .rejected)
            #expect(controller.paneState.diff.packageMetadata == nil)
            #expect(controller.paneState.diff.packageDelta == nil)
            #expect(controller.paneState.diff.status == .idle)
        }

        @Test("replayed committed File hint cannot replace the accepted sequence")
        func replayedCommittedFileHintIsIgnored() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let acceptedSource = BridgeActiveViewerSource(
                protocolId: .worktreeFile,
                streamId: "accepted-file-stream",
                generation: 7
            )
            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-session",
                sequence: 2,
                mode: .file,
                activeSource: acceptedSource,
                productAdmission: productAdmission
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-session",
                sequence: 2,
                mode: .file,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .worktreeFile,
                    streamId: "replayed-file-stream",
                    generation: 8
                ),
                productAdmission: productAdmission
            )

            #expect(controller.activeViewerModeSignalState.lastSequence == 2)
            #expect(controller.activeViewerModeSignalState.acceptedSignal?.activeSource == acceptedSource)
        }

        @Test("new product session accepts a lower sequence")
        func newProductSessionAcceptsLowerSequence() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "first-product-session",
                sequence: 9,
                mode: .file,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .worktreeFile,
                    streamId: "first-file-stream",
                    generation: 1
                ),
                productAdmission: productAdmission
            )
            let replacementSource = BridgeActiveViewerSource(
                protocolId: .worktreeFile,
                streamId: "replacement-file-stream",
                generation: 2
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "replacement-product-session",
                sequence: 1,
                mode: .file,
                activeSource: replacementSource,
                productAdmission: productAdmission
            )

            #expect(controller.activeViewerModeSignalState.sessionId == "replacement-product-session")
            #expect(controller.activeViewerModeSignalState.lastSequence == 1)
            #expect(controller.activeViewerModeSignalState.acceptedSignal?.activeSource == replacementSource)
        }

        @Test("mismatched product File source fails open")
        func mismatchedProductFileSourceFailsOpen() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-session",
                sequence: 1,
                mode: .file,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .review,
                    streamId: "review-stream",
                    generation: 1
                ),
                productAdmission: productAdmission
            )

            #expect(controller.activeViewerModeSignalState.acceptedSignal == nil)
        }

        @Test("accepted active-viewer sequence admits the exact native surface receipt")
        func acceptedSequenceAdmitsExactNativeSurfaceReceipt() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let bootstrap = try #require(await controller.productSessionOwner.activeBootstrap())
            controller.surfaceSelectionAuthority.retainIntent(surface: .file)
            let requestCandidate = try controller.surfaceSelectionAuthority.rebindRetainedIntent(
                paneSessionId: bootstrap.paneSessionId,
                workerInstanceId: bootstrap.workerInstanceId
            )
            let request = try #require(requestCandidate)
            let correlation = try BridgeProductControlCorrelation(
                paneSessionId: bootstrap.paneSessionId,
                requestId: "active-viewer-native-receipt",
                requestSequence: 1,
                workerInstanceId: bootstrap.workerInstanceId
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-session",
                sequence: 1,
                mode: .file,
                activeSource: nil,
                productAdmission: productAdmission,
                nativeSelectionRequestId: request.requestId,
                productCorrelation: correlation
            )

            #expect(
                controller.surfaceSelectionAuthority.admitReceipt(
                    nativeSelectionRequestId: request.requestId,
                    mode: .file,
                    paneSessionId: bootstrap.paneSessionId,
                    workerInstanceId: bootstrap.workerInstanceId
                ) == .idempotentReplay
            )
        }

        @Test("stale active-viewer sequence cannot consume a native surface receipt")
        func staleSequenceCannotConsumeNativeSurfaceReceipt() async throws {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let bootstrap = try #require(await controller.productSessionOwner.activeBootstrap())
            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-session",
                sequence: 2,
                mode: .file,
                activeSource: nil,
                productAdmission: productAdmission
            )
            controller.surfaceSelectionAuthority.retainIntent(surface: .review)
            let requestCandidate = try controller.surfaceSelectionAuthority.rebindRetainedIntent(
                paneSessionId: bootstrap.paneSessionId,
                workerInstanceId: bootstrap.workerInstanceId
            )
            let request = try #require(requestCandidate)
            let correlation = try BridgeProductControlCorrelation(
                paneSessionId: bootstrap.paneSessionId,
                requestId: "stale-active-viewer-native-receipt",
                requestSequence: 2,
                workerInstanceId: bootstrap.workerInstanceId
            )

            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "product-session",
                sequence: 1,
                mode: .review,
                activeSource: nil,
                productAdmission: productAdmission,
                nativeSelectionRequestId: request.requestId,
                productCorrelation: correlation
            )

            #expect(
                controller.surfaceSelectionAuthority.admitReceipt(
                    nativeSelectionRequestId: request.requestId,
                    mode: .review,
                    paneSessionId: bootstrap.paneSessionId,
                    workerInstanceId: bootstrap.workerInstanceId
                ) == .accepted
            )
        }

        private func makeController() -> BridgePaneController {
            BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .fileViewer,
                    source: .workspace(
                        rootPath: "/tmp/product-file-viewer",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground
            )
        }

    }
}

private enum ProductActiveViewerReviewPublicationHarnessError: Error {
    case reviewSubscriptionRejected
    case workerSessionRejected
}

@MainActor
private struct ProductActiveViewerReviewPublicationHarness {
    struct OpenedSubscription {
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let metadataLease: BridgeProductProducerLease
        let productAdmission: BridgeProductAdmissionContext
    }

    let controller: BridgePaneController
    let installation: BridgeProductSessionInstallation
    let productAdmissionGate: BridgeProductAdmissionGate
    let productProvider: BridgePaneProductSchemeProvider
    let reviewMetadataRecorder: ProductActiveViewerReviewMetadataRecorder

    static func make() -> Self {
        let controllerBox = ProductActiveViewerControllerBox()
        let reviewMetadataRecorder = ProductActiveViewerReviewMetadataRecorder(
            controllerBox: controllerBox
        )
        let refreshWorkAdmission = BridgePaneRefreshWorkAdmissionTestContext.foregroundOnMainActor()
        let productProvider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: reviewMetadataRecorder,
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let paneId = UUIDv7.generate()
        let productAdmissionGate = BridgeProductAdmissionGate()
        let installation = BridgePaneController.makeInitialProductSessionInstallation(
            paneSessionId: paneId.uuidString,
            provider: productProvider,
            productAdmissionGate: productAdmissionGate
        )
        let owner = BridgePaneController.makeProductSessionOwner(
            paneSessionId: paneId.uuidString,
            provider: productProvider,
            productAdmissionGate: productAdmissionGate,
            activeInstallation: installation
        )
        let controller = BridgePaneController(
            paneId: paneId,
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .commit(sha: "product-ready-ordering")
            ),
            appRootURL: testBridgeAppRootURL(),
            initialPaneActivity: .foreground,
            productSessionDependencies: BridgePaneProductSessionDependencies(
                installation: installation,
                owner: owner,
                productProvider: productProvider
            )
        )
        controllerBox.controller = controller
        return Self(
            controller: controller,
            installation: installation,
            productAdmissionGate: productAdmissionGate,
            productProvider: productProvider,
            reviewMetadataRecorder: reviewMetadataRecorder
        )
    }

    func openReviewMetadataSubscription() async throws -> OpenedSubscription {
        let productAdmission = try #require(productAdmissionGate.acquire())
        let controlDispatcher = BridgeProductSchemeControlDispatcher(
            session: installation.session,
            provider: productProvider,
            productAdmission: productAdmission
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )
        let workerOpenRequest = try productActiveViewerWorkerOpenRequest(
            installation: installation
        )
        let workerOpenResponse = try await readAdmittedBridgeProductControlResponse(
            try await controlDispatcher.dispatch(
                exactRequestBytes: try productActiveViewerControlRequestBytes(workerOpenRequest),
                presentedCapability: capabilityHeader
            ),
            installation: installation,
            capabilityHeader: capabilityHeader
        )
        guard case .workerSessionAccepted = workerOpenResponse else {
            throw ProductActiveViewerReviewPublicationHarnessError.workerSessionRejected
        }
        let metadataRequest = try productActiveViewerMetadataRequest(
            installation: installation
        )
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
        #expect(
            await consumeNextBridgeProductProducerFrame(
                for: metadataLease,
                from: installation.session,
                productAdmission: productAdmission
            )?.sequence == 0
        )
        let reviewOpenRequest = try productActiveViewerReviewOpenRequest(
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
                exactRequestBytes: try productActiveViewerControlRequestBytes(reviewOpenRequest),
                presentedCapability: capabilityHeader
            ),
            installation: installation,
            capabilityHeader: capabilityHeader
        )
        guard case .subscriptionOpenAccepted = reviewOpenResponse else {
            throw ProductActiveViewerReviewPublicationHarnessError.reviewSubscriptionRejected
        }
        return OpenedSubscription(
            foregroundWorkAdmission: try #require(
                controller.refreshAdmissionCoordinator.acquireForegroundWork()
            ),
            metadataLease: metadataLease,
            productAdmission: productAdmission
        )
    }
}

private struct ProductActiveViewerReviewPublicationObservation: Equatable, Sendable {
    let deliveredPackage: BridgeReviewPackage
    let packageMetadata: BridgeReviewPackage?
    let packageDelta: BridgeReviewDelta?
    let status: DiffStatus
}

@MainActor
private final class ProductActiveViewerControllerBox {
    weak var controller: BridgePaneController?

    func observation(
        deliveredPackage: BridgeReviewPackage
    ) -> ProductActiveViewerReviewPublicationObservation? {
        guard let controller else { return nil }
        return ProductActiveViewerReviewPublicationObservation(
            deliveredPackage: deliveredPackage,
            packageMetadata: controller.paneState.diff.packageMetadata,
            packageDelta: controller.paneState.diff.packageDelta,
            status: controller.paneState.diff.status
        )
    }
}

private enum ProductActiveViewerReviewMetadataRecorderError: Error {
    case controllerUnavailable
}

private actor ProductActiveViewerReviewMetadataRecorder:
    BridgePaneProductReviewMetadataProducing
{
    private let controllerBox: ProductActiveViewerControllerBox
    private(set) var observations: [ProductActiveViewerReviewPublicationObservation] = []

    init(controllerBox: ProductActiveViewerControllerBox) {
        self.controllerBox = controllerBox
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {}

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        BridgeReviewMetadataPublicationReservation(
            reservationId: UUIDv7.generate(),
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
        publication: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        guard let observation = await controllerBox.observation(deliveredPackage: publication.package) else {
            throw ProductActiveViewerReviewMetadataRecorderError.controllerUnavailable
        }
        return productAdmission.withValidAdmission {
            observations.append(observation)
            return .deferred(retained: 0)
        } ?? .deferred(retained: 0)
    }

    func cancel(subscriptionId _: String) {}
}

private func productActiveViewerPreparedLoad(
    package: BridgeReviewPackage,
    delta: BridgeReviewDelta?
) async throws -> BridgeReviewPackageLoadData {
    let preparedPackage = package.withRevision(delta?.revision ?? package.revision)
    let contentHandles = preparedPackage.itemsById.values.flatMap(\.contentRoles.allHandles)
    let preparedPublication = try #require(
        await BridgeReviewPreparedPublication.prepare(
            BridgeReviewPublicationCandidate(
                package: preparedPackage,
                delta: delta,
                contentHandles: contentHandles
            )
        )
    )
    return BridgeReviewPackageLoadData(
        preparedPublication: preparedPublication,
        changeIndexLoad: BridgeChangeIndexPreparedLoad(
            package: preparedPackage,
            delta: delta
        )
    )
}

private func productActiveViewerWorkerOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try productActiveViewerControlRequest([
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "request-open-product-ready-ordering",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func productActiveViewerReviewOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try productActiveViewerControlRequest([
        "kind": "subscription.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-review-open-product-ready-ordering",
        "requestSequence": 2,
        "subscription": ["subscriptionKind": "review.metadata"],
        "subscriptionId": "review-subscription-product-ready-ordering",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func productActiveViewerMetadataRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-product-ready-ordering",
            "paneSessionId": installation.bootstrap.paneSessionId,
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: data
    )
}

private func productActiveViewerControlRequest(
    _ object: [String: Any]
) throws -> BridgeProductControlRequest {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: data)
}

private func productActiveViewerControlRequestBytes(
    _ request: BridgeProductControlRequest
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(request)
}

private func productActiveViewerReviewPackageFixture() throws -> BridgeReviewPackage {
    let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
    let fixtureURL = projectRoot.appending(
        path: "Tests/BridgeContractFixtures/valid/bridge-review-package.json"
    )
    let decoded = try JSONDecoder().decode(
        BridgeReviewPackage.self,
        from: Data(contentsOf: fixtureURL)
    )
    let orderedItemsById = try Dictionary(
        uniqueKeysWithValues: decoded.orderedItemIds.map { itemId in
            (itemId, try #require(decoded.itemsById[itemId]))
        }
    )
    return BridgeReviewPackage(
        packageId: decoded.packageId,
        schemaVersion: decoded.schemaVersion,
        reviewGeneration: decoded.reviewGeneration,
        revision: decoded.revision,
        query: decoded.query,
        baseEndpoint: decoded.baseEndpoint,
        headEndpoint: decoded.headEndpoint,
        orderedItemIds: decoded.orderedItemIds,
        itemsById: orderedItemsById,
        groups: decoded.groups,
        summary: decoded.summary,
        filterState: decoded.filterState,
        generatedAtUnixMilliseconds: decoded.generatedAtUnixMilliseconds,
        changesetCluster: decoded.changesetCluster
    )
}
