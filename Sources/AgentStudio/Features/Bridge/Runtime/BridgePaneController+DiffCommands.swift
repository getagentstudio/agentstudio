import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import os.log

private let bridgeDiffCommandLogger = Logger(subsystem: "com.agentstudio", category: "BridgeDiffCommands")

@MainActor
extension BridgePaneController: BridgeRuntimeCommandHandling {
    /// Bootstraps the review package for any workspace-backed Bridge pane, not
    /// only `.diffViewer` panes. A pane hosts both viewer modes in one webview
    /// and the browser can switch into review mode regardless of the pane's
    /// fixed `panelKind`; the review viewer is intake-only and never requests
    /// the package itself, so a `.fileViewer` pane that skipped this load would
    /// show a blank review surface on switch.
    func loadInitialReviewPackageIfPossible(
        correlationId: UUID?,
        reviewAuthorityGeneration: UInt64? = nil
    ) async -> ActionResult? {
        guard case .workspace = bridgePaneState.source,
            let worktreeId = runtime.metadata.worktreeId,
            paneState.diff.status == .idle || paneState.diff.status == .loading
                || paneState.diff.status == .error,
            paneState.diff.packageMetadata == nil
        else {
            return nil
        }

        return await loadReviewPackage(
            worktreeId: worktreeId,
            correlationId: correlationId,
            reviewAuthorityGeneration: reviewAuthorityGeneration
                ?? refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
        )
    }

    package func handleDiffCommand(
        _ command: DiffCommand,
        commandId: UUID,
        correlationId: UUID?
    ) async -> ActionResult {
        switch command {
        case .loadDiff:
            supersedePendingExplicitReviewCommandForNewIntent()
            refreshAdmissionCoordinator.advanceAuthority(for: .review)
            retireActiveReviewRefreshTask()
        }
        return await executeDiffCommand(
            command,
            commandId: commandId,
            correlationId: correlationId,
            reviewAuthorityGeneration: refreshAdmissionCoordinator.currentAuthorityGeneration(
                for: .review
            )
        )
    }

    private func executeDiffCommand(
        _ command: DiffCommand,
        commandId: UUID,
        correlationId: UUID?,
        reviewAuthorityGeneration: UInt64
    ) async -> ActionResult {
        guard let foregroundWorkAdmission = refreshAdmissionCoordinator.acquireForegroundWork(),
            let paneAdmission = productAdmissionGate.acquire(),
            let installation = productSessionOwner.installationFenceProjection.snapshot.installation,
            let productAdmission = paneAdmission.withInstallation(installation.gate)
        else {
            return .failure(.invalidPayload(description: "Bridge pane is closed"))
        }
        switch command {
        case .loadDiff(let artifact):
            return await handleLoadDiffCommand(
                artifact: artifact,
                commandId: commandId,
                correlationId: correlationId,
                admissions: ExplicitReviewLoadAdmissions(
                    paneAdmission: paneAdmission,
                    installationAdmission: productAdmission
                ),
                foregroundWorkAdmission: foregroundWorkAdmission,
                reviewAuthorityGeneration: reviewAuthorityGeneration
            )
        }
    }

    /// Keeps pane command authority distinct from current-installation Review authority.
    struct ExplicitReviewLoadAdmissions: Sendable {
        let paneAdmission: BridgeProductAdmissionContext
        let installationAdmission: BridgeProductAdmissionContext
    }

    struct ReviewPackageLoadReset {
        let buildReason: BridgeReviewPackageBuildReason
        let reviewAuthorityGeneration: UInt64
        let reviewGeneration: BridgeReviewGeneration
        let shouldPresentComparisonReplacement: Bool
    }

    var hasCurrentReviewPackageLoad: Bool {
        activeReviewPackageLoad?.reviewAuthorityGeneration
            == refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
    }

    func finishReviewPackageLoadAttempt(_ reset: ReviewPackageLoadReset) {
        guard activeReviewPackageLoad?.reviewGeneration == reset.reviewGeneration,
            activeReviewPackageLoad?.reviewAuthorityGeneration == reset.reviewAuthorityGeneration
        else { return }
        activeReviewPackageLoad = nil
        // Authority supersession preserves dirty input. Its owner must resume it when
        // the full load ends, even when that load failed and retained a predecessor.
        scheduleRetainedReviewPackageBuildIfPossible()
        scheduleWorktreeProductCatchUpIfPossible()
    }

