import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

struct BridgeDevelopmentProductProviderPreparationInput {
    // Production passes nothing. A test supplies an observer so it can await the commit
    // instead of sampling the host's diagnostic read.
    let didCommitReviewPublication: (@MainActor @Sendable (BridgeReviewCommittedPublication) -> Void)?
    let gitReadContext: BridgeGitReadContext
    let operationDeadlineClock: (any Clock<Duration> & Sendable)?
    let reviewInitialization: BridgeDevelopmentProductReviewInitialization
    let reviewProvider: any BridgeReviewSourceProvider
    let schemeTaskCensus: BridgeProductSchemeTaskCensus
    let source: BridgeDevelopmentProductSource
    let statusPhysicalGate: AgentStudioGitStatusPhysicalGate
    let worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor?
    let worktreeAnnotationStore: WorktreeAnnotationServiceActor?
}

struct BridgeDevelopmentProductProviderPreparation {
    let committedCallTarget: BridgeDevelopmentProductCommittedCallTarget
    let constructionCoordinator: BridgeWorktreeProductConstructionCoordinator
    let fileMetadataSource: BridgePaneProductFileMetadataSource
    let productAdmission: BridgeProductAdmissionContext
    let productAdmissionGate: BridgeProductAdmissionGate
    let productProvider: BridgePaneProductSchemeProvider
    let productSessionOwner: BridgePaneProductSessionOwner
    let refreshAdmissionCoordinator: BridgePaneRefreshAdmissionCoordinator
    let reviewContentLoaderCache: BridgeReviewContentLoaderCache
    let reviewPublicationCoordinator: BridgeReviewPublicationCoordinator
    let reviewSharedConstructionBinder: BridgePaneReviewSharedConstructionBinder?
}

private struct BridgeDevelopmentProductProviderDependencies {
    let annotationOutputSource: BridgePaneProductWorktreeAnnotationOutputSource
    let annotationProjectionSource: BridgeAnnotationProjectionSource
    let annotationSource: BridgePaneAnnotationNotificationSource
    let applyWorktreeAnnotationCommand:
        @MainActor @Sendable (
            BridgeProductWorktreeAnnotationCommandRequest,
            BridgeProductSurface,
            BridgeProductControlCorrelation,
            BridgeProductAdmissionContext
        ) async -> BridgeProductWorktreeAnnotationCommandOutcomeDTO
    let applyReviewComparisonUpdate:
        @MainActor @Sendable (
            BridgeProductReviewComparisonUpdateRequest,
            Int,
            BridgeProductAdmissionContext
        ) async -> Void
    let applyFileRefreshRetry: @MainActor @Sendable (BridgeProductAdmissionContext) async -> Void
    let refreshAdmissionCoordinator: BridgePaneRefreshAdmissionCoordinator
    let applyActiveViewerModeUpdate:
        @MainActor @Sendable (
            BridgeProductCallRequest,
            BridgeProductControlCorrelation,
            BridgeProductAdmissionContext
        ) async -> Void
    let fileMetadataSource: BridgePaneProductFileMetadataSource
    let initialPresentation: BridgePaneProductPresentationSnapshot
    let refreshWorkAdmissionSource: BridgePaneRefreshWorkAdmissionSource
    let reviewContentLoaderCache: BridgeReviewContentLoaderCache
    let reviewMetadataSource: BridgePaneProductReviewMetadataSource
    let reviewPublicationCoordinator: BridgeReviewPublicationCoordinator
    let reviewSourceProvider: any BridgeReviewSourceProvider
    let reviewComparisonTargetProjection: BridgeReviewComparisonTargetProjection
}

