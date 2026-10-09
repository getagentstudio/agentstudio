import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import WebKit
import os.log

private let bridgeProductBootstrapLogger = Logger(
    subsystem: "com.agentstudio",
    category: "BridgeProductBootstrap"
)

package typealias BridgeProductSessionBootstrapSink =
    @MainActor (
        _ page: WebPage,
        _ requestId: String,
        _ installation: BridgeProductSessionInstallation,
        _ contentWorld: WKContentWorld,
        _ productAdmission: BridgeProductAdmissionContext
    ) async throws -> Void

package typealias BridgeTelemetrySessionBootstrapSink =
    @MainActor (
        _ page: WebPage,
        _ requestId: String,
        _ installation: BridgeTelemetrySessionInstallation?,
        _ contentWorld: WKContentWorld
    ) async throws -> Void

struct BridgeProductSessionDependencyInput {
    let paneSessionId: String
    let runtime: BridgeRuntime
    let state: BridgePaneState
    let gitReadContext: BridgeGitReadContext?
    let worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator?
    let worktreeAnnotationStore: WorktreeAnnotationServiceActor?
    let worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor?
    let gitWorkingTreeStatusProvider: (any GitWorkingTreeStatusProvider)?
    let reviewContentLoaderCache: BridgeReviewContentLoaderCache
    let reviewPublicationCoordinator: BridgeReviewPublicationCoordinator
    let refreshWorkAdmissionSource: BridgePaneRefreshWorkAdmissionSource
    let recordCurrentFileRefreshFailure: @MainActor @Sendable (BridgeFileSurfaceOutcomeApplication) async -> Void
    let initialProductPresentation: BridgePaneProductPresentationSnapshot
    let telemetryRecorder: (any BridgePerformanceTraceRecording)?
    let reviewSourceProvider: any BridgeReviewSourceProvider
    let reviewComparisonTargetProjection: BridgeReviewComparisonTargetProjection
}

@MainActor
final class BridgePaneProductCommittedCallTarget {
    private let productAdmissionGate: BridgeProductAdmissionGate
    weak var controller: BridgePaneController?

    init(productAdmissionGate: BridgeProductAdmissionGate) {
        self.productAdmissionGate = productAdmissionGate
    }

    func applyActiveViewerModeUpdate(
        _ call: BridgeProductCallRequest,
        correlation: BridgeProductControlCorrelation,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        let mode: BridgeActiveViewerMode
        let sourceProtocol: BridgeActiveViewerSourceProtocol
        let update: BridgeProductActiveViewerModeUpdateRequest
        switch call {
        case .fileAnnotationsCommand, .fileAnnotationsOutputInspect,
            .fileAnnotationsProjectionQuery,
            .reviewAnnotationsCommand, .reviewAnnotationsOutputInspect,
            .reviewAnnotationsProjectionQuery,
            .fileSourceCurrent, .fileRefreshRetry:
            return
        case .fileActiveViewerModeUpdate(let request):
            mode = .file
            sourceProtocol = .worktreeFile
            update = request
        case .reviewActiveViewerModeUpdate(let request):
            mode = .review
            sourceProtocol = .review
            update = request
        case .reviewComparisonUpdate, .reviewIntakeReady, .reviewMarkFileViewed,
            .reviewPublicationInstallAdmission, .reviewPublicationApplied,
            .reviewComparisonTargetsQuery:
            return
        }
        let activeSource = update.activeSource.map {
            BridgeActiveViewerSource(
                protocolId: sourceProtocol,
                streamId: $0.streamId,
                generation: $0.generation
            )
        }
        await controller?.handleCommittedProductActiveViewerModeUpdate(
            sessionId: update.sessionId,
            sequence: update.sequence,
            mode: mode,
            activeSource: activeSource,
            productAdmission: productAdmission,
            nativeSelectionRequestId: update.nativeSelectionRequestId,
            productCorrelation: correlation
        )
    }