    struct ReviewPackageLoadCommit {
        let reset: ReviewPackageLoadReset
        let load: BridgeReviewPackageLoadData
        let summary: BridgeReviewPackageSummary
        let commandId: UUID
        let correlationId: UUID?
        let productAdmission: BridgeProductAdmissionContext
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let traceContext: BridgeTraceContext?
    }

    private func handleLoadDiffCommand(
        artifact: DiffArtifact,
        commandId: UUID,
        correlationId: UUID?,
        admissions: ExplicitReviewLoadAdmissions,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        reviewAuthorityGeneration: UInt64
    ) async -> ActionResult {
        if let deferredResult = await deferLoadDiffCommandIfPageModeRequiresIt(
            artifact: artifact,
            commandId: commandId,
            correlationId: correlationId,
            admissions: admissions,
            foregroundWorkAdmission: foregroundWorkAdmission,
            reviewAuthorityGeneration: reviewAuthorityGeneration
        ) {
            return deferredResult
        }

        let execution = await performExplicitReviewPackageLoad(
            artifact: artifact,
            commandId: commandId,
            correlationId: correlationId,
            productAdmission: admissions.installationAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            reviewAuthorityGeneration: reviewAuthorityGeneration
        )
        switch execution {
        case .completed(let result):
            return result
        case .awaitingPageMode:
            assertionFailure("A direct explicit load must be deferred before package work begins")
            return .failure(.invalidPayload(description: "Stale bridge review load"))
        }
    }

