import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

enum BridgeReviewPageModeAdmissionDisposition {
    case reviewShown
    case modeUnknown
    case hidden
    case closed
}

enum BridgePendingExplicitReviewCommandExecutionResult {
    case awaitingPageMode
    case completed(ActionResult)
}

private enum BridgeExplicitReviewPackageLoadEntryPoint {
    case directCommand
    case resumedCommand
}

private struct BridgeExplicitReviewPackageLoadRequest {
    let artifact: DiffArtifact
    let commandId: UUID
    let correlationId: UUID?
    let productAdmission: BridgeProductAdmissionContext
    let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    let reviewAuthorityGeneration: UInt64
    let entryPoint: BridgeExplicitReviewPackageLoadEntryPoint
}

private enum BridgeExplicitReviewPackageLoadPreparation {
    case ready(BridgePaneController.ReviewPackageLoadCommit)
    case completed(ActionResult)
}

@MainActor
final class BridgePendingExplicitReviewCommand {
    let artifact: DiffArtifact
    let commandId: UUID
    let correlationId: UUID?
    let productAdmission: BridgeProductAdmissionContext
    let installationAdmission: BridgeProductAdmissionContext
    let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    let reviewAuthorityGeneration: UInt64

    private let continuation: CheckedContinuation<ActionResult, Never>
    private var closeObservation: BridgeProductAdmissionCloseObservation?
    private(set) var hasStartedResumption = false
    private(set) var isSettled = false

    init(
        artifact: DiffArtifact,
        commandId: UUID,
        correlationId: UUID?,
        productAdmission: BridgeProductAdmissionContext,
        installationAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        reviewAuthorityGeneration: UInt64,
        continuation: CheckedContinuation<ActionResult, Never>
    ) {
        self.artifact = artifact
        self.commandId = commandId
        self.correlationId = correlationId
        self.productAdmission = productAdmission
        self.installationAdmission = installationAdmission
        self.foregroundWorkAdmission = foregroundWorkAdmission
        self.reviewAuthorityGeneration = reviewAuthorityGeneration
        self.continuation = continuation
    }

    func installCloseObservation(_ observation: BridgeProductAdmissionCloseObservation) {
        guard !isSettled else {
            observation.cancel()
            return
        }
        closeObservation = observation
    }

    func beginResumption() -> Bool {
        guard !isSettled, !hasStartedResumption else { return false }
        hasStartedResumption = true
        return true
    }

    func returnToPageModeWait() -> Bool {
        guard !isSettled, hasStartedResumption else { return false }
        hasStartedResumption = false
        return true
    }

    func settle(_ result: ActionResult) -> Bool {
        guard !isSettled else { return false }
        isSettled = true
        closeObservation?.cancel()
        closeObservation = nil
        continuation.resume(returning: result)
        return true
    }
}

@MainActor
extension BridgePaneController {
    func reviewPageModeAdmissionDisposition(
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> BridgeReviewPageModeAdmissionDisposition {
        foregroundWorkAdmission.withValidAdmission {
            productAdmission.withValidAdmission {
                switch activeViewerModeSignalState.acceptedMode {
                case .review: .reviewShown
                case .file: .hidden
                case nil: .modeUnknown
                }
            }
        }.flatMap { $0 } ?? .closed
    }

    var hasPendingOrResumingExplicitReviewCommand: Bool {
        pendingExplicitReviewCommand != nil || hasResumingExplicitReviewCommand
    }

    var hasResumingExplicitReviewCommand: Bool {
        resumingExplicitReviewCommandsById.values.contains { !$0.isSettled }
    }

    func deferExplicitReviewLoadUntilPageModeIsAccepted(
        artifact: DiffArtifact,
        commandId: UUID,
        correlationId: UUID?,
        admissions: ExplicitReviewLoadAdmissions,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        reviewAuthorityGeneration: UInt64
    ) async -> ActionResult {
        guard admissions.paneAdmission.withValidAdmission({ true }) == true,
            admissions.installationAdmission.withValidAdmission({ true }) == true
        else {
            return Self.closedExplicitReviewCommandResult()
        }
        deferExplicitReviewLoadReason()
        return await withCheckedContinuation { continuation in
            let pendingCommand = BridgePendingExplicitReviewCommand(
                artifact: artifact,
                commandId: commandId,
                correlationId: correlationId,
                productAdmission: admissions.paneAdmission,
                installationAdmission: admissions.installationAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                reviewAuthorityGeneration: reviewAuthorityGeneration,
                continuation: continuation
            )
            if let existingCommand = pendingExplicitReviewCommand {
                finishPendingExplicitReviewCommand(
                    existingCommand,
                    result: Self.supersededExplicitReviewCommandResult(),
                    outcome: .superseded
                )
            }
            pendingExplicitReviewCommand = pendingCommand
            recordReviewBuildAdmissionFact(
                .pendingExplicitCommandAwaitingPageMode(commandId: commandId),
                scope: .pendingExplicitCommand(commandId)
            )
            pendingCommand.installCloseObservation(
                admissions.installationAdmission.observeClose { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.retirePendingExplicitReviewCommand(commandId: commandId)
                    }
                }
            )
            guard admissions.installationAdmission.withValidAdmission({ true }) == true else {
                finishPendingExplicitReviewCommand(
                    pendingCommand,
                    result: Self.closedExplicitReviewCommandResult(),
                    outcome: .retired
                )
                return
            }
        }
    }

