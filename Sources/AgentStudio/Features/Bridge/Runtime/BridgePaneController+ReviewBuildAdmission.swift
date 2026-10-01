import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@MainActor
extension BridgePaneController {
    func scheduleInitialReviewPackageLoadIfPossible(reason: BridgeReviewPackageBuildReason) {
        guard case .workspace = bridgePaneState.source,
            runtime.metadata.worktreeId != nil,
            paneState.diff.status == .idle || paneState.diff.status == .loading
                || paneState.diff.status == .error,
            paneState.diff.packageMetadata == nil
        else { return }
        if pendingExplicitReviewCommand != nil {
            pendingReviewPackageBuildReasons.insert(reason)
            return
        }
        guard activeReviewPackageLoad == nil else { return }
        let hiddenInput = BridgePaneReviewBuildAdmissionInput.initialIntake
        guard isReviewShownByPage else {
            pendingReviewPackageBuildReasons.insert(reason)
            recordReviewBuildAdmissionFact(
                .deferredHidden(input: hiddenInput),
                scope: .hiddenInput(hiddenInput)
            )
            return
        }
        guard refreshAdmissionCoordinator.acquireForegroundWork() != nil else {
            pendingReviewPackageBuildReasons.insert(reason)
            return
        }
        guard activeReviewRefreshTask == nil else { return }
        pendingReviewPackageBuildReasons.insert(reason)
        scheduleRetainedReviewPackageBuildIfPossible(admissionInput: .initialIntake)
    }

    /// Full reload for a typed product resync request on an already-loaded pane.
    func scheduleReviewPackageReloadForProductResync() {
        scheduleReviewPackageReloadForProductResync(reason: .productResync)
    }

    func scheduleReviewPackageReloadForProductResync(reason: BridgeReviewPackageBuildReason) {
        pendingReviewPackageBuildReasons.insert(reason)
        let hiddenInput = BridgePaneReviewBuildAdmissionInput.productResync
        guard isReviewShownByPage else {
            recordReviewBuildAdmissionFact(
                .deferredHidden(input: hiddenInput),
                scope: .hiddenInput(hiddenInput)
            )
            return
        }
        guard refreshAdmissionCoordinator.acquireForegroundWork() != nil else { return }
        refreshAdmissionCoordinator.advanceAuthority(for: .review)
        retireActiveReviewRefreshTask()
        scheduleRetainedReviewPackageBuildIfPossible(admissionInput: .productResync)
    }

    func scheduleRetainedReviewPackageBuildIfPossible(
        admissionInput: BridgePaneReviewBuildAdmissionInput? = nil
    ) {
        guard !pendingReviewPackageBuildReasons.isEmpty else { return }
        guard pendingExplicitReviewCommand == nil else { return }
        guard activeReviewPackageLoad == nil else { return }
        let hiddenInput = admissionInput ?? .retainedPackageBuild
        guard isReviewShownByPage else {
            recordReviewBuildAdmissionFact(
                .deferredHidden(input: hiddenInput),
                scope: .hiddenInput(hiddenInput)
            )
            return
        }
        guard
            activeReviewRefreshTask == nil,
            refreshAdmissionCoordinator.acquireForegroundWork() != nil,
            case .workspace = bridgePaneState.source,
            let worktreeId = runtime.metadata.worktreeId
        else { return }

        let shouldLoadInitialPackage =
            paneState.diff.packageMetadata == nil
            && (paneState.diff.status == .idle || paneState.diff.status == .loading
                || paneState.diff.status == .error)
        guard
            shouldLoadInitialPackage || paneState.diff.packageMetadata != nil
                || pendingReviewPackageBuildReasons.contains(.productResync)
        else { return }

        let taskId = UUIDv7.generate()
        let factScope: BridgePaneReviewBuildAdmissionScope = .attempt(taskId)
        recordReviewBuildAdmissionFact(.admitted(attempt: taskId), scope: factScope)
        let reviewAuthorityGeneration = refreshAdmissionCoordinator.currentAuthorityGeneration(
            for: .review
        )
        activeReviewRefreshTaskId = taskId
        activeReviewRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result: ActionResult?
            if shouldLoadInitialPackage {
                result = await self.loadInitialReviewPackageIfPossible(
                    correlationId: nil,
                    reviewAuthorityGeneration: reviewAuthorityGeneration
                )
            } else {
                result = await self.loadReviewPackage(
                    worktreeId: worktreeId,
                    correlationId: nil,
                    reviewAuthorityGeneration: reviewAuthorityGeneration
                )
            }
            let outcome: BridgePaneReviewBuildAttemptOutcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if let result {
                switch result {
                case .success, .queued:
                    outcome = .succeeded
                case .failure(.invalidPayload(description: "Stale bridge review load")):
                    outcome = .stale
                case .failure:
                    outcome = .failed
                }
            } else {
                outcome = .stale
            }
            self.retiringReviewRefreshTaskById.removeValue(forKey: taskId)
            self.recordReviewBuildAdmissionFact(
                .attemptEnded(attempt: taskId, outcome: outcome),
                scope: factScope
            )
            guard self.activeReviewRefreshTaskId == taskId else { return }
            self.activeReviewRefreshTask = nil
            self.activeReviewRefreshTaskId = nil
            self.scheduleRetainedReviewPackageBuildIfPossible()
            self.scheduleWorktreeProductCatchUpIfPossible()
        }
    }
}