extension BridgeDevelopmentProductHost {
    static func makeProductProviderPreparation(
        _ input: BridgeDevelopmentProductProviderPreparationInput
    ) async throws -> BridgeDevelopmentProductProviderPreparation {
        let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator()
        let reviewSharedConstructionBinder = makeReviewSharedConstructionBinder(
            coordinator: constructionCoordinator,
            pipeline: input.reviewInitialization.pipeline,
            provider: input.reviewProvider,
            repositoryPath: input.source.worktreeRoot
        )
        let fileMetadataSource = makeFileMetadataSource(
            source: input.source,
            gitReadContext: input.gitReadContext,
            constructionCoordinator: constructionCoordinator,
            statusPhysicalGate: input.statusPhysicalGate
        )
        let reviewContentLoaderCache = BridgeReviewContentLoaderCache(
            provider: input.reviewProvider
        )
        let didCommitReviewPublication = input.didCommitReviewPublication
        let reviewPublicationCoordinator = await MainActor.run {
            BridgeReviewPublicationCoordinator(didCommitPublication: didCommitReviewPublication)
        }
        let committedCallTarget = await MainActor.run {
            BridgeDevelopmentProductCommittedCallTarget()
        }
        let refreshAdmissionCoordinator = await makeRefreshAdmissionCoordinator(
            initialReviewTarget: input.reviewInitialization.initialTarget,
            repositoryDefaultTarget: input.reviewInitialization.defaultTarget
        )
        let refreshWorkAdmissionSource = await MainActor.run {
            refreshAdmissionCoordinator.workAdmissionSource
        }
        let initialPresentation = await refreshAdmissionCoordinator.productPresentationSnapshot
        let annotationHandlerDependencies = makeWorktreeAnnotationHandlerDependencies(
            input: input,
            fileMetadataSource: fileMetadataSource,
            reviewPublicationCoordinator: reviewPublicationCoordinator,
            reviewContentLoaderCache: reviewContentLoaderCache,
            reviewSourceProvider: input.reviewProvider
        )
        let annotationCommandHandler = await MainActor.run {
            makeWorktreeAnnotationCommandHandler(annotationHandlerDependencies)
        }
        let productProvider = makeProductProvider(
            dependencies: BridgeDevelopmentProductProviderDependencies(
                annotationOutputSource: BridgePaneProductWorktreeAnnotationOutputSource(
                    store: input.worktreeAnnotationStore
                ),
                annotationProjectionSource: makeWorktreeAnnotationProjectionSource(
                    annotationHandlerDependencies
                ),
                annotationSource: BridgePaneAnnotationNotificationSource(
                    service: input.worktreeAnnotationStore,
                    worktreeID: input.source.worktreeID.uuidString.lowercased()
                ),
                applyWorktreeAnnotationCommand: annotationCommandHandler,
                applyReviewComparisonUpdate: { request, workerDerivationEpoch, productAdmission in
                    await committedCallTarget.applyReviewComparisonUpdate(
                        request,
                        workerDerivationEpoch: workerDerivationEpoch,
                        productAdmission: productAdmission
                    )
                },
                applyFileRefreshRetry: committedCallTarget.applyFileRefreshRetry,
                refreshAdmissionCoordinator: refreshAdmissionCoordinator,
                applyActiveViewerModeUpdate: committedCallTarget.applyActiveViewerModeUpdate,
                fileMetadataSource: fileMetadataSource,
                initialPresentation: initialPresentation,
                refreshWorkAdmissionSource: refreshWorkAdmissionSource,
                reviewContentLoaderCache: reviewContentLoaderCache,
                reviewMetadataSource: BridgePaneProductReviewMetadataSource(),
                reviewPublicationCoordinator: reviewPublicationCoordinator,
                reviewSourceProvider: input.reviewProvider,
                reviewComparisonTargetProjection: input.reviewInitialization
                    .comparisonTargetProjection
            )
        )
        let sessionAdmission = try makeProductSessionAdmission(
            input: input,
            productProvider: productProvider,
            reviewPublicationCoordinator: reviewPublicationCoordinator
        )
        return BridgeDevelopmentProductProviderPreparation(
            committedCallTarget: committedCallTarget,
            constructionCoordinator: constructionCoordinator,
            fileMetadataSource: fileMetadataSource,
            productAdmission: sessionAdmission.productAdmission,
            productAdmissionGate: sessionAdmission.productAdmissionGate,
            productProvider: productProvider,
            productSessionOwner: sessionAdmission.productSessionOwner,
            refreshAdmissionCoordinator: refreshAdmissionCoordinator,
            reviewContentLoaderCache: reviewContentLoaderCache,
            reviewPublicationCoordinator: reviewPublicationCoordinator,
            reviewSharedConstructionBinder: reviewSharedConstructionBinder
        )
    }