    /// Returns true when a pending or already-resuming explicit command owns this Review transition.
    func resumePendingExplicitReviewCommandIfPossible() -> Bool {
        guard let pendingCommand = pendingExplicitReviewCommand else {
            return resumingExplicitReviewCommandsById.values.contains { !$0.isSettled }
        }
        guard pendingCommand.productAdmission.withValidAdmission({ true }) == true,
            pendingCommand.installationAdmission.withValidAdmission({ true }) == true,
            pendingCommand.foregroundWorkAdmission.withValidAdmission({ true }) == true
        else {
            recordReviewBuildAdmissionFact(
                .pendingExplicitCommandResumptionPreflightRejected(commandId: pendingCommand.commandId),
                scope: .pendingExplicitCommand(pendingCommand.commandId)
            )
            finishPendingExplicitReviewCommand(
                pendingCommand,
                result: Self.closedExplicitReviewCommandResult(),
                outcome: .retired
            )
            return false
        }
        guard pendingCommand.beginResumption() else { return true }

        // Transfer the complete command and its waiter before the task can enter the resume path.
        pendingExplicitReviewCommand = nil
        resumingExplicitReviewCommandsById[pendingCommand.commandId] = pendingCommand
        let resumptionTask = Task { @MainActor [weak self, pendingCommand] in
            guard let self else {
                _ = pendingCommand.settle(Self.closedExplicitReviewCommandResult())
                return
            }
            await self.runExplicitReviewCommandResumption(pendingCommand)
        }
        resumingExplicitReviewCommandTasksById[pendingCommand.commandId] = resumptionTask
        recordReviewBuildAdmissionFact(
            .pendingExplicitCommandResumptionScheduled(commandId: pendingCommand.commandId),
            scope: .pendingExplicitCommand(pendingCommand.commandId)
        )
        return true
    }

    func supersedePendingExplicitReviewCommandForNewIntent() {
        var currentCommands: [BridgePendingExplicitReviewCommand] = []
        if let pendingExplicitReviewCommand {
            currentCommands.append(pendingExplicitReviewCommand)
        }
        currentCommands.append(contentsOf: resumingExplicitReviewCommandsById.values.filter { !$0.isSettled })

        for command in currentCommands {
            let result: ActionResult
            let outcome: BridgePanePendingExplicitReviewCommandOutcome
            if command.productAdmission.withValidAdmission({ true }) == true,
                command.installationAdmission.withValidAdmission({ true }) == true
            {
                result = Self.supersededExplicitReviewCommandResult()
                outcome = .superseded
            } else {
                result = Self.closedExplicitReviewCommandResult()
                outcome = .retired
            }
            finishPendingExplicitReviewCommand(command, result: result, outcome: outcome)
        }
    }

    func retirePendingExplicitReviewCommand(commandId: UUID? = nil) {
        var commandsToRetire: [BridgePendingExplicitReviewCommand] = []
        if let pendingExplicitReviewCommand,
            commandId == nil || pendingExplicitReviewCommand.commandId == commandId
        {
            commandsToRetire.append(pendingExplicitReviewCommand)
        }
        commandsToRetire.append(
            contentsOf: resumingExplicitReviewCommandsById.values.filter {
                !$0.isSettled && (commandId == nil || $0.commandId == commandId)
            })
        for command in commandsToRetire {
            finishPendingExplicitReviewCommand(
                command,
                result: Self.closedExplicitReviewCommandResult(),
                outcome: .retired
            )
        }
    }

