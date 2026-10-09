import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import WebKit

package enum BridgeDevelopmentProductHostShutdownResult: Equatable, Sendable {
    case completed
    case quiescenceDeadlineExceeded(unfinishedExecutionCount: Int)
}

package struct BridgeDevelopmentProductHostShutdownSnapshot: Equatable, Sendable {
    package let unfinishedDrainCount: Int
    package let cleanupCompleted: Bool
}

package actor BridgeDevelopmentProductHost {
    struct FileNavigationPublication: Equatable {
        let bindingRevision: Int
        let source: BridgeProductFileSourceIdentity
    }

    let constructionCoordinator: BridgeWorktreeProductConstructionCoordinator
    let contributionTargetCommit:
        @MainActor @Sendable (WorkspaceReviewContributionTarget) -> BridgePaneStateMutationResult
    private let committedCallTarget: BridgeDevelopmentProductCommittedCallTarget
    var activeReviewComparisonTask: Task<Void, Never>?
    var activeReviewComparisonTaskAttempt: UInt64?
    var retiringReviewComparisonTasks: [UInt64: Task<Void, Never>] = [:]
    var bootstrapTransitionTail: Task<Void, Never>?
    let gitReadScheduler: BridgeGitReadScheduler
    private var navigationBindingRevision = 0 { didSet { publishBootstrapAuthorization() } }
    private var navigationIntent: BridgeDevelopmentProductBootstrapRequest.NavigationIntent? {
        didSet { publishBootstrapAuthorization() }
    }
    private var owningTabId: String? { didSet { publishBootstrapAuthorization() } }
    private let bootstrapAuthorizationProjection: BridgeDevelopmentBootstrapAuthorizationProjection
    private let paneSessionId: String
    let retirementDelay: AsyncDelay
    let productAdmission: BridgeProductAdmissionContext
    let productAdmissionGate: BridgeProductAdmissionGate
    let productProvider: BridgePaneProductSchemeProvider
    let productSessionOwner: BridgePaneProductSessionOwner
    let refreshAdmissionCoordinator: BridgePaneRefreshAdmissionCoordinator
    let worktreeRefreshDriver: BridgePaneWorktreeRefreshDriver
    private let repoId: UUID
    private let reviewedSubjectLabel: String?
    let reviewContentLoaderCache: BridgeReviewContentLoaderCache
    var paneState: BridgePaneState
    private let reviewPipeline: BridgeReviewPipeline
    let reviewProvider: any BridgeReviewSourceProvider
    var reviewGitRefreshSeedHolder = BridgeReviewGitRefreshSeedHolder()
    let reviewComparisonTargetProjection: BridgeReviewComparisonTargetProjection
    let reviewPublicationCoordinator: BridgeReviewPublicationCoordinator
    private let reviewSharedConstructionBinder: BridgePaneReviewSharedConstructionBinder?
    private let schemeHandler: BridgeSchemeHandler
    var isShutdown = false { didSet { publishBootstrapAuthorization() } }
    var shutdownCompletion: AsyncStream<BridgeDevelopmentProductHostShutdownResult>.Continuation?
    var shutdownDeadlineTask: Task<Void, Never>?
    var unfinishedShutdownDrains: Set<String> = []
    var shutdownResult: BridgeDevelopmentProductHostShutdownResult?
    var shutdownWaiters: [CheckedContinuation<BridgeDevelopmentProductHostShutdownResult, Never>] = []
    var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextReviewComparisonTaskAttempt: UInt64 = 0
    var nextReviewGeneration: BridgeReviewGeneration = 1
    private var publishedFileNavigation: FileNavigationPublication?
    private let worktreeId: UUID
    private let worktreeRoot: URL

    package init(
        source: BridgeDevelopmentProductSource,
        worktreeAnnotationStore: WorktreeAnnotationServiceActor? = nil,
        worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor? = nil,
        statusPhysicalGate: AgentStudioGitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate(),
        operationDeadlineClock: (any Clock<Duration> & Sendable)? = nil,
        retirementClock: (any Clock<Duration> & Sendable)? = nil,
        contributionTargetCommit:
            @escaping @MainActor @Sendable (WorkspaceReviewContributionTarget) ->
            BridgePaneStateMutationResult
    ) async throws {
        try await self.init(
            source: source,
            worktreeAnnotationStore: worktreeAnnotationStore,
            worktreeAnnotationOutputCoordinator: worktreeAnnotationOutputCoordinator,
            operationDeadlineClock: operationDeadlineClock,
            retirementClock: retirementClock,
            contributionTargetCommit: contributionTargetCommit,
            statusPhysicalGate: statusPhysicalGate,
            makeReviewProvider: { repositoryPath, gitReadContext in
                BridgeReviewSourceProviderFactory.gitProvider(
                    repositoryPath: repositoryPath,
                    gitReadContext: gitReadContext,
                    statusPhysicalGate: statusPhysicalGate
                )
            }
        )
    }

    package init(
        source: BridgeDevelopmentProductSource,
        worktreeAnnotationStore: WorktreeAnnotationServiceActor? = nil,
        worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor? = nil,
        operationDeadlineClock: (any Clock<Duration> & Sendable)? = nil,
        retirementClock: (any Clock<Duration> & Sendable)? = nil,
        contributionTargetCommit:
            @escaping @MainActor @Sendable (WorkspaceReviewContributionTarget) ->
            BridgePaneStateMutationResult,
        statusPhysicalGate: AgentStudioGitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate(),
        makeReviewProvider: @Sendable (URL, BridgeGitReadContext) -> any BridgeReviewSourceProvider,
        // Production passes nothing. A test supplies a census with a termination
        // observer to pin the window this host's bootstrap gate now handles.
        schemeTaskCensus: BridgeProductSchemeTaskCensus = BridgeProductSchemeTaskCensus(),
        // Production passes nothing. A test supplies an observer of the Review commit,
        // which is the only moment the publication's existence is published rather than
        // merely readable, so the test can await it instead of sampling. It carries no
        // payload because this initializer is `package` while
        // `BridgeReviewCommittedPublication` is internal, and widening that type's
        // visibility is not worth a signal that only says "a commit happened"; a caller
        // that needs the publication reads it back from the host.
        didCommitReviewPublication: (@MainActor @Sendable () -> Void)? = nil
    ) async throws {
        let source = try Self.validatedFilesystemSource(source)
        let paneId = source.paneID
        let repoId = source.repoID
        let gitReadScheduler = BridgeGitReadScheduler(topology: .recoveryBaseline)
        let gitReadContext = BridgeGitReadContext(
            scheduler: gitReadScheduler,
            worktreeKey: BridgeGitReadWorktreeKey(token: StableKey.fromPath(source.worktreeRoot)),
            scopeKey: BridgeGitReadScopeKey(token: paneId.uuidString)
        )
        let reviewProvider = makeReviewProvider(source.worktreeRoot, gitReadContext)
        let reviewInitialization = try await Self.makeReviewInitialization(
            state: source.paneState,
            provider: reviewProvider
        )

        // Adapts the payload-free `package` signal to the coordinator-level hook, which
        // carries the committed publication for callers that can see that internal type.
        var reviewCommitObservation: (@MainActor @Sendable (BridgeReviewCommittedPublication) -> Void)?
        if let observeCommit = didCommitReviewPublication {
            reviewCommitObservation = { _ in observeCommit() }
        }

        let productPreparation = try await Self.makeProductProviderPreparation(
            .init(
                didCommitReviewPublication: reviewCommitObservation,
                gitReadContext: gitReadContext,
                operationDeadlineClock: operationDeadlineClock,
                reviewInitialization: reviewInitialization,
                reviewProvider: reviewProvider,
                schemeTaskCensus: schemeTaskCensus,
                source: source,
                statusPhysicalGate: statusPhysicalGate,
                worktreeAnnotationOutputCoordinator: worktreeAnnotationOutputCoordinator,
                worktreeAnnotationStore: worktreeAnnotationStore
            )
        )

        self.constructionCoordinator = productPreparation.constructionCoordinator
        self.contributionTargetCommit = contributionTargetCommit
        self.committedCallTarget = productPreparation.committedCallTarget
        self.gitReadScheduler = gitReadScheduler
        self.paneSessionId = paneId.uuidString
        self.bootstrapAuthorizationProjection = BridgeDevelopmentBootstrapAuthorizationProjection(
            paneSessionId: paneId.uuidString)
        self.retirementDelay = retirementClock.map(AsyncDelay.clock) ?? .taskSleep
        self.productAdmission = productPreparation.productAdmission
        self.productAdmissionGate = productPreparation.productAdmissionGate
        self.productProvider = productPreparation.productProvider
        self.productSessionOwner = productPreparation.productSessionOwner
        self.refreshAdmissionCoordinator = productPreparation.refreshAdmissionCoordinator
        self.worktreeRefreshDriver = await Self.makeWorktreeRefreshDriver(productPreparation)
        self.repoId = repoId
        self.reviewedSubjectLabel = source.reviewedSubjectLabel
        self.reviewContentLoaderCache = productPreparation.reviewContentLoaderCache
        self.paneState = source.paneState
        self.reviewPipeline = reviewInitialization.pipeline
        self.reviewProvider = reviewProvider
        self.reviewComparisonTargetProjection = reviewInitialization.comparisonTargetProjection
        self.reviewPublicationCoordinator = productPreparation.reviewPublicationCoordinator
        self.reviewSharedConstructionBinder = productPreparation.reviewSharedConstructionBinder
        self.schemeHandler = Self.makeSchemeHandler(
            paneId: paneId,
            source: source,
            productSessionOwner: productPreparation.productSessionOwner
        )
        self.worktreeId = source.worktreeID
        self.worktreeRoot = source.worktreeRoot
        await connectProductCallbacks(
            committedCallTarget: productPreparation.committedCallTarget,
            fileMetadataSource: productPreparation.fileMetadataSource
        )
    }

    private static func makeWorktreeRefreshDriver(
        _ preparation: BridgeDevelopmentProductProviderPreparation
    ) async -> BridgePaneWorktreeRefreshDriver {
        let productProvider = preparation.productProvider
        let productAdmissionGate = preparation.productAdmissionGate
        return await MainActor.run {
            BridgePaneWorktreeRefreshDriver(
                coordinator: preparation.refreshAdmissionCoordinator,
                acquireProductAdmission: { productAdmissionGate.acquire() },
                publishFileChangeset: productProvider.publishFileChangeset,
                publishFileStatus: productProvider.publishFileStatus,
                publishPresentation: { snapshot, traceContext in
                    await productProvider.publishPanePresentation(
                        snapshot,
                        traceContext: traceContext
                    )
                },
                publishOperationLifecycle: { event in
                    await productProvider.recordOperationLifecycle(event)
                }
            )
        }
    }

    package func issueBootstrap(
        for request: BridgeDevelopmentProductBootstrapRequest
    ) async throws -> Data {
        guard !isShutdown else { throw BridgeDevelopmentProductHostError.shutdown }
        let predecessor = productSessionOwner.installationFenceProjection.snapshot
        let authorization = bootstrapAuthorizationProjection.snapshot
        try await validateBootstrapTransition(request, predecessor: predecessor, authorization: authorization)
        guard !isShutdown, bootstrapAuthorizationProjection.snapshot == authorization,
            productSessionOwner.installationFenceProjection.snapshot == predecessor
        else { throw BridgeDevelopmentProductHostError.sessionAlreadyOpen }
        predecessor.close()
        let precedingTransition = bootstrapTransitionTail
        let transition = Task { [weak self] () throws -> Data in
            if let precedingTransition {
                await precedingTransition.value
            }
            try Task.checkCancellation()
            guard let self else { throw BridgeDevelopmentProductHostError.shutdown }
            return try await self.performBootstrapTransition(for: request, predecessor: predecessor)
        }
        bootstrapTransitionTail = Task {
            _ = try? await transition.value
        }
        return try await withTaskCancellationHandler {
            try await transition.value
        } onCancel: {
            transition.cancel()
        }
    }

    private func publishBootstrapAuthorization() {
        bootstrapAuthorizationProjection.publish(
            tabId: owningTabId,
            navigationBindingRevision: navigationBindingRevision, isShutdown: isShutdown)
    }

    private func performBootstrapTransition(
        for request: BridgeDevelopmentProductBootstrapRequest,
        predecessor: BridgeProductInstallationFenceSnapshot
    ) async throws -> Data {
        guard !isShutdown else { throw BridgeDevelopmentProductHostError.shutdown }
        try Task.checkCancellation()
        guard !isShutdown else { throw BridgeDevelopmentProductHostError.shutdown }
        let candidate = try await productSessionOwner.prepareCandidate(
            productAdmission: productAdmission
        )
        guard
            await productSessionOwner.activatePreparedCandidate(
                candidate,
                productAdmission: productAdmission,
                replacing: predecessor
            ) == .activated
        else {
            throw BridgeDevelopmentProductHostError.sessionActivationFailed
        }
        let reviewPublication = try await prepareReviewPublicationIfNeeded(
            for: request.navigationIntent
        )
        navigationIntent = request.navigationIntent
        if request.reason == .initial { owningTabId = request.tabId }
        navigationBindingRevision += 1
        await publishNavigation(
            request.navigationIntent,
            bindingRevision: navigationBindingRevision,
            bootstrap: candidate.bootstrap,
            reviewPublication: reviewPublication
        )
        return try BridgeDevelopmentProductBootstrapEnvelope.encode(candidate)
    }

    package func route(
        _ request: URLRequest
    ) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        schemeHandler.reply(for: request)
    }

    package func handleObservedWorktreeInvalidation(
        _ invalidation: BridgePaneWorktreeProductInvalidation
    ) async {
        guard !isShutdown else { return }
        let affectedLanes: Set<BridgePaneRefreshLane>
        switch invalidation {
        case .filesChanged(let changeset):
            guard changeset.repoId == repoId,
                changeset.worktreeId == worktreeId,
                changeset.rootPath.standardizedFileURL.resolvingSymlinksInPath()
                    == worktreeRoot.standardizedFileURL.resolvingSymlinksInPath()
            else { return }
            _ = await constructionCoordinator.invalidate(
                worktree: worktreeConstructionIdentity
            )
            affectedLanes = await worktreeRefreshDriver.recordInvalidation(
                fileChangeset: changeset,
                requiresReviewRefresh: true
            )
        case .statusChanged(let status):
            _ = await constructionCoordinator.invalidate(
                worktree: worktreeConstructionIdentity
            )
            affectedLanes = await worktreeRefreshDriver.recordInvalidation(
                fileChangeset: nil,
                latestFileStatus: status,
                requiresReviewRefresh: true
            )
        }
        if affectedLanes.contains(.review) {
            await scheduleObservedReviewRefreshIfPossible()
        }
    }

    private var worktreeConstructionIdentity: BridgeWorktreeIdentityKey {
        BridgeWorktreeIdentityKey(
            repoIdentity: repoId.uuidString,
            worktreeIdentity: worktreeId.uuidString,
            stableRootIdentity: StableKey.fromPath(worktreeRoot)
        )
    }

    private func publishNavigation(
        _ navigationIntent: BridgeDevelopmentProductBootstrapRequest.NavigationIntent,
        bindingRevision: Int,
        bootstrap: BridgeProductSessionBootstrap,
        reviewPublication: BridgeReviewCommittedPublication?
    ) async {
        let navigationCommand: BridgeProductNavigationCommand
        switch navigationIntent {
        case .activateContext(let commandId, let surface):
            navigationCommand = .activateContext(
                commandId: commandId,
                bindingRevision: bindingRevision,
                surface: surface
            )
        case .activateFileTarget:
            // Activate the source owner before waiting for its accepted identity. The later
            // target keeps the caller's command ID so an activation receipt cannot clear it.
            navigationCommand = .activateContext(
                commandId: UUIDv7.generate().uuidString.lowercased(),
                bindingRevision: bindingRevision,
                surface: .file
            )
            navigationBindingRevision = max(navigationBindingRevision, bindingRevision + 1)
        case .activateReviewTarget:
            guard let reviewPublication,
                let reviewCommand = Self.bindReviewNavigationCommand(
                    intent: navigationIntent,
                    publication: reviewPublication,
                    bindingRevision: bindingRevision
                )
            else { return }
            navigationCommand = reviewCommand
        }
        let request = BridgePaneSurfaceSelectionRequest(
            navigationCommand: navigationCommand,
            paneSessionId: bootstrap.paneSessionId,
            workerInstanceId: bootstrap.workerInstanceId
        )
        _ = await productProvider.publishPaneSurfaceSelectionRequest(
            request,
            productAdmission: productAdmission,
            streamAbsenceDisposition: .retainForReplay
        )
    }

    private func publishFileNavigationIfNeeded(
        _ source: BridgeProductFileSourceIdentity
    ) async {
        guard
            let bindingRevision = Self.nextFileNavigationBindingRevision(
                currentBindingRevision: navigationBindingRevision,
                previouslyPublishedBindingRevision: publishedFileNavigation?.bindingRevision,
                previouslyPublishedSource: publishedFileNavigation?.source,
                acceptedSource: source
            )
        else { return }
        guard !isShutdown,
            let navigationIntent,
            let navigationCommand = Self.bindFileNavigationCommand(
                intent: navigationIntent,
                source: source,
                bindingRevision: bindingRevision
            ),
            let bootstrap = await productSessionOwner.activeBootstrap()
        else { return }
        let request = BridgePaneSurfaceSelectionRequest(
            navigationCommand: navigationCommand,
            paneSessionId: bootstrap.paneSessionId,
            workerInstanceId: bootstrap.workerInstanceId
        )
        guard
            await productProvider.publishPaneSurfaceSelectionRequest(
                request,
                productAdmission: productAdmission,
                streamAbsenceDisposition: .retainForReplay
            )
        else { return }
        navigationBindingRevision = Self.navigationBindingRevisionAfterFilePublish(
            currentBindingRevision: navigationBindingRevision,
            publishedRequestBindingRevision: bindingRevision
        )
        publishedFileNavigation = Self.fileNavigationPublicationAfterCommit(
            currentPublication: publishedFileNavigation,
            completedPublication: FileNavigationPublication(
                bindingRevision: bindingRevision,
                source: source
            )
        )
    }

    static func fileNavigationPublicationAfterCommit(
        currentPublication: FileNavigationPublication?,
        completedPublication: FileNavigationPublication
    ) -> FileNavigationPublication {
        guard let currentPublication,
            currentPublication.bindingRevision >= completedPublication.bindingRevision
        else {
            return completedPublication
        }
        return currentPublication
    }

    static func navigationBindingRevisionAfterFilePublish(
        currentBindingRevision: Int,
        publishedRequestBindingRevision: Int
    ) -> Int {
        max(currentBindingRevision, publishedRequestBindingRevision)
    }

    static func nextFileNavigationBindingRevision(
        currentBindingRevision: Int,
        previouslyPublishedBindingRevision: Int?,
        previouslyPublishedSource: BridgeProductFileSourceIdentity?,
        acceptedSource: BridgeProductFileSourceIdentity
    ) -> Int? {
        guard previouslyPublishedSource != acceptedSource else {
            guard previouslyPublishedBindingRevision != currentBindingRevision else { return nil }
            return currentBindingRevision
        }
        guard let previouslyPublishedBindingRevision else { return currentBindingRevision }
        return max(currentBindingRevision, previouslyPublishedBindingRevision + 1)
    }

    private func prepareReviewPublicationIfNeeded(
        for navigationIntent: BridgeDevelopmentProductBootstrapRequest.NavigationIntent
    ) async throws -> BridgeReviewCommittedPublication? {
        let requiresReviewPublication: Bool
        switch navigationIntent {
        case .activateContext(_, .review), .activateReviewTarget:
            requiresReviewPublication = true
        case .activateContext(_, .file), .activateFileTarget:
            requiresReviewPublication = false
        }
        guard requiresReviewPublication else { return nil }
        if let activePublication = await MainActor.run(body: {
            reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        }) {
            return activePublication
        }

        let target = try Self.reviewTarget(from: paneState)
        let initialGeneration = nextReviewGeneration
        await MainActor.run {
            refreshAdmissionCoordinator.beginReviewComparisonAttempt(
                activeTarget: target,
                reviewGeneration: initialGeneration.rawValue
            )
        }
        await publishCurrentPanePresentation()
        let construction: BridgeDevelopmentReviewPublicationConstruction
        do {
            construction = try await constructReviewPublication(
                target: target,
                reviewGeneration: initialGeneration
            )
        } catch {
            await failReviewComparisonAttempt(
                initialGeneration,
                failureKind: "publication_failed",
                refreshReservation: nil
            )
            throw error
        }
        let preparedPublication = construction.preparedPublication
        let committedPublication: BridgeReviewCommittedPublication? = await MainActor.run {
            () -> BridgeReviewCommittedPublication? in
            guard
                let token = reviewPublicationCoordinator.stage(
                    preparedPublication,
                    productAdmission: productAdmission
                )
            else { return nil }
            guard
                case .committed(let committedPublication) = reviewPublicationCoordinator.commit(
                    token,
                    productAdmission: productAdmission,
                    captureCommittedPresentation: { package in
                        refreshAdmissionCoordinator.settleReviewComparisonAttempt(
                            reviewGeneration: package.reviewGeneration.rawValue,
                            displayedSnapshotIdentity: BridgePaneReviewDisplayedSnapshotIdentity(
                                packageId: package.packageId,
                                reviewGeneration: package.reviewGeneration.rawValue,
                                revision: package.revision
                            )
                        )
                        return refreshAdmissionCoordinator.productPresentationSnapshot
                    },
                    presentCommitted: { _ in }
                )
            else {
                _ = reviewPublicationCoordinator.rejectReservation(
                    token,
                    productAdmission: productAdmission
                )
                return nil
            }
            return committedPublication
        }
        guard let committedPublication else {
            await failReviewComparisonAttempt(
                initialGeneration,
                failureKind: "publication_failed",
                refreshReservation: nil
            )
            throw BridgeDevelopmentProductHostError.reviewPublicationFailed
        }
        reviewGitRefreshSeedHolder.commit(construction.gitRefreshSeed)
        nextReviewGeneration = committedPublication.package.reviewGeneration
        await publishCurrentPanePresentation()
        return committedPublication
    }

    func constructReviewPublication(
        target: WorkspaceReviewContributionTarget,
        reviewGeneration: BridgeReviewGeneration,
        predecessorPackage: BridgeReviewPackage? = nil,
        refreshReservation: BridgePaneRefreshCatchUpReservation? = nil
    ) async throws -> BridgeDevelopmentReviewPublicationConstruction {
        let pipelineRequest = try await makeDevelopmentReviewPipelineRequest(
            generatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            reviewGeneration: reviewGeneration,
            target: target,
            predecessorPackage: predecessorPackage,
            refreshReservation: refreshReservation
        )
        let constructionResult: BridgeReviewPackageConstructionResult
        if let reviewSharedConstructionBinder {
            let binding = try await reviewSharedConstructionBinder.acquire(pipelineRequest)
            constructionResult = BridgeReviewPackageConstructionResult(
                result: binding.result,
                artifactPin: binding.artifactPin
            )
        } else {
            constructionResult = BridgeReviewPackageConstructionResult(
                result: try await reviewPipeline.loadPackage(pipelineRequest),
                artifactPin: nil
            )
        }
        do {
            try Task.checkCancellation()
        } catch {
            await constructionResult.releaseArtifactPin()
            throw error
        }
        let result = constructionResult.result
        let package: BridgeReviewPackage
        let delta: BridgeReviewDelta?
        if let predecessorPackage,
            result.package.packageId == predecessorPackage.packageId,
            result.package.reviewGeneration == predecessorPackage.reviewGeneration
        {
            delta = try BridgeReviewDeltaBuilder.build(
                BridgeReviewDeltaBuildRequest(
                    currentPackage: predecessorPackage,
                    nextPackage: result.package,
                    currentRevision: predecessorPackage.revision
                )
            )
            if let delta {
                package = result.package.withRevision(delta.revision)
            } else {
                let revision =
                    result.package.hasSameReviewTruth(as: predecessorPackage)
                    ? predecessorPackage.revision
                    : predecessorPackage.revision + 1
                package = result.package.withRevision(revision)
            }
        } else {
            package = result.package
            delta = nil
        }
        guard
            let preparedPublication = await BridgeReviewPreparedPublication.prepare(
                BridgeReviewPublicationCandidate(
                    package: package,
                    delta: delta,
                    contentHandles: result.registeredContentHandles,
                    artifactPin: constructionResult.artifactPin
                )
            )
        else {
            await constructionResult.releaseArtifactPin()
            throw BridgeDevelopmentProductHostError.reviewPublicationFailed
        }
        return BridgeDevelopmentReviewPublicationConstruction(
            preparedPublication: preparedPublication,
            gitRefreshSeed: result.gitRefreshSeed
        )
    }

    private func makeDevelopmentReviewPipelineRequest(
        generatedAt: Int64,
        reviewGeneration: BridgeReviewGeneration,
        target: WorkspaceReviewContributionTarget,
        predecessorPackage: BridgeReviewPackage?,
        refreshReservation: BridgePaneRefreshCatchUpReservation?
    ) async throws -> BridgeReviewPipelineRequest {
        let replacementBaseEndpoint = BridgeSourceEndpoint(
            endpointId: "development-base",
            kind: .gitRef,
            repoId: repoId,
            worktreeId: worktreeId,
            label: Self.label(for: target),
            createdAtUnixMilliseconds: generatedAt,
            contentSetHash: nil,
            providerIdentity: Self.label(for: target)
        )
        let replacementHeadEndpoint = BridgeSourceEndpoint(
            endpointId: "development-working-tree",
            kind: .workingTree,
            repoId: repoId,
            worktreeId: worktreeId,
            label: "Working tree",
            createdAtUnixMilliseconds: generatedAt,
            contentSetHash: nil,
            providerIdentity: "working-tree:\(worktreeId.uuidString)"
        )
        let baseEndpoint = predecessorPackage?.baseEndpoint ?? replacementBaseEndpoint
        let headEndpoint = predecessorPackage?.headEndpoint ?? replacementHeadEndpoint
        let query =
            predecessorPackage?.query
            ?? BridgeReviewQuery(
                queryId: "development-query-\(UUIDv7.generate().uuidString)",
                queryKind: .compare,
                repoId: repoId,
                worktreeId: worktreeId,
                baseEndpointId: baseEndpoint.endpointId,
                headEndpointId: headEndpoint.endpointId,
                comparisonSemantics: .workingTreeDelta,
                pathScope: [],
                fileTarget: nil,
                viewFilter: BridgeViewFilter(
                    showHiddenFiles: true,
                    showBinaryFiles: true,
                    showLargeFiles: true
                ),
                grouping: BridgeChangeGrouping(kind: .flat),
                provenanceFilter: BridgeProvenanceFilter()
            )
        let request = BridgeReviewPipelineRequest(
            packageId: predecessorPackage?.packageId ?? "development-package-\(UUIDv7.generate().uuidString)",
            query: query,
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            checkpointIds: [],
            reviewGeneration: reviewGeneration,
            generatedAtUnixMilliseconds: generatedAt,
            reviewAttemptAuthorityGeneration: refreshReservation?.authorityGeneration ?? 0,
            gitRefreshScope:
                refreshReservation?.reviewRefreshScope ?? .complete(reason: .nonExactInput),
            gitRefreshSeed: predecessorPackage == nil ? nil : reviewGitRefreshSeedHolder.activeSeed
        )
        let capture = try await reviewProvider.captureContributionComparison(
            BridgeContributionComparisonRequest(
                symbolicTarget: target,
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                reviewGenerationValue: reviewGeneration.rawValue,
                reviewAttemptAuthorityGeneration: request.reviewAttemptAuthorityGeneration,
                gitRefreshScope: request.gitRefreshScope,
                gitRefreshSeed: request.gitRefreshSeed
            )
        )
        return try BridgeResolvedContributionRequestBuilder.build(
            request: request,
            symbolicTarget: target,
            capture: capture,
            reviewedSubjectLabel: reviewedSubjectLabel
        )
    }

    func allocateReviewComparisonTaskAttempt() -> UInt64 {
        nextReviewComparisonTaskAttempt &+= 1
        return nextReviewComparisonTaskAttempt
    }

    static func loadReviewComparisonDefaultTarget(
        from reviewProvider: any BridgeReviewSourceProvider
    ) async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        do {
            return try await reviewProvider.resolveReviewDefaultTarget()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    static func bindReviewNavigationCommand(
        intent: BridgeDevelopmentProductBootstrapRequest.NavigationIntent,
        publication: BridgeReviewCommittedPublication,
        bindingRevision: Int
    ) -> BridgeProductNavigationCommand? {
        guard case .activateReviewTarget(let commandId, let target) = intent else {
            return nil
        }
        let package = publication.package
        return .activateReviewTarget(
            commandId: commandId,
            bindingRevision: bindingRevision,
            source: BridgeProductNavigationReviewSource(
                generation: package.reviewGeneration.rawValue,
                metadataSourceId: package.query.queryId,
                packageId: package.packageId
            ),
            target: target
        )
    }

    static func bindFileNavigationCommand(
        intent: BridgeDevelopmentProductBootstrapRequest.NavigationIntent,
        source: BridgeProductFileSourceIdentity,
        bindingRevision: Int
    ) -> BridgeProductNavigationCommand? {
        guard case .activateFileTarget(let commandId, let target) = intent else {
            return nil
        }
        return .activateFileTarget(
            commandId: commandId,
            bindingRevision: bindingRevision,
            source: BridgeProductNavigationFileSource(
                sourceId: source.sourceId,
                subscriptionGeneration: source.subscriptionGeneration
            ),
            target: target
        )
    }

    private func connectProductCallbacks(
        committedCallTarget: BridgeDevelopmentProductCommittedCallTarget,
        fileMetadataSource: BridgePaneProductFileMetadataSource
    ) async {
        await MainActor.run {
            committedCallTarget.host = self
        }
        await fileMetadataSource.setSourceAcceptedObserver { [weak self] source in
            await self?.recordAcceptedFileSource(source)
        }
    }

    private func recordAcceptedFileSource(
        _ source: BridgeProductFileSourceIdentity
    ) async {
        await worktreeRefreshDriver.recordFileSourceAccepted(source)
        await publishFileNavigationIfNeeded(source)
    }

    private static func validatedFilesystemSource(
        _ source: BridgeDevelopmentProductSource
    ) throws -> BridgeDevelopmentProductSource {
        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(
            atPath: source.worktreeRoot.path,
            isDirectory: &isDirectory
        )
        let gitAuthorityExists = FileManager.default.fileExists(
            atPath: source.worktreeRoot.appending(path: ".git").path
        )
        guard rootExists, isDirectory.boolValue, gitAuthorityExists else {
            throw BridgeDevelopmentProductHostError.invalidWorktree
        }
        guard case .workspace(let rootPath, let baseline)? = source.paneState.source else {
            throw BridgeDevelopmentProductHostError.invalidPaneSource
        }
        let restoredRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard restoredRoot.path == source.worktreeRoot.path,
            baseline?.contributionTarget != nil
        else {
            throw BridgeDevelopmentProductHostError.invalidPaneSource
        }
        return source
    }

    static func reviewTarget(
        from paneState: BridgePaneState
    ) throws -> WorkspaceReviewContributionTarget {
        guard case .workspace(_, let baseline)? = paneState.source,
            let reviewTarget = baseline?.contributionTarget
        else {
            throw BridgeDevelopmentProductHostError.invalidContributionTarget
        }
        return reviewTarget
    }

    private static func label(for target: WorkspaceReviewContributionTarget) -> String {
        switch target {
        case .localDefaultBranch(let branchName, _):
            branchName
        case .branch(let name, _):
            name
        case .originDefaultBranch(let remoteName, let branchName, _):
            "\(remoteName)/\(branchName)"
        case .commit(let oid):
            oid
        case .ref(let name, _):
            name
        }
    }
}