    func providerUnavailableReviewPackageLoadResult(
        reset: ReviewPackageLoadReset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> ActionResult {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
            retainReviewPackageBuildReasonIfCurrent(reset: reset, productAdmission: productAdmission)
            return .failure(.invalidPayload(description: "Stale bridge review load"))
        }
        guard
            await retainCommittedReviewOrSetInitialFailure(
                "providerUnavailable",
                reset: reset,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else {
            return .failure(.invalidPayload(description: "Bridge pane is closed"))
        }
        return .failure(.backendUnavailable(backend: "BridgeReviewSourceProvider"))
    }

    private func deferLoadDiffCommandIfPageModeRequiresIt(
        artifact: DiffArtifact,
        commandId: UUID,
        correlationId: UUID?,
        admissions: ExplicitReviewLoadAdmissions,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        reviewAuthorityGeneration: UInt64
    ) async -> ActionResult? {
        let productAdmission = admissions.installationAdmission
        let pageModeAdmission = reviewPageModeAdmissionDisposition(
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
        switch pageModeAdmission {
        case .reviewShown:
            return nil
        case .modeUnknown:
            return await deferExplicitReviewLoadUntilPageModeIsAccepted(
                artifact: artifact,
                commandId: commandId,
                correlationId: correlationId,
                admissions: admissions,
                foregroundWorkAdmission: foregroundWorkAdmission,
                reviewAuthorityGeneration: reviewAuthorityGeneration
            )
        case .hidden:
            recordReviewBuildAdmissionFact(
                .deferredHidden(input: .explicitTarget),
                scope: .hiddenInput(.explicitTarget)
            )
            return await deferExplicitReviewLoadUntilPageModeIsAccepted(
                artifact: artifact,
                commandId: commandId,
                correlationId: correlationId,
                admissions: admissions,
                foregroundWorkAdmission: foregroundWorkAdmission,
                reviewAuthorityGeneration: reviewAuthorityGeneration
            )
        case .closed:
            return .failure(.invalidPayload(description: "Bridge pane is closed"))
        }
    }

    func completeReviewPackageLoad(
        _ commit: ReviewPackageLoadCommit
    ) async -> ActionResult {
        guard
            case .committed(let deliveryDisposition) =
                await commitReviewPackageLoadAndPublishDiffLoaded(commit)
        else {
            // Teardown closes E1 and clears page visibility; classify retirement before hidden.
            guard
                let reviewIsShown = commit.productAdmission.withValidAdmission({
                    isReviewShownByPage
                })
            else {
                return .failure(.invalidPayload(description: "Bridge pane is closed"))
            }
            if !reviewIsShown {
                retainReviewPackageBuildReasonIfCurrent(
                    reset: commit.reset,
                    productAdmission: commit.productAdmission
                )
                return .failure(.invalidPayload(description: "Stale bridge review load"))
            }
            if commit.foregroundWorkAdmission.withValidAdmission({ true }) == nil {
                retainReviewPackageBuildReasonIfCurrent(
                    reset: commit.reset,
                    productAdmission: commit.productAdmission
                )
            }
            guard
                await retainCommittedReviewOrSetInitialFailure(
                    "loadFailed:publication",
                    reset: commit.reset,
                    productAdmission: commit.productAdmission,
                    foregroundWorkAdmission: commit.foregroundWorkAdmission
                )
            else {
                return .failure(.invalidPayload(description: "Bridge pane is closed"))
            }
            return .failure(.invalidPayload(description: "Failed to load bridge review package"))
        }
        let deliveryFact: BridgePaneReviewPackageDeliveryFact
        switch deliveryDisposition {
        case .deferred:
            deliveryFact = .deferred
        case .failed:
            deliveryFact = .failed
        case .viewBatchSealed:
            deliveryFact = .viewBatchSealed
        }
        recordReviewBuildAdmissionFact(
            .explicitReviewPackageDelivery(
                commandId: commit.commandId,
                disposition: deliveryFact
            ),
            scope: .pendingExplicitCommand(commit.commandId)
        )
        if deliveryDisposition == .failed {
            await productSchemeProvider?.resetCurrentReviewSubscriptionsForUnavailableSource(
                productAdmission: commit.productAdmission,
                foregroundWorkAdmission: commit.foregroundWorkAdmission
            )
        }
        return .success(commandId: commit.commandId)
    }

    func reviewPackageLoadFailureResult(
        for error: any Error,
        reset: ReviewPackageLoadReset,
        reviewLoadStage: String,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> ActionResult {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
            retainReviewPackageBuildReasonIfCurrent(reset: reset, productAdmission: productAdmission)
            return .failure(.invalidPayload(description: "Stale bridge review load"))
        }
        let failureSummary = Self.reviewPackageLoadFailureSummary(for: error, stage: reviewLoadStage)
        bridgeDiffCommandLogger.error(
            "Bridge review package load failed: \(failureSummary, privacy: .public)"
        )
        guard
            await retainCommittedReviewOrSetInitialFailure(
                failureSummary,
                reset: reset,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else {
            return .failure(.invalidPayload(description: "Bridge pane is closed"))
        }
        return .failure(.invalidPayload(description: "Failed to load bridge review package"))
    }

    func acceptReviewPackageLoadResult(
        reset: ReviewPackageLoadReset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        packageTraceContext: BridgeTraceContext?
    ) -> Bool {
        guard productAdmission.withValidAdmission({ isReviewShownByPage }) == true else { return false }
        return foregroundWorkAdmission.withValidAdmission {
            productAdmission.withValidAdmission {
                guard isReviewShownByPage,
                    reset.reviewGeneration == nextReviewGeneration,
                    reset.reviewAuthorityGeneration
                        == refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
                else { return false }
                lastReviewPackageTraceContext = packageTraceContext
                return true
            }
        }.flatMap { $0 } == true
    }

    func isReviewPackageLoadCurrent(
        reset: ReviewPackageLoadReset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> Bool {
        guard productAdmission.withValidAdmission({ isReviewShownByPage }) == true else { return false }
        return foregroundWorkAdmission.withValidAdmission {
            productAdmission.withValidAdmission {
                isReviewShownByPage
                    && reset.reviewGeneration == nextReviewGeneration
                    && reset.reviewAuthorityGeneration
                        == refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
            }
        }.flatMap { $0 } == true
    }

    private func commitReviewPackageLoadAndPublishDiffLoaded(
        _ request: ReviewPackageLoadCommit
    ) async -> BridgeReviewPackageLoadCommitDisposition {
        guard request.productAdmission.withValidAdmission({ isReviewShownByPage }) == true else {
            return .rejected
        }
        let commitDisposition = await commitReviewPackageLoad(
            request.load,
            expectedReviewGeneration: request.reset.reviewGeneration,
            expectedReviewAuthorityGeneration: request.reset.reviewAuthorityGeneration,
            productAdmission: request.productAdmission,
            traceContext: request.traceContext,
            foregroundWorkAdmission: request.foregroundWorkAdmission
        )
        guard case .committed = commitDisposition else { return .rejected }
        let didPublishDiffLoaded =
            request.foregroundWorkAdmission.withValidAdmission {
                request.productAdmission.withValidAdmission {
                    ingestRuntimeEvent(
                        .diff(.diffLoaded(stats: Self.diffStats(from: request.summary))),
                        commandId: request.commandId,
                        correlationId: request.correlationId
                    )
                    return true
                }
            }.flatMap { $0 } == true
        return didPublishDiffLoaded ? commitDisposition : .rejected
    }

    func beginReviewPackageLoad(
        artifact: DiffArtifact,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        reviewAuthorityGeneration: UInt64
    ) async -> ReviewPackageLoadReset? {
        guard
            reviewAuthorityGeneration
                == refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
        else { return nil }
        guard
            let reset = foregroundWorkAdmission.withValidAdmission({
                productAdmission.withValidAdmission {
                    let buildReason = consumePendingReviewPackageBuildReason(default: .initialIntake)
                    let shouldPresentComparisonReplacement =
                        buildReason == .initialIntake || pendingComparisonReviewGeneration != nil
                    if reviewPublicationCoordinator.diagnosticSnapshot.active == nil {
                        paneState.diff.setStatus(.loading)
                    }
                    paneState.diff.advanceEpoch()
                    let reviewGeneration =
                        pendingComparisonReviewGeneration
                        ?? nextReviewGeneration.next()
                    pendingComparisonReviewGeneration = nil
                    nextReviewGeneration = reviewGeneration
                    let reset = ReviewPackageLoadReset(
                        buildReason: buildReason,
                        reviewAuthorityGeneration: reviewAuthorityGeneration,
                        reviewGeneration: reviewGeneration,
                        shouldPresentComparisonReplacement: shouldPresentComparisonReplacement
                    )
                    activeReviewPackageLoad = reset
                    return reset
                }
            }).flatMap({ $0 })
        else {
            return nil
        }
        if reset.shouldPresentComparisonReplacement,
            case .workspace(_, let baseline) = bridgePaneState.source,
            let activeTarget = baseline?.contributionTarget
        {
            refreshAdmissionCoordinator.beginReviewComparisonAttempt(
                activeTarget: activeTarget,
                reviewGeneration: reset.reviewGeneration.rawValue
            )
            // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
            _ = scheduleProductPresentationPublication()
        }
        return reset
    }

    func loadReviewPackageResult(
        artifact: DiffArtifact,
        reset: ReviewPackageLoadReset,
        reviewLoadStage: inout String,
        packageTraceContext: BridgeTraceContext?
    ) async throws -> BridgeReviewPackageConstructionResult {
        let unresolvedRequest = makeReviewPipelineRequest(
            artifact: artifact,
            reviewGeneration: reset.reviewGeneration,
            reviewAttemptAuthorityGeneration: reset.reviewAuthorityGeneration
        )
        let packageBuildStart = ContinuousClock.now
        let constructionResult: BridgeReviewPackageConstructionResult
        reviewLoadStage = "package"
        constructionResult = try await acquireReviewPackage(unresolvedRequest)
        await recordSwiftTelemetry(
            name: "performance.bridge.swift.package_build",
            phase: "package_build",
            priorityHint: .cold,
            traceContext: packageTraceContext,
            stringAttributes: [
                "agentstudio.bridge.package_build.reason": reset.buildReason.rawValue
            ],
            durationMilliseconds: AgentStudioPerformanceTraceRecorder.milliseconds(
                from: packageBuildStart.duration(to: ContinuousClock.now)
            )
        )
        return constructionResult
    }

    func makeReviewPackageLoadData(
        constructionResult: BridgeReviewPackageConstructionResult,
        contentHandles: [BridgeContentHandle],
        productAdmission: BridgeProductAdmissionContext,
        fallbackRevision: Int? = nil,
        reviewLoadStage: inout String,
        packageTraceContext: BridgeTraceContext?
    ) async throws -> BridgeReviewPackageLoadData {
        let result = constructionResult.result
        let deltaBuildStart = ContinuousClock.now
        reviewLoadStage = "delta"
        let changeIndexLoad: BridgeChangeIndexPreparedLoad
        do {
            changeIndexLoad = try await reviewChangeIndex.prepareExplicitLoad(
                result.package,
                fallbackRevision: fallbackRevision,
                productAdmission: productAdmission
            )
        } catch {
            await constructionResult.releaseArtifactPin()
            throw error
        }
        await recordSwiftTelemetry(
            name: "performance.bridge.swift.delta_build",
            phase: "delta_build",
            priorityHint: .warm,
            traceContext: makeChildTraceContext(parent: packageTraceContext),
            durationMilliseconds: AgentStudioPerformanceTraceRecorder.milliseconds(
                from: deltaBuildStart.duration(to: ContinuousClock.now)
            )
        )
        reviewLoadStage = "publicationPrepare"
        guard
            let preparedPublication = await BridgeReviewPreparedPublication.prepare(
                BridgeReviewPublicationCandidate(
                    package: changeIndexLoad.package,
                    delta: changeIndexLoad.delta,
                    contentHandles: contentHandles,
                    artifactPin: constructionResult.artifactPin
                )
            )
        else {
            await constructionResult.releaseArtifactPin()
            throw BridgeProviderFailure.providerFailed(
                message: "Invalid bridge Review publication candidate"
            )
        }
        guard productAdmission.withValidAdmission({ true }) == true else {
            await constructionResult.releaseArtifactPin()
            throw BridgeChangeIndexError.admissionClosed
        }
        return BridgeReviewPackageLoadData(
            preparedPublication: preparedPublication,
            changeIndexLoad: changeIndexLoad
        )
    }

    func recordReviewContentRegisterTelemetry(
        traceContext: BridgeTraceContext?,
        contentRegisterStart: ContinuousClock.Instant
    ) async {
        await recordSwiftTelemetry(
            name: "performance.bridge.swift.content_register",
            phase: "content_register",
            priorityHint: .cold,
            traceContext: makeChildTraceContext(parent: traceContext),
            durationMilliseconds: AgentStudioPerformanceTraceRecorder.milliseconds(
                from: contentRegisterStart.duration(to: ContinuousClock.now)
            )
        )
    }

    func loadReviewPackage(
        worktreeId: UUID,
        correlationId: UUID?,
        reviewAuthorityGeneration: UInt64
    ) async -> ActionResult {
        let commandId = UUIDv7.generate()
        return await executeDiffCommand(
            .loadDiff(
                DiffArtifact(
                    diffId: UUIDv7.generate(),
                    worktreeId: worktreeId,
                    patchData: Data()
                )
            ),
            commandId: commandId,
            correlationId: correlationId,
            reviewAuthorityGeneration: reviewAuthorityGeneration
        )
    }

    func handlePaneFilesystemContextEvent(_ event: PaneFilesystemContextEvent) async {
        guard shouldRefreshReviewPackage(for: event) else { return }
        switch event {
        case .cwdSubtreeChanged(let context, let paths, let batchSequence):
            await handleWorktreeProductInvalidation(
                .filesChanged(
                    FileChangeset(
                        worktreeId: context.worktreeId,
                        repoId: context.repoId,
                        rootPath: context.cwd,
                        paths: Array(paths),
                        timestamp: .now,
                        batchSeq: batchSequence
                    )
                )
            )
        case .gitWorkingTreeInCwd(_, let staged, let unstaged, let untracked):
            await handleWorktreeProductInvalidation(
                .statusChanged(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(
                            changed: unstaged,
                            staged: staged,
                            untracked: untracked
                        ),
                        branch: nil,
                        origin: nil
                    )
                )
            )
        }
    }

    func refreshCurrentReviewPackage(
        reservation: BridgePaneRefreshCatchUpReservation,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgePaneRefreshCatchUpOutcome {
        guard productAdmission.withValidAdmission({ isReviewShownByPage }) == true,
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            refreshAdmissionCoordinator.isRefreshPassCurrent(reservation)
        else { return .stale }
        guard
            let currentPublication = reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        else {
            guard paneState.diff.status == .error || paneState.diff.status == .loading else { return .succeeded }
            guard
                let result = await loadInitialReviewPackageIfPossible(
                    correlationId: nil,
                    reviewAuthorityGeneration: reservation.authorityGeneration
                )
            else { return .stale }
            if case .success = result { return .succeeded }
            guard !Task.isCancelled,
                foregroundWorkAdmission.withValidAdmission({ true }) == true,
                refreshAdmissionCoordinator.isRefreshPassCurrent(reservation)
            else { return .stale }
            return .failed
        }
        let currentPackage = currentPublication.package
        guard
            let refreshGeneration = beginReviewPackageRefresh(
                currentPackage: currentPackage,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else {
            return .stale
        }
        do {
            _ = try await resolveAndPublishReviewComparisonDefaultTargetIfCurrent(
                reset: ReviewPackageLoadReset(
                    buildReason: .filesystemRefresh,
                    reviewAuthorityGeneration: reservation.authorityGeneration,
                    reviewGeneration: refreshGeneration,
                    shouldPresentComparisonReplacement: false
                ),
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        } catch is CancellationError {
            return failCurrentReviewComparisonRefresh(
                refreshGeneration,
                failureKind: Self.reviewPackageLoadFailureSummary(
                    for: CancellationError(),
                    stage: "package"
                ),
                reservation: reservation,
                foregroundWorkAdmission: foregroundWorkAdmission,
                productAdmission: productAdmission
            )
        } catch {
            return failCurrentReviewComparisonRefresh(
                refreshGeneration,
                failureKind: "defaultTargetUnavailable",
                reservation: reservation,
                foregroundWorkAdmission: foregroundWorkAdmission,
                productAdmission: productAdmission
            )
        }
        return await performReviewPackageRefresh(
            currentPublication: currentPublication,
            refreshGeneration: refreshGeneration,
            foregroundWorkAdmission: foregroundWorkAdmission,
            productAdmission: productAdmission,
            reservation: reservation
        )
    }

    private func performReviewPackageRefresh(
        currentPublication: BridgeReviewCommittedPublication,
        refreshGeneration: BridgeReviewGeneration,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        productAdmission: BridgeProductAdmissionContext,
        reservation: BridgePaneRefreshCatchUpReservation
    ) async -> BridgePaneRefreshCatchUpOutcome {
        let currentPackage = currentPublication.package
        do {
            let (constructionResult, packageTraceContext) = try await loadReviewPackageForRefresh(
                currentPackage,
                reviewGeneration: refreshGeneration,
                reservation: reservation
            )
            let result = constructionResult.result
            guard
                admitPreparedReviewPackageRefresh(
                    currentPublication: currentPublication,
                    refreshGeneration: refreshGeneration,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    productAdmission: productAdmission,
                    reservation: reservation,
                    packageTraceContext: packageTraceContext
                )
            else {
                await constructionResult.releaseArtifactPin()
                return .stale
            }

            var reviewLoadStage = "delta"
            let preparedLoad = try await makeReviewPackageLoadData(
                constructionResult: constructionResult,
                contentHandles: result.registeredContentHandles,
                productAdmission: productAdmission,
                fallbackRevision: currentPackage.revision,
                reviewLoadStage: &reviewLoadStage,
                packageTraceContext: packageTraceContext
            )
            guard
                productAdmission.withValidAdmission({ isReviewShownByPage }) == true,
                !Task.isCancelled,
                foregroundWorkAdmission.withValidAdmission({ true }) == true,
                refreshAdmissionCoordinator.isRefreshPassCurrent(reservation),
                refreshGeneration == nextReviewGeneration,
                reviewPublicationCoordinator.isCurrentPublication(
                    publicationId: currentPublication.publicationId,
                    productAdmission: productAdmission
                )
            else {
                await preparedLoad.releaseArtifactPin()
                return .stale
            }
            reviewGitRefreshSeedHolder.commit(result.gitRefreshSeed)
            guard !Self.isUnchangedSameLineageLoad(preparedLoad, currentPublication: currentPublication)
            else {
                await preparedLoad.releaseArtifactPin()
                settleReviewComparisonAttempt(
                    reviewGeneration: refreshGeneration,
                    package: currentPackage
                )
                return .succeeded
            }
            guard
                let load = try await classifyReviewPackageRefresh(
                    preparedLoad,
                    currentPublication: currentPublication,
                    refreshGeneration: refreshGeneration,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    productAdmission: productAdmission,
                    reservation: reservation
                )
            else {
                await preparedLoad.releaseArtifactPin()
                return .stale
            }
            return await commitClassifiedReviewPackageRefresh(
                load,
                refreshGeneration: refreshGeneration,
                reservation: reservation,
                productAdmission: productAdmission,
                packageTraceContext: packageTraceContext,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        } catch {
            bridgeDiffCommandLogger.debug(
                "Skipped bridge review refresh: \(String(describing: error), privacy: .private)"
            )
            return failCurrentReviewComparisonRefresh(
                refreshGeneration,
                failureKind: Self.reviewPackageRefreshFailureKind(for: error),
                reservation: reservation,
                foregroundWorkAdmission: foregroundWorkAdmission,
                productAdmission: productAdmission
            )
        }
    }

    private func settleReviewComparisonAttempt(
        reviewGeneration: BridgeReviewGeneration,
        package: BridgeReviewPackage
    ) {
        refreshAdmissionCoordinator.settleReviewComparisonAttempt(
            reviewGeneration: reviewGeneration.rawValue,
            displayedSnapshotIdentity: BridgePaneReviewDisplayedSnapshotIdentity(
                packageId: package.packageId,
                reviewGeneration: package.reviewGeneration.rawValue,
                revision: package.revision
            )
        )
        // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
        _ = scheduleProductPresentationPublication()
    }

    private func beginReviewPackageRefresh(
        currentPackage: BridgeReviewPackage,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> BridgeReviewGeneration? {
        foregroundWorkAdmission.withValidAdmission {
            productAdmission.withValidAdmission { () -> BridgeReviewGeneration? in
                guard pendingComparisonReviewGeneration == nil,
                    !hasCurrentReviewPackageLoad,
                    nextReviewGeneration >= currentPackage.reviewGeneration
                else { return nil }
                // Ordinary refresh stays in its lineage so delta and unchanged-load
                // handling remain incremental. A failed full load leaves a monotonic
                // allocation gap; replace the retained package beyond that attempt.
                if nextReviewGeneration == currentPackage.reviewGeneration {
                    return currentPackage.reviewGeneration
                }
                nextReviewGeneration = nextReviewGeneration.next()
                return nextReviewGeneration
            }
        }.flatMap { $0 }.flatMap { $0 }
    }

    private static func isUnchangedSameLineageLoad(
        _ load: BridgeReviewPackageLoadData,
        currentPublication: BridgeReviewCommittedPublication
    ) -> Bool {
        let currentPackage = currentPublication.package
        return load.delta == nil
            && load.package.revision == currentPackage.revision
            && load.package.hasSameReviewTruth(as: currentPackage)
    }

    private func retainCommittedReviewOrSetInitialFailure(
        _ failureSummary: String,
        reset: ReviewPackageLoadReset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> Bool {
        let failureDisposition =
            foregroundWorkAdmission.withValidAdmission {
                productAdmission.withValidAdmission {
                    guard reset.reviewGeneration == nextReviewGeneration,
                        reset.reviewAuthorityGeneration
                            == refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
                    else {
                        return (accepted: false, isInitial: false)
                    }
                    guard reviewPublicationCoordinator.diagnosticSnapshot.active == nil else {
                        return (accepted: true, isInitial: false)
                    }
                    paneState.diff.setStatus(.error, error: failureSummary)
                    return (accepted: true, isInitial: true)
                } ?? (accepted: false, isInitial: false)
            } ?? (accepted: false, isInitial: false)
        guard failureDisposition.accepted else { return false }
        failReviewComparisonAttempt(
            reviewGeneration: reset.reviewGeneration,
            failureKind: failureSummary,
            retryable: true
        )
        if failureDisposition.isInitial {
            await productSchemeProvider?.resetCurrentReviewSubscriptionsForUnavailableSource(
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        }
        return true
    }

}