    private static func makeProductSessionAdmission(
        input: BridgeDevelopmentProductProviderPreparationInput,
        productProvider: BridgePaneProductSchemeProvider,
        reviewPublicationCoordinator: BridgeReviewPublicationCoordinator
    ) throws -> (
        productAdmission: BridgeProductAdmissionContext,
        productAdmissionGate: BridgeProductAdmissionGate,
        productSessionOwner: BridgePaneProductSessionOwner
    ) {
        let productAdmissionGate = BridgeProductAdmissionGate()
        guard let productAdmission = productAdmissionGate.acquire() else {
            throw BridgeDevelopmentProductHostError.shutdown
        }
        let worktreeAnnotationStore = input.worktreeAnnotationStore
        let productSessionOwner = try BridgePaneProductSessionOwner(
            paneSessionId: input.source.paneID.uuidString,
            provider: productProvider,
            productAdmissionGate: productAdmissionGate,
            operationDeadlineClock: input.operationDeadlineClock,
            didRetireWorkerInstance: { workerInstanceId in
                await reviewPublicationCoordinator.retireDisplayWorker(
                    workerInstanceId: workerInstanceId
                )
                await worktreeAnnotationStore?.invalidateEditOwnerGeneration(workerInstanceId)
            },
            schemeTaskCensus: input.schemeTaskCensus
        )
        return (productAdmission, productAdmissionGate, productSessionOwner)
    }

    private static func makeWorktreeAnnotationHandlerDependencies(
        input: BridgeDevelopmentProductProviderPreparationInput,
        fileMetadataSource: BridgePaneProductFileMetadataSource,
        reviewPublicationCoordinator: BridgeReviewPublicationCoordinator,
        reviewContentLoaderCache: BridgeReviewContentLoaderCache,
        reviewSourceProvider: any BridgeReviewSourceProvider
    ) -> WorktreeAnnotationCommandHandlerDependencies {
        .init(
            store: input.worktreeAnnotationStore,
            outputCoordinator: input.worktreeAnnotationOutputCoordinator,
            source: input.source,
            fileMetadataSource: fileMetadataSource,
            reviewPublicationCoordinator: reviewPublicationCoordinator,
            reviewContentLoaderCache: reviewContentLoaderCache,
            reviewSourceProvider: reviewSourceProvider
        )
    }

    private static func makeReviewSharedConstructionBinder(
        coordinator: BridgeWorktreeProductConstructionCoordinator,
        pipeline: BridgeReviewPipeline,
        provider: any BridgeReviewSourceProvider,
        repositoryPath: URL
    ) -> BridgePaneReviewSharedConstructionBinder? {
        guard provider is any BridgeSharedReviewConstructionSourceProvider else { return nil }
        return BridgePaneReviewSharedConstructionBinder(
            coordinator: coordinator,
            pipeline: pipeline,
            repositoryPath: repositoryPath
        )
    }

