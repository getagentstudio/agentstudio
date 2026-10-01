import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

enum BridgeReviewPageModeAdmissionDisposition {
    case reviewShown
    case modeUnknown
    case hidden
    case closed
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

    func deferExplicitReviewLoadUntilPageModeIsAccepted(
        artifact: DiffArtifact,
        commandId: UUID,
        correlationId: UUID?,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        reviewAuthorityGeneration: UInt64
    ) async -> ActionResult {
        guard let installationFence = productSessionOwner.installationFenceProjection.snapshot.installation,
            let installationAdmission = productAdmission.withInstallation(installationFence.gate)
        else {
            return Self.closedExplicitReviewCommandResult()
        }
        deferExplicitReviewLoadReason()
        return await withCheckedContinuation { continuation in
            let pendingCommand = BridgePendingExplicitReviewCommand(
                artifact: artifact,
                commandId: commandId,
                correlationId: correlationId,
                productAdmission: productAdmission,
                installationAdmission: installationAdmission,
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
                installationAdmission.observeClose { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.retirePendingExplicitReviewCommand(commandId: commandId)
                    }
                }
            )
            guard installationAdmission.withValidAdmission({ true }) == true else {
                finishPendingExplicitReviewCommand(
                    pendingCommand,
                    result: Self.closedExplicitReviewCommandResult(),
                    outcome: .retired
                )
                return
            }
        }
    }

    func resumePendingExplicitReviewCommandIfPossible() -> Bool {
        guard let pendingCommand = pendingExplicitReviewCommand else { return false }
        guard pendingCommand.productAdmission.withValidAdmission({ true }) == true,
            pendingCommand.installationAdmission.withValidAdmission({ true }) == true,
            pendingCommand.foregroundWorkAdmission.withValidAdmission({ true }) == true
        else {
            finishPendingExplicitReviewCommand(
                pendingCommand,
                result: Self.closedExplicitReviewCommandResult(),
                outcome: .retired
            )
            return false
        }
        guard pendingCommand.beginResumption() else { return true }

        Task { @MainActor [weak self, pendingCommand] in
            guard let self,
                self.pendingExplicitReviewCommand === pendingCommand,
                !pendingCommand.isSettled
            else { return }
            guard pendingCommand.productAdmission.withValidAdmission({ true }) == true,
                pendingCommand.installationAdmission.withValidAdmission({ true }) == true,
                pendingCommand.foregroundWorkAdmission.withValidAdmission({ true }) == true
            else {
                self.finishPendingExplicitReviewCommand(
                    pendingCommand,
                    result: Self.closedExplicitReviewCommandResult(),
                    outcome: .retired
                )
                return
            }
            let result = await self.resumeExplicitReviewCommand(pendingCommand)
            self.finishPendingExplicitReviewCommand(
                pendingCommand,
                result: result,
                outcome: .completed
            )
        }
        return true
    }

    func supersedePendingExplicitReviewCommandForNewIntent() {
        guard let pendingCommand = pendingExplicitReviewCommand else { return }
        guard pendingCommand.productAdmission.withValidAdmission({ true }) == true,
            pendingCommand.installationAdmission.withValidAdmission({ true }) == true
        else {
            finishPendingExplicitReviewCommand(
                pendingCommand,
                result: Self.closedExplicitReviewCommandResult(),
                outcome: .retired
            )
            return
        }
        finishPendingExplicitReviewCommand(
            pendingCommand,
            result: Self.supersededExplicitReviewCommandResult(),
            outcome: .superseded
        )
    }

    func retirePendingExplicitReviewCommand(commandId: UUID? = nil) {
        guard let pendingCommand = pendingExplicitReviewCommand,
            commandId == nil || pendingCommand.commandId == commandId
        else { return }
        finishPendingExplicitReviewCommand(
            pendingCommand,
            result: Self.closedExplicitReviewCommandResult(),
            outcome: .retired
        )
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

    private func finishPendingExplicitReviewCommand(
        _ pendingCommand: BridgePendingExplicitReviewCommand,
        result: ActionResult,
        outcome: BridgePanePendingExplicitReviewCommandOutcome
    ) {
        guard pendingCommand.settle(result) else { return }
        if pendingExplicitReviewCommand === pendingCommand {
            pendingExplicitReviewCommand = nil
        }
        recordReviewBuildAdmissionFact(
            .pendingExplicitCommandEnded(commandId: pendingCommand.commandId, outcome: outcome),
            scope: .pendingExplicitCommand(pendingCommand.commandId)
        )
        guard outcome == .completed else { return }
        scheduleRetainedReviewPackageBuildIfPossible()
        scheduleWorktreeProductCatchUpIfPossible()
    }

    private func resumeExplicitReviewCommand(
        _ pendingCommand: BridgePendingExplicitReviewCommand
    ) async -> ActionResult {
        await resumePendingExplicitReviewPackageCommand(pendingCommand)
    }

    private static func closedExplicitReviewCommandResult() -> ActionResult {
        .failure(.invalidPayload(description: "Bridge pane is closed"))
    }

    private static func supersededExplicitReviewCommandResult() -> ActionResult {
        .failure(.invalidPayload(description: "Stale bridge review load"))
    }
}