    func applyFileRefreshRetry(productAdmission: BridgeProductAdmissionContext) async {
        guard (productAdmission.withValidAdmission { true }) == true else { return }
        await controller?.worktreeRefreshDriver.retryUnavailableFileRefreshAndWait(
            ifAdmittedBy: productAdmission
        )
    }

    func applyReviewIntakeReady(
        _ request: BridgeProductReviewIntakeReadyRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        await controller?.handleCommittedProductReviewIntakeReady(
            request,
            productAdmission: productAdmission
        )
    }

    func applyReviewComparisonUpdate(
        _ request: BridgeProductReviewComparisonUpdateRequest,
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        guard productAdmission.withValidAdmission({ true }) == true else { return }
        guard let controller else {
            return
        }
        _ = await controller.handleCommittedProductReviewComparisonUpdate(
            request,
            workerDerivationEpoch: workerDerivationEpoch,
            productAdmission: productAdmission
        )
    }
}

private enum CommittedReviewIntakeSchedulingDecision {
    case initialPackageLoad
    case productResync
    case replayCommittedPublication
}

@MainActor
extension BridgePaneController {
    static func registerReadyMessageHandler(
        in userContentController: WKUserContentController,
        contentWorld: WKContentWorld
    ) -> BridgeReadyMessageHandler {
        let readyMessageHandler = BridgeReadyMessageHandler()
        userContentController.add(
            readyMessageHandler,
            contentWorld: contentWorld,
            name: "rpc"
        )
        return readyMessageHandler
    }

    func handleCommittedProductReviewIntakeReady(
        _ request: BridgeProductReviewIntakeReadyRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        let currentStreamId = reviewProtocolStreamId()
        guard request.streamId == nil || request.streamId == currentStreamId else {
            await recordReviewIntakeReadyTelemetry(phase: "dropped")
            return
        }
        await recordReviewIntakeReadyTelemetry(phase: "accepted")
        if request.reason == "background-warmup" {
            guard
                productAdmission.withValidAdmission({ paneState.diff.packageMetadata == nil }) == true
            else { return }
            scheduleInitialReviewPackageLoadIfPossible(reason: .initialIntake)
            return
        }
        var schedulingDecision: CommittedReviewIntakeSchedulingDecision?
        guard
            productAdmission.withValidAdmission({
                let package = paneState.diff.packageMetadata
                if package == nil {
                    if request.reason == "sequence_gap" {
                        schedulingDecision = .initialPackageLoad
                    }
                    return
                }
                if request.reason == "sequence_gap" {
                    schedulingDecision = .productResync
                    return
                }
                schedulingDecision = .replayCommittedPublication
            }) != nil,
            let schedulingDecision
        else {
            return
        }

        switch schedulingDecision {
        case .initialPackageLoad:
            scheduleInitialReviewPackageLoadIfPossible(reason: .initialIntake)
        case .productResync:
            scheduleReviewPackageReloadForProductResync(reason: .productResync)
        case .replayCommittedPublication:
            let productSchemeProvider = productSchemeProvider
            Task { [productSchemeProvider] in
                await productSchemeProvider?.replayCommittedReviewPublicationIfPresent(
                    productAdmission: productAdmission
                )
            }
        }
    }
}

@MainActor
extension BridgePaneController {
    func enqueueTelemetrySessionBootstrapRequest(
        requestId: String,
        reason: BridgeReadyMessageHandler.TelemetrySessionBootstrapReason
    ) async {
        let precedingTransition = telemetrySessionBootstrapTransitionTail
        let transition = Task { @MainActor [weak self] in
            if let precedingTransition {
                await precedingTransition.value
            }
            await self?.performTelemetrySessionBootstrapRequest(
                requestId: requestId,
                reason: reason
            )
        }
        telemetrySessionBootstrapTransitionTail = transition
        await transition.value
    }