@MainActor
final class BridgeDevelopmentProductCommittedCallTarget {
    weak var host: BridgeDevelopmentProductHost?

    func applyReviewComparisonUpdate(
        _ request: BridgeProductReviewComparisonUpdateRequest,
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        _ = await host?.applyCommittedReviewComparisonUpdate(
            request,
            workerDerivationEpoch: workerDerivationEpoch,
            productAdmission: productAdmission
        )
    }

    func applyFileRefreshRetry(productAdmission: BridgeProductAdmissionContext) async {
        guard (productAdmission.withValidAdmission { true }) == true else { return }
        await host?.retryUnavailableFileRefresh(productAdmission: productAdmission)
    }

    func applyActiveViewerModeUpdate(
        _ call: BridgeProductCallRequest,
        correlation _: BridgeProductControlCorrelation,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        await host?.applyCommittedActiveViewerModeUpdate(call, productAdmission: productAdmission)
    }
}

extension BridgeDevelopmentProductHost {
    private func validateBootstrapTransition(
        _ request: BridgeDevelopmentProductBootstrapRequest,
        predecessor: BridgeProductInstallationFenceSnapshot,
        authorization: BridgeDevelopmentBootstrapAuthorizationSnapshot
    ) async throws {
        switch request.reason {
        case .initial:
            if let owningTabId, owningTabId != request.tabId,
                let installation = predecessor.installation
            {
                guard
                    await productSessionOwner.schemeRouter.closeTerminatedInstallation(
                        installation, authorization: authorization, projection: bootstrapAuthorizationProjection)
                else {
                    throw BridgeDevelopmentProductHostError.sessionAlreadyOpen
                }
            }
        case .workerReplacement:
            guard owningTabId == request.tabId else {
                throw BridgeDevelopmentProductHostError.sessionAlreadyOpen
            }
            guard request.paneSessionId == paneSessionId else {
                throw BridgeDevelopmentProductHostError.replacementPaneNotFound
            }
            guard request.navigationIntent == navigationIntent else {
                throw BridgeDevelopmentProductHostError.replacementNavigationChanged
            }
        }
    }

    func retryUnavailableFileRefresh(productAdmission: BridgeProductAdmissionContext) async {
        guard !isShutdown else { return }
        await MainActor.run {
            worktreeRefreshDriver.retryUnavailableFileRefresh(ifAdmittedBy: productAdmission)
        }
    }
}