    @MainActor
    private static func makeRefreshAdmissionCoordinator(
        initialReviewTarget: WorkspaceReviewContributionTarget,
        repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
    ) -> BridgePaneRefreshAdmissionCoordinator {
        BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground,
            initialReviewComparison: BridgePaneReviewComparisonPresentation(
                activeTarget: initialReviewTarget,
                attempt: .pending(reviewGeneration: 0),
                displayedSnapshot: .absent,
                repositoryDefaultTarget: repositoryDefaultTarget
            )
        )
    }

    private static func makeProductProvider(
        dependencies: BridgeDevelopmentProductProviderDependencies
    ) -> BridgePaneProductSchemeProvider {
        let reviewContentSource = BridgePaneProductReviewContentSource(
            loaderCache: dependencies.reviewContentLoaderCache,
            acquireContentLease: { descriptor, productAdmission in
                dependencies.reviewPublicationCoordinator.acquireContentLease(
                    handleId: descriptor.descriptorId,
                    packageId: descriptor.packageId,
                    requestedGeneration: BridgeReviewGeneration(descriptor.reviewGeneration),
                    sourceIdentity: descriptor.sourceIdentity,
                    productAdmission: productAdmission
                )
            },
            settleContentLease: { lease in
                dependencies.reviewPublicationCoordinator.settleContentLease(lease)
            }
        )
        return BridgePaneProductSchemeProvider(
            annotationSource: dependencies.annotationSource,
            annotationOutputSource: dependencies.annotationOutputSource,
            annotationProjectionSource: dependencies.annotationProjectionSource,
            fileMetadataSource: dependencies.fileMetadataSource,
            reviewMetadataSource: dependencies.reviewMetadataSource,
            reviewContentSource: reviewContentSource,
            reviewPublicationReplay: { productAdmission in
                dependencies.reviewPublicationCoordinator.committedPublicationForReplay(
                    productAdmission: productAdmission
                )
            },
            isReviewPublicationCurrent: { publicationId, productAdmission in
                dependencies.reviewPublicationCoordinator.isCurrentCanonicalPublication(
                    publicationId: publicationId,
                    productAdmission: productAdmission
                )
            },
            admitReviewPublicationInstallation: { request, correlation, productAdmission in
                dependencies.reviewPublicationCoordinator.admitDisplayInstallation(
                    expectedDisplayedPublicationId: request.expectedDisplayedPublicationId,
                    candidatePublicationId: request.candidatePublicationId,
                    workerInstanceId: correlation.workerInstanceId,
                    productAdmission: productAdmission
                )
            },
            recordReviewPublicationApplication: { publicationId, correlation, productAdmission in
                dependencies.reviewPublicationCoordinator.recordDisplayedApplication(
                    publicationId: publicationId,
                    workerInstanceId: correlation.workerInstanceId,
                    productAdmission: productAdmission
                )
            },
            markReviewItemViewed: { _, _ in },
            applyActiveViewerModeUpdate: dependencies.applyActiveViewerModeUpdate,
            applyReviewComparisonUpdate: dependencies.applyReviewComparisonUpdate,
            applyFileRefreshRetry: dependencies.applyFileRefreshRetry,
            recordCurrentFileRefreshFailure: { failure in
                dependencies.refreshAdmissionCoordinator.recordCurrentFileRefreshFailure(failure)
            },
            applyWorktreeAnnotationCommand: dependencies.applyWorktreeAnnotationCommand,
            authorizeReviewComparisonTargets:
                BridgePaneProductComparisonTargetQuerySource.makeAuthorization(
                    targetProjection: dependencies.reviewComparisonTargetProjection,
                    refreshWorkAdmissionSource: dependencies.refreshWorkAdmissionSource
                ),
            reviewComparisonTargetCatalogProducer: BridgeReviewComparisonTargetCatalogProducer(
                reviewSourceProvider: dependencies.reviewSourceProvider
            ),
            initialPanePresentation: dependencies.initialPresentation,
            refreshWorkAdmissionSource: dependencies.refreshWorkAdmissionSource
        )
    }

    private static func makeFileMetadataSource(
        source: BridgeDevelopmentProductSource,
        gitReadContext: BridgeGitReadContext,
        constructionCoordinator: BridgeWorktreeProductConstructionCoordinator,
        statusPhysicalGate: AgentStudioGitStatusPhysicalGate
    ) -> BridgePaneProductFileMetadataSource {
        BridgePaneProductFileMetadataSource(
            authority: BridgePaneProductFileSourceAuthority(
                paneId: source.paneID,
                worktree: Worktree(
                    id: source.worktreeID,
                    repoId: source.repoID,
                    name: source.worktreeRoot.lastPathComponent,
                    path: source.worktreeRoot
                )
            ),
            gitReadContext: gitReadContext,
            constructionCoordinator: constructionCoordinator,
            statusProvider: AgentStudioGitWorkingTreeStatusProvider(
                physicalGate: statusPhysicalGate
            )
        )
    }

    static func makeSchemeHandler(
        paneId: UUID,
        source: BridgeDevelopmentProductSource,
        productSessionOwner: BridgePaneProductSessionOwner
    ) -> BridgeSchemeHandler {
        BridgeSchemeHandler(
            paneId: paneId,
            appRootURL: source.worktreeRoot,
            telemetrySessionOwner: nil,
            productSessionRouter: productSessionOwner.schemeRouter
        )
    }
}