    private func deferExplicitReviewLoadReason() {
        let reason: BridgeReviewPackageBuildReason
        if paneState.diff.packageMetadata == nil,
            pendingComparisonReviewGeneration == nil
        {
            reason = .initialIntake
        } else {
            reason = .productResync
        }
        pendingReviewPackageBuildReasons.insert(reason)
    }

    func performExplicitReviewPackageLoad(
        artifact: DiffArtifact,
        commandId: UUID,
        correlationId: UUID?,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        reviewAuthorityGeneration: UInt64
    ) async -> BridgePendingExplicitReviewCommandExecutionResult {
        await performExplicitReviewPackageLoad(
            BridgeExplicitReviewPackageLoadRequest(
                artifact: artifact,
                commandId: commandId,
                correlationId: correlationId,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                reviewAuthorityGeneration: reviewAuthorityGeneration,
                entryPoint: .directCommand
            )
        )
    }

    private func performResumedExplicitReviewPackageLoad(
        _ pendingCommand: BridgePendingExplicitReviewCommand,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgePendingExplicitReviewCommandExecutionResult {
        await performExplicitReviewPackageLoad(
            BridgeExplicitReviewPackageLoadRequest(
                artifact: pendingCommand.artifact,
                commandId: pendingCommand.commandId,
                correlationId: pendingCommand.correlationId,
                productAdmission: productAdmission,
                foregroundWorkAdmission: pendingCommand.foregroundWorkAdmission,
                reviewAuthorityGeneration: pendingCommand.reviewAuthorityGeneration,
                entryPoint: .resumedCommand
            )
        )
    }

    private func performExplicitReviewPackageLoad(
        _ request: BridgeExplicitReviewPackageLoadRequest
    ) async -> BridgePendingExplicitReviewCommandExecutionResult {
        let packageTraceContext = makeRootTraceContext()
        guard
            let reset = await beginReviewPackageLoad(
                artifact: request.artifact,
                productAdmission: request.productAdmission,
                foregroundWorkAdmission: request.foregroundWorkAdmission,
                reviewAuthorityGeneration: request.reviewAuthorityGeneration
            )
        else {
            return .completed(.failure(.invalidPayload(description: "Bridge pane is closed")))
        }
        defer { finishReviewPackageLoadAttempt(reset) }
        return await loadAndCommitExplicitReviewPackage(
            request,
            reset: reset,
            packageTraceContext: packageTraceContext
        )
    }

    private func loadAndCommitExplicitReviewPackage(
        _ request: BridgeExplicitReviewPackageLoadRequest,
        reset: ReviewPackageLoadReset,
        packageTraceContext: BridgeTraceContext?
    ) async -> BridgePendingExplicitReviewCommandExecutionResult {
        do {
            try await adoptInitialContributionTargetIfEligible(
                reset: reset,
                productAdmission: request.productAdmission,
                foregroundWorkAdmission: request.foregroundWorkAdmission
            )
            if case .resumedCommand = request.entryPoint {
                switch reviewPageModeAdmissionDisposition(
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission
                ) {
                case .reviewShown:
                    guard !Task.isCancelled else {
                        return .completed(Self.supersededExplicitReviewCommandResult())
                    }
                case .modeUnknown, .hidden:
                    deferExplicitReviewLoadReason()
                    return .awaitingPageMode
                case .closed:
                    return .completed(Self.closedExplicitReviewCommandResult())
                }
            }
            switch await prepareExplicitReviewPackageLoad(
                request,
                reset: reset,
                packageTraceContext: packageTraceContext
            ) {
            case .ready(let commit):
                return .completed(await completeReviewPackageLoad(commit))
            case .completed(let result):
                return .completed(result)
            }
        } catch BridgeProviderFailure.providerUnavailable {
            return .completed(
                await providerUnavailableReviewPackageLoadResult(
                    reset: reset,
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission
                )
            )
        } catch {
            if error is CancellationError, case .resumedCommand = request.entryPoint {
                return .completed(.failure(.invalidPayload(description: "Stale bridge review load")))
            }
            return .completed(
                await reviewPackageLoadFailureResult(
                    for: error,
                    reset: reset,
                    reviewLoadStage: "designation",
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission
                )
            )
        }
    }

    private func prepareExplicitReviewPackageLoad(
        _ request: BridgeExplicitReviewPackageLoadRequest,
        reset: ReviewPackageLoadReset,
        packageTraceContext: BridgeTraceContext?
    ) async -> BridgeExplicitReviewPackageLoadPreparation {
        var reviewLoadStage = "package"
        do {
            recordReviewBuildAdmissionFact(
                .explicitReviewPackageBuildStarted(commandId: request.commandId),
                scope: .pendingExplicitCommand(request.commandId)
            )
            if case .resumedCommand = request.entryPoint {
                recordReviewBuildAdmissionFact(
                    .pendingExplicitCommandBuildStarted(commandId: request.commandId),
                    scope: .pendingExplicitCommand(request.commandId)
                )
            }
            let constructionResult = try await loadReviewPackageResult(
                artifact: request.artifact,
                reset: reset,
                reviewLoadStage: &reviewLoadStage,
                packageTraceContext: packageTraceContext
            )
            let result = constructionResult.result
            guard
                acceptReviewPackageLoadResult(
                    reset: reset,
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission,
                    packageTraceContext: packageTraceContext
                )
            else {
                await constructionResult.releaseArtifactPin()
                retainReviewPackageBuildReasonIfCurrent(
                    reset: reset,
                    productAdmission: request.productAdmission
                )
                return .completed(.failure(.invalidPayload(description: "Stale bridge review load")))
            }
            let load = try await makeReviewPackageLoadData(
                constructionResult: constructionResult,
                contentHandles: result.registeredContentHandles,
                productAdmission: request.productAdmission,
                reviewLoadStage: &reviewLoadStage,
                packageTraceContext: packageTraceContext
            )
            let contentRegisterStart = ContinuousClock.now
            await recordReviewContentRegisterTelemetry(
                traceContext: packageTraceContext,
                contentRegisterStart: contentRegisterStart
            )
            guard
                isReviewPackageLoadCurrent(
                    reset: reset,
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission
                )
            else {
                await load.releaseArtifactPin()
                retainReviewPackageBuildReasonIfCurrent(
                    reset: reset,
                    productAdmission: request.productAdmission
                )
                return .completed(.failure(.invalidPayload(description: "Stale bridge review load")))
            }
            reviewGitRefreshSeedHolder.commit(result.gitRefreshSeed)
            return .ready(
                ReviewPackageLoadCommit(
                    reset: reset,
                    load: load,
                    summary: result.package.summary,
                    commandId: request.commandId,
                    correlationId: request.correlationId,
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission,
                    traceContext: packageTraceContext
                )
            )
        } catch BridgeProviderFailure.providerUnavailable {
            return .completed(
                await providerUnavailableReviewPackageLoadResult(
                    reset: reset,
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission
                )
            )
        } catch {
            if error is CancellationError, case .resumedCommand = request.entryPoint {
                return .completed(.failure(.invalidPayload(description: "Stale bridge review load")))
            }
            return .completed(
                await reviewPackageLoadFailureResult(
                    for: error,
                    reset: reset,
                    reviewLoadStage: reviewLoadStage,
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission
                )
            )
        }
    }

    private func resumePendingExplicitReviewPackageCommand(
        _ pendingCommand: BridgePendingExplicitReviewCommand,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgePendingExplicitReviewCommandExecutionResult {
        switch reviewPageModeAdmissionDisposition(
            productAdmission: productAdmission,
            foregroundWorkAdmission: pendingCommand.foregroundWorkAdmission
        ) {
        case .reviewShown:
            return await performResumedExplicitReviewPackageLoad(
                pendingCommand,
                productAdmission: productAdmission
            )
        case .modeUnknown, .hidden:
            return .awaitingPageMode
        case .closed:
            return .completed(Self.closedExplicitReviewCommandResult())
        }
    }

    private func finishPendingExplicitReviewCommand(
        _ pendingCommand: BridgePendingExplicitReviewCommand,
        result: ActionResult,
        outcome: BridgePanePendingExplicitReviewCommandOutcome
    ) {
        guard pendingCommand.settle(result) else { return }
        if pendingExplicitReviewCommand === pendingCommand {
            pendingExplicitReviewCommand = nil
        }
        if outcome != .completed {
            resumingExplicitReviewCommandTasksById[pendingCommand.commandId]?.cancel()
        }
        recordReviewBuildAdmissionFact(
            .pendingExplicitCommandEnded(commandId: pendingCommand.commandId, outcome: outcome),
            scope: .pendingExplicitCommand(pendingCommand.commandId)
        )
        guard outcome == .completed else { return }
        scheduleRetainedReviewPackageBuildIfPossible()
        scheduleWorktreeProductCatchUpIfPossible()
    }

    private func runExplicitReviewCommandResumption(
        _ pendingCommand: BridgePendingExplicitReviewCommand
    ) async {
        defer { finishExplicitReviewCommandResumption(pendingCommand) }
        guard resumingExplicitReviewCommandsById[pendingCommand.commandId] === pendingCommand,
            !pendingCommand.isSettled,
            !Task.isCancelled
        else { return }

        guard let installationAdmission = currentInstallationAdmission(for: pendingCommand) else {
            recordReviewBuildAdmissionFact(
                .pendingExplicitCommandResumptionAdmissionRejected(commandId: pendingCommand.commandId),
                scope: .pendingExplicitCommand(pendingCommand.commandId)
            )
            finishPendingExplicitReviewCommand(
                pendingCommand,
                result: Self.closedExplicitReviewCommandResult(),
                outcome: .retired
            )
            return
        }
        recordReviewBuildAdmissionFact(
            .pendingExplicitCommandResumptionAdmissionAcquired(commandId: pendingCommand.commandId),
            scope: .pendingExplicitCommand(pendingCommand.commandId)
        )
        let execution = await resumePendingExplicitReviewPackageCommand(
            pendingCommand,
            productAdmission: installationAdmission
        )
        guard !pendingCommand.isSettled else { return }
        guard pendingCommand.installationAdmission.withValidAdmission({ true }) == true else {
            finishPendingExplicitReviewCommand(
                pendingCommand,
                result: Self.closedExplicitReviewCommandResult(),
                outcome: .retired
            )
            return
        }
        switch execution {
        case .awaitingPageMode:
            returnExplicitReviewCommandToPageModeWait(pendingCommand)
        case .completed(let result):
            finishPendingExplicitReviewCommand(
                pendingCommand,
                result: result,
                outcome: .completed
            )
        }
    }

    private func currentInstallationAdmission(
        for pendingCommand: BridgePendingExplicitReviewCommand
    ) -> BridgeProductAdmissionContext? {
        guard let currentInstallation = productSessionOwner.installationFenceProjection.snapshot.installation,
            let currentAdmission = pendingCommand.productAdmission.withInstallation(currentInstallation.gate),
            pendingCommand.installationAdmission.matches(currentAdmission),
            currentAdmission.withValidAdmission({ true }) == true,
            pendingCommand.foregroundWorkAdmission.withValidAdmission({ true }) == true
        else { return nil }
        return currentAdmission
    }

    private func returnExplicitReviewCommandToPageModeWait(
        _ pendingCommand: BridgePendingExplicitReviewCommand
    ) {
        guard resumingExplicitReviewCommandsById[pendingCommand.commandId] === pendingCommand,
            pendingCommand.returnToPageModeWait()
        else { return }
        resumingExplicitReviewCommandsById[pendingCommand.commandId] = nil
        pendingExplicitReviewCommand = pendingCommand
        recordReviewBuildAdmissionFact(
            .pendingExplicitCommandAwaitingPageMode(commandId: pendingCommand.commandId),
            scope: .pendingExplicitCommand(pendingCommand.commandId)
        )
    }

    private func finishExplicitReviewCommandResumption(
        _ pendingCommand: BridgePendingExplicitReviewCommand
    ) {
        if resumingExplicitReviewCommandsById[pendingCommand.commandId] === pendingCommand {
            resumingExplicitReviewCommandsById[pendingCommand.commandId] = nil
        }
        resumingExplicitReviewCommandTasksById[pendingCommand.commandId] = nil
    }

    private static func closedExplicitReviewCommandResult() -> ActionResult {
        .failure(.invalidPayload(description: "Bridge pane is closed"))
    }

    private static func supersededExplicitReviewCommandResult() -> ActionResult {
        .failure(.invalidPayload(description: "Stale bridge review load"))
    }
}