    private func performTelemetrySessionBootstrapRequest(
        requestId: String,
        reason _: BridgeReadyMessageHandler.TelemetrySessionBootstrapReason
    ) async {
        guard let telemetrySessionOwner, let telemetryRecorder else {
            try? await telemetrySessionBootstrapSink(page, requestId, nil, bridgeWorld)
            return
        }

        let installation: BridgeTelemetrySessionInstallation
        if hasPublishedTelemetrySessionBootstrap {
            do {
                installation = try await telemetrySessionOwner.replace(
                    enabledScopes: [.web],
                    endpointURL: "agentstudio://telemetry/batch",
                    policy: .live,
                    projector: BridgeTelemetryNativeProjector(recorder: telemetryRecorder).project
                )
            } catch {
                try? await telemetrySessionBootstrapSink(page, requestId, nil, bridgeWorld)
                return
            }
        } else {
            installation = await telemetrySessionOwner.installation
        }

        hasPublishedTelemetrySessionBootstrap = true
        do {
            try await telemetrySessionBootstrapSink(
                page,
                requestId,
                installation,
                bridgeWorld
            )
        } catch {
            await telemetrySessionOwner.invalidateActiveSession()
        }
    }

    static func dispatchTelemetrySessionBootstrap(
        page: WebPage,
        requestId: String,
        installation: BridgeTelemetrySessionInstallation?,
        contentWorld: WKContentWorld
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bootstrapJSON: String
        if let installation {
            let data = try encoder.encode(installation.bootstrap)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw BridgeError.encoding("Unable to encode telemetry session bootstrap")
            }
            bootstrapJSON = encoded
        } else {
            bootstrapJSON = "null"
        }
        try await page.callJavaScript(
            """
            document.dispatchEvent(new CustomEvent('__bridge_telemetry_session_bootstrap', {
                detail: {
                    requestId: requestId,
                    result: bootstrapJSON === 'null'
                        ? { kind: 'unavailable', reason: 'disabled' }
                        : { kind: 'available', workerBootstrap: JSON.parse(bootstrapJSON) }
                }
            }));
            """,
            arguments: [
                "requestId": requestId,
                "bootstrapJSON": bootstrapJSON,
            ],
            contentWorld: contentWorld
        )
    }

    func enqueueProductSessionBootstrapRequest(
        requestId: String,
        reason: BridgeReadyMessageHandler.ProductSessionBootstrapReason,
        predecessor: BridgeProductInstallationFenceSnapshot? = nil
    ) async {
        guard let productAdmission = productAdmissionGate.acquire() else { return }
        latestProductSessionBootstrapRequestId = requestId
        let expected: BridgeProductInstallationFenceSnapshot?
        if let predecessor {
            expected = predecessor
        } else if hasPublishedProductSessionBootstrap {
            expected = productSessionOwner.closeActiveInstallation()
            retirePendingExplicitReviewCommand()
        } else {
            expected = nil
        }
        let precedingTransition = productSessionBootstrapTransitionTail
        let transition = Task { @MainActor [weak self] in
            if let precedingTransition {
                await precedingTransition.value
            }
            await self?.performProductSessionBootstrapRequest(
                requestId: requestId,
                reason: reason,
                productAdmission: productAdmission,
                predecessor: expected
            )
        }
        productSessionBootstrapTransitionTail = transition
        await transition.value
    }

    private func performProductSessionBootstrapRequest(
        requestId: String,
        reason: BridgeReadyMessageHandler.ProductSessionBootstrapReason,
        productAdmission: BridgeProductAdmissionContext,
        predecessor: BridgeProductInstallationFenceSnapshot?
    ) async {
        guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return }
        bridgeProductBootstrapLogger.debug(
            "Preparing product session bootstrap requestId=\(requestId, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        let installation: BridgeProductSessionInstallation
        if hasPublishedProductSessionBootstrap || predecessor != nil {
            guard
                let replacement = await activateReplacementProductSessionInstallation(
                    requestId: requestId,
                    reason: reason,
                    productAdmission: productAdmission,
                    predecessor: predecessor
                )
            else { return }
            installation = replacement
        } else {
            guard let activeInstallation = await productSessionOwner.activeInstallation else {
                setProductBootstrapConnectionErrorIfAdmitted(productAdmission, requestId: requestId)
                await answerProductSessionBootstrapFailure(
                    requestId: requestId,
                    reason: .noActiveSession,
                    productAdmission: productAdmission
                )
                return
            }
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return }
            installation = activeInstallation
        }

        guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission),
            let installationAdmission = installation.productAdapter.acquireAdmission(),
            (productAdmission.withValidAdmission {
                hasPublishedProductSessionBootstrap = true
                return true
            }) == true
        else { return }
        let surfaceSelectionSnapshot = surfaceSelectionAuthority.diagnosticSnapshot
        let surfaceSelectionReplay: Task<Bool, Never>?
        if let retainedCommandId = surfaceSelectionSnapshot.retainedCommandId,
            let productSchemeProvider
        {
            surfaceSelectionReplay = enqueueRetainedSurfaceSelectionReplay(
                commandId: retainedCommandId,
                productAdmission: installationAdmission,
                productSchemeProvider: productSchemeProvider,
                bootstrap: installation.bootstrap
            )
        } else {
            surfaceSelectionReplay = nil
        }
        do {
            let sink = productSessionBootstrapSink
            let replyPage = page
            let replyWorld = bridgeWorld
            try await deliverProductBootstrapReply(requestId: requestId, admission: installationAdmission) {
                try await sink(replyPage, requestId, installation, replyWorld, installationAdmission)
            }
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else {
                // The successor captured this projection as its predecessor. Its
                // replacement owner must perform retirement after that comparison.
                return
            }
            _ = await surfaceSelectionReplay?.value
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else {
                await retireProductBootstrapCandidateIfCurrent(installation)
                return
            }
            bridgeProductBootstrapLogger.debug(
                "Delivered product session bootstrap requestId=\(requestId, privacy: .public)"
            )
        } catch {
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return }
            let failedInstallation = productSessionOwner.installationFenceProjection.snapshot
            await retireProductBootstrapCandidateIfCurrent(installation)
            guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return }
            bridgeProductBootstrapLogger.error("Bridge product session bootstrap delivery failed: \(error)")
            // The undelivered capability must not stay live. A failed retirement stays
            // owned by the session owner and is retried by the page's next request.
            if failedInstallation.installation == installation.installationFence,
                productSessionOwner.installationFenceProjection.snapshot.installation == nil
            {
                setProductBootstrapConnectionErrorIfAdmitted(productAdmission, requestId: requestId)
            }
            await answerProductSessionBootstrapFailure(
                requestId: requestId,
                reason: .deliveryFailed,
                productAdmission: productAdmission
            )
        }
    }

    func setProductBootstrapConnectionErrorIfAdmitted(
        _ productAdmission: BridgeProductAdmissionContext,
        requestId: String,
        predecessor: BridgeProductInstallationFenceSnapshot? = nil
    ) {
        guard isCurrentProductBootstrapRequest(requestId, productAdmission: productAdmission) else { return }
        if let predecessor, productSessionOwner.installationFenceProjection.snapshot != predecessor { return }
        _ = productAdmission.withValidAdmission {
            paneState.connection.setHealth(.error)
        }
    }

    func isCurrentProductBootstrapRequest(
        _ requestId: String,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        latestProductSessionBootstrapRequestId == requestId
            && productAdmission.withValidAdmission { true } == true
    }

    func retireProductBootstrapCandidateIfCurrent(_ installation: BridgeProductSessionInstallation) async {
        installation.installationFence.close()
        let current = productSessionOwner.installationFenceProjection.snapshot
        guard current.installation == installation.installationFence else { return }
        _ = await productSessionOwner.retire(reason: .pageReload, installation: current)
    }

    static func dispatchProductSessionBootstrap(
        page: WebPage,
        requestId: String,
        installation: BridgeProductSessionInstallation,
        contentWorld: WKContentWorld,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bootstrapData = try encoder.encode(installation.bootstrap)
        let capabilityData = try encoder.encode(installation.capabilityBytes)
        guard let bootstrapJSON = String(data: bootstrapData, encoding: .utf8),
            let capabilityJSON = String(data: capabilityData, encoding: .utf8)
        else {
            throw BridgeError.encoding("Unable to encode product session bootstrap")
        }
        guard (productAdmission.withValidAdmission { true }) == true else {
            throw CancellationError()
        }
        try await page.callJavaScript(
            """
            document.dispatchEvent(new CustomEvent('__bridge_product_session_bootstrap', {
                detail: {
                    requestId: requestId,
                    bootstrap: JSON.parse(bootstrapJSON),
                    productCapability: new Uint8Array(JSON.parse(capabilityJSON)).buffer
                }
            }));
            """,
            arguments: [
                "requestId": requestId,
                "bootstrapJSON": bootstrapJSON,
                "capabilityJSON": capabilityJSON,
            ],
            contentWorld: contentWorld
        )
        guard (productAdmission.withValidAdmission { true }) == true else {
            throw CancellationError()
        }
    }

    func configureRuntimeCallbacks() {
        onRuntimeEvent = { [weak self] event, commandId, correlationId in
            self?.runtime.ingestBridgeEvent(event, commandId: commandId, correlationId: correlationId)
        }
        runtime.commandHandler = self
    }

    static func makeProductSessionDependencies(
        _ input: BridgeProductSessionDependencyInput
    ) -> BridgePaneProductSessionDependencies {
        let productAdmissionGate = BridgeProductAdmissionGate()
        let committedCallTarget = makeCommittedCallTarget(productAdmissionGate)
        let fileSourceComposition = makeFileSourceComposition(input)
        let fileMetadataSource = fileSourceComposition.source
        let provider = makeProductSchemeProvider(
            input,
            committedCallTarget: committedCallTarget,
            fileMetadataSource: fileMetadataSource
        )
        let installation = makeInitialProductSessionInstallation(
            paneSessionId: input.paneSessionId,
            provider: provider,
            productAdmissionGate: productAdmissionGate,
            telemetryRecorder: input.telemetryRecorder
        )
        return BridgePaneProductSessionDependencies(
            installation: installation,
            owner: makeProductSessionOwner(
                paneSessionId: input.paneSessionId,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                activeInstallation: installation,
                reviewPublicationCoordinator: input.reviewPublicationCoordinator,
                worktreeAnnotationStore: input.worktreeAnnotationStore,
                telemetryRecorder: input.telemetryRecorder
            ),
            committedCallTarget: committedCallTarget,
            fileSourceAcceptanceRelay: fileSourceComposition.acceptanceRelay,
            productProvider: provider
        )
    }

    private static func makeProductSchemeProvider(
        _ input: BridgeProductSessionDependencyInput,
        committedCallTarget: BridgePaneProductCommittedCallTarget,
        fileMetadataSource: any BridgePaneProductFileMetadataProducing
    ) -> BridgePaneProductSchemeProvider {
        let reviewContentSource = makeReviewContentSource(input)
        let lifecycleTraceRecorder = input.telemetryRecorder.map(
            BridgeProductMetadataLifecycleTraceRecorder.init(recorder:)
        )
        let annotationSource = makeWorktreeAnnotationSource(input)
        let annotationProjectionSource = makeWorktreeAnnotationProjectionSource(
            input,
            fileMetadataSource: fileMetadataSource
        )
        return BridgePaneProductSchemeProvider(
            annotationSource: annotationSource,
            annotationOutputSource: BridgePaneProductWorktreeAnnotationOutputSource(
                store: input.worktreeAnnotationStore
            ),
            annotationProjectionSource: annotationProjectionSource,
            fileMetadataSource: fileMetadataSource,
            reviewMetadataSource: BridgePaneProductReviewMetadataSource(),
            reviewContentSource: reviewContentSource,
            reviewPublicationReplay:
                input.reviewPublicationCoordinator.committedPublicationForReplay,
            isReviewPublicationCurrent:
                input.reviewPublicationCoordinator.isCurrentCanonicalPublication,
            admitReviewPublicationInstallation: { request, correlation, productAdmission in
                input.reviewPublicationCoordinator.admitDisplayInstallation(
                    expectedDisplayedPublicationId: request.expectedDisplayedPublicationId,
                    candidatePublicationId: request.candidatePublicationId,
                    workerInstanceId: correlation.workerInstanceId,
                    productAdmission: productAdmission
                )
            },
            recordReviewPublicationApplication: { publicationId, correlation, productAdmission in
                input.reviewPublicationCoordinator.recordDisplayedApplication(
                    publicationId: publicationId,
                    workerInstanceId: correlation.workerInstanceId,
                    productAdmission: productAdmission
                )
            },
            markReviewItemViewed: { itemId, productAdmission in
                _ = productAdmission.withValidAdmission {
                    input.runtime.paneState.review.markFileViewed(itemId)
                }
            },
            handleReviewIntakeReady: { request, productAdmission in
                await committedCallTarget.applyReviewIntakeReady(
                    request,
                    productAdmission: productAdmission
                )
            },
            applyActiveViewerModeUpdate: { call, correlation, productAdmission in
                await committedCallTarget.applyActiveViewerModeUpdate(
                    call,
                    correlation: correlation,
                    productAdmission: productAdmission
                )
            },
            applyReviewComparisonUpdate: committedCallTarget.applyReviewComparisonUpdate,
            applyFileRefreshRetry: committedCallTarget.applyFileRefreshRetry,
            recordCurrentFileRefreshFailure: input.recordCurrentFileRefreshFailure,
            applyWorktreeAnnotationCommand: makeWorktreeAnnotationCommandHandler(
                input,
                fileMetadataSource: fileMetadataSource
            ),
            authorizeReviewComparisonTargets: makeReviewComparisonTargetsAuthorization(input),
            reviewComparisonTargetCatalogProducer: BridgeReviewComparisonTargetCatalogProducer(
                reviewSourceProvider: input.reviewSourceProvider,
                traceRecorder: input.telemetryRecorder.map { recorder in
                    BridgeReviewComparisonTargetCatalogTraceRecorder(recorder: recorder)
                }
            ),
            comparisonTargetCatalogTraceRecorder: input.telemetryRecorder.map { recorder in
                BridgeReviewComparisonTargetCatalogTraceRecorder(recorder: recorder)
            },
            initialPanePresentation: input.initialProductPresentation,
            refreshWorkAdmissionSource: input.refreshWorkAdmissionSource,
            lifecycleTraceRecorder: lifecycleTraceRecorder
        )
    }

    private static func makeFileSourceComposition(
        _ input: BridgeProductSessionDependencyInput
    ) -> (
        source: any BridgePaneProductFileMetadataProducing,
        acceptanceRelay: BridgePaneFileSourceAcceptanceRelay
    ) {
        let acceptanceRelay = BridgePaneFileSourceAcceptanceRelay()
        let source = makeFileMetadataSource(
            input,
            sourceAcceptedObserver: { acceptedSource in
                await acceptanceRelay.accept(acceptedSource)
            }
        )
        return (source, acceptanceRelay)
    }

    private static func makeFileMetadataSource(
        _ input: BridgeProductSessionDependencyInput,
        sourceAcceptedObserver: @escaping BridgePaneProductFileSourceAcceptedObserver
    ) -> any BridgePaneProductFileMetadataProducing {
        guard
            let authority = makeProductFileSourceAuthority(
                paneId: UUID(uuidString: input.paneSessionId),
                runtime: input.runtime,
                state: input.state
            ), let gitReadContext = input.gitReadContext,
            let constructionCoordinator = input.worktreeProductConstructionCoordinator,
            let gitWorkingTreeStatusProvider = input.gitWorkingTreeStatusProvider
        else {
            return BridgeUnavailablePaneProductFileMetadataSource()
        }
        return BridgePaneProductFileMetadataSource(
            authority: authority,
            gitReadContext: gitReadContext,
            constructionCoordinator: constructionCoordinator,
            sourceAcceptedObserver: sourceAcceptedObserver,
            statusProvider: gitWorkingTreeStatusProvider
        )
    }

    private static func makeReviewContentSource(
        _ input: BridgeProductSessionDependencyInput
    ) -> BridgePaneProductReviewContentSource {
        BridgePaneProductReviewContentSource(
            loaderCache: input.reviewContentLoaderCache,
            acquireContentLease: { descriptor, productAdmission in
                input.reviewPublicationCoordinator.acquireContentLease(
                    handleId: descriptor.descriptorId,
                    packageId: descriptor.packageId,
                    requestedGeneration: BridgeReviewGeneration(
                        descriptor.reviewGeneration
                    ),
                    sourceIdentity: descriptor.sourceIdentity,
                    productAdmission: productAdmission
                )
            },
            settleContentLease: { lease in
                input.reviewPublicationCoordinator.settleContentLease(lease)
            }
        )
    }

    private static func makeWorktreeAnnotationSource(
        _ input: BridgeProductSessionDependencyInput
    ) -> BridgePaneAnnotationNotificationSource {
        guard let service = input.worktreeAnnotationStore,
            let worktreeID = input.runtime.metadata.worktreeId?.uuidString.lowercased()
        else { return .unavailable }
        return BridgePaneAnnotationNotificationSource(
            service: service,
            worktreeID: worktreeID
        )
    }

    private static func makeWorktreeAnnotationProjectionSource(
        _ input: BridgeProductSessionDependencyInput,
        fileMetadataSource: any BridgePaneProductFileMetadataProducing
    ) -> BridgeAnnotationProjectionSource {
        guard let service = input.worktreeAnnotationStore,
            let worktreeID = input.runtime.metadata.worktreeId?.uuidString.lowercased()
        else { return .unavailable }
        let sourceResolver = WorktreeAnnotationSourceCapture.resolver(
            fileMetadataSource: fileMetadataSource,
            reviewPublicationCoordinator: input.reviewPublicationCoordinator,
            reviewContentLoaderCache: input.reviewContentLoaderCache,
            gitEvidenceSource: input.reviewSourceProvider as? any WorktreeAnnotationGitEvidenceSource
        )
        return BridgeAnnotationProjectionSource(
            service: service,
            sourceResolver: sourceResolver,
            worktreeID: worktreeID,
            currentSourceGeneration: sourceResolver.currentSourceGeneration
        )
    }

    private static func makeWorktreeAnnotationCommandHandler(
        _ input: BridgeProductSessionDependencyInput,
        fileMetadataSource: any BridgePaneProductFileMetadataProducing
    )
        -> @MainActor @Sendable (
            BridgeProductWorktreeAnnotationCommandRequest,
            BridgeProductSurface,
            BridgeProductControlCorrelation,
            BridgeProductAdmissionContext
        ) async -> BridgeProductWorktreeAnnotationCommandOutcomeDTO
    {
        guard let store = input.worktreeAnnotationStore,
            let repositoryID = input.runtime.metadata.repoId?.uuidString.lowercased(),
            let worktreeID = input.runtime.metadata.worktreeId?.uuidString.lowercased()
        else {
            return { _, surface, correlation, _ in
                BridgeProductWorktreeAnnotationCommandOutcomeDTO(
                    .init(
                        requestID: correlation.requestId,
                        surface: surface,
                        sessionID: nil,
                        status: .failed(.unavailable)
                    )
                )
            }
        }
        let sourceResolver = WorktreeAnnotationSourceCapture.resolver(
            fileMetadataSource: fileMetadataSource,
            reviewPublicationCoordinator: input.reviewPublicationCoordinator,
            reviewContentLoaderCache: input.reviewContentLoaderCache,
            gitEvidenceSource: input.reviewSourceProvider as? any WorktreeAnnotationGitEvidenceSource
        )
        let adapter = WorktreeAnnotationTransportAdapter(
            store: store,
            contextID: input.paneSessionId,
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            sourceResolver: sourceResolver,
            outputCoordinator: input.worktreeAnnotationOutputCoordinator,
            outputLabels: .init(
                sessionLabel: "Current review",
                worktreeLabel: input.runtime.metadata.worktreeName ?? "Worktree",
                comparisonLabel: nil
            )
        )
        return { request, surface, correlation, productAdmission in
            await adapter.apply(
                request,
                surface: surface,
                correlation: correlation,
                productAdmission: productAdmission
            )
        }
    }

    private static func makeReviewComparisonTargetsAuthorization(
        _ input: BridgeProductSessionDependencyInput
    ) -> @Sendable () async -> BridgeProductReviewComparisonTargetsAuthorization? {
        BridgePaneProductComparisonTargetQuerySource.makeAuthorization(
            targetProjection: input.reviewComparisonTargetProjection,
            refreshWorkAdmissionSource: input.refreshWorkAdmissionSource
        )
    }

    private static func makeCommittedCallTarget(
        _ productAdmissionGate: BridgeProductAdmissionGate
    ) -> BridgePaneProductCommittedCallTarget {
        BridgePaneProductCommittedCallTarget(productAdmissionGate: productAdmissionGate)
    }

    private static func makeProductFileSourceAuthority(
        paneId: UUID?,
        runtime: BridgeRuntime,
        state: BridgePaneState
    ) -> BridgePaneProductFileSourceAuthority? {
        guard let paneId,
            let repoId = runtime.metadata.repoId,
            let worktreeId = runtime.metadata.worktreeId,
            let rootURL = worktreeFileBootstrapRootURL(
                metadata: runtime.metadata,
                source: state.source
            )
        else { return nil }
        return BridgePaneProductFileSourceAuthority(
            paneId: paneId,
            worktree: Worktree(
                id: worktreeId,
                repoId: repoId,
                name: runtime.metadata.worktreeName ?? rootURL.lastPathComponent,
                path: rootURL
            )
        )
    }

    nonisolated static func makeInitialProductSessionInstallation(
        paneSessionId: String,
        provider: any BridgeProductSchemeProvider,
        productAdmissionGate: BridgeProductAdmissionGate,
        telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil
    ) -> BridgeProductSessionInstallation {
        do {
            return try .make(
                paneSessionId: paneSessionId,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                telemetryRecorder: telemetryRecorder
            )
        } catch {
            preconditionFailure("Bridge product capability generation failed: \(error)")
        }
    }

    nonisolated static func makeProductSessionOwner(
        paneSessionId: String,
        provider: any BridgeProductSchemeProvider,
        productAdmissionGate: BridgeProductAdmissionGate,
        activeInstallation: BridgeProductSessionInstallation,
        reviewPublicationCoordinator: BridgeReviewPublicationCoordinator? = nil,
        worktreeAnnotationStore: WorktreeAnnotationServiceActor? = nil,
        telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil
    ) -> BridgePaneProductSessionOwner {
        do {
            return try BridgePaneProductSessionOwner(
                paneSessionId: paneSessionId,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                activeInstallation: activeInstallation,
                telemetryRecorder: telemetryRecorder,
                didRetireWorkerInstance: { workerInstanceId in
                    await reviewPublicationCoordinator?.retireDisplayWorker(
                        workerInstanceId: workerInstanceId
                    )
                    await worktreeAnnotationStore?.invalidateEditOwnerGeneration(workerInstanceId)
                }
            )
        } catch {
            preconditionFailure("Bridge product session owner construction failed: \(error)")
        }
    }
}
