import AgentStudioGit
import Foundation

struct WorktreePruneEntryContext: Sendable {
    let targetResolution: WorktreeIntegrationTargetResolution
    let request: WorktreePruneRequest
    let repository: WorktreeRemovalRunner.RepositoryContext
    let mainWorktreePath: URL
    let removalRunner: WorktreeRemovalRunner
}

extension WorktreePruneRunner {
    func pruneEntry(
        _ snapshot: GitWorktreeSnapshot,
        assessment: BranchAssessment?,
        context: WorktreePruneEntryContext
    ) async -> WorktreePruneEntry {
        let worktreePath = snapshot.canonicalPath.standardizedFileURL
        let branchName = WorktreeListingProjector.branchName(in: snapshot.head)

        if let branchName, branchName == context.targetResolution.branchName {
            return skippedEntry(
                target: worktreePath.path,
                reason: .defaultBranch,
                repositoryPath: context.repository.repositoryPath,
                worktreePath: worktreePath
            )
        }

        let removalRequest = removalRequest(
            repositoryPath: context.repository.repositoryPath,
            callerDirectory: context.request.callerDirectory,
            targetPath: worktreePath,
            evidencePolicy: context.request.evidencePolicy,
            fetchPolicy: .skip,
            dryRun: true
        )
        let preflight = await context.removalRunner.preflight(
            snapshot,
            request: removalRequest,
            mainWorktreePath: context.mainWorktreePath
        )
        let removalAssessment = assessment.map {
            WorktreeRemovalRunner.BranchAssessment(
                branchName: $0.branchName,
                grade: $0.grade,
                commit: $0.commit,
                document: $0.document
            )
        }
        let lockCheck = context.removalRunner.preEffectLockCheck(
            snapshot: snapshot,
            branchName: branchName,
            assessment: removalAssessment,
            request: removalRequest,
            repository: context.repository,
            targetResolution: context.targetResolution
        )
        let stops = [preflight.stop, preflight.archiveDestinationStop, lockCheck.stop].compactMap { $0 }
        if let stop = firstStopInLifecycleOrder(stops) {
            return skippedEntry(
                target: worktreePath.path,
                reason: .stop(stop.reason),
                details: stop,
                repositoryPath: context.repository.repositoryPath,
                worktreePath: worktreePath
            )
        }

        return await assessedPruneEntry(
            snapshot,
            branchName: branchName,
            assessment: assessment,
            removalAssessment: removalAssessment,
            context: context
        )
    }

    private func assessedPruneEntry(
        _ snapshot: GitWorktreeSnapshot,
        branchName: String?,
        assessment: BranchAssessment?,
        removalAssessment: WorktreeRemovalRunner.BranchAssessment?,
        context: WorktreePruneEntryContext
    ) async -> WorktreePruneEntry {
        let worktreePath = snapshot.canonicalPath.standardizedFileURL
        guard let branchName else {
            return skippedEntry(
                target: worktreePath.path,
                reason: .detached,
                repositoryPath: context.repository.repositoryPath,
                worktreePath: worktreePath
            )
        }
        guard let assessment else {
            return skippedEntry(
                target: worktreePath.path,
                reason: .assessmentUnknown(context.targetResolution.hasReadFailure ? .readFailed : .noTarget),
                repositoryPath: context.repository.repositoryPath,
                worktreePath: worktreePath
            )
        }

        switch assessment.document {
        case .hasRemainingContribution:
            return skippedEntry(
                target: worktreePath.path,
                reason: .notIntegrated,
                repositoryPath: context.repository.repositoryPath,
                worktreePath: worktreePath
            )
        case .unknown(let reason):
            return skippedEntry(
                target: worktreePath.path,
                reason: .assessmentUnknown(reason),
                repositoryPath: context.repository.repositoryPath,
                worktreePath: worktreePath
            )
        case .integrated:
            guard case .integrated = assessment.grade else {
                return skippedEntry(
                    target: worktreePath.path,
                    reason: .assessmentUnknown(.readFailed),
                    repositoryPath: context.repository.repositoryPath,
                    worktreePath: worktreePath
                )
            }
            let wouldRemove = WorktreePruneWouldRemoveDocument(
                target: worktreePath.path,
                branch: branchName,
                assessment: assessment.document
            )
            guard context.request.apply else { return .wouldRemove(wouldRemove) }
            return await applyRemoval(
                snapshot,
                assessment: removalAssessment,
                request: context.request,
                repository: context.repository,
                removalRunner: context.removalRunner
            )
        }
    }

    private func applyRemoval(
        _ snapshot: GitWorktreeSnapshot,
        assessment: WorktreeRemovalRunner.BranchAssessment?,
        request: WorktreePruneRequest,
        repository: WorktreeRemovalRunner.RepositoryContext,
        removalRunner: WorktreeRemovalRunner
    ) async -> WorktreePruneEntry {
        let targetPath = snapshot.canonicalPath.standardizedFileURL
        let removalResult = await removalRunner.runForPruneCandidate(
            removalRequest(
                repositoryPath: repository.repositoryPath,
                callerDirectory: request.callerDirectory,
                targetPath: targetPath,
                evidencePolicy: request.evidencePolicy,
                fetchPolicy: .skip,
                dryRun: false
            )
        )
        switch removalResult {
        case .candidateRejected(let rejection):
            let reason: WorktreePruneSkipReason
            guard rejection.branchName != nil else {
                reason = .detached
                return skippedEntry(
                    target: targetPath.path,
                    reason: reason,
                    repositoryPath: repository.repositoryPath,
                    worktreePath: targetPath
                )
            }
            guard let freshAssessment = rejection.assessment else {
                return skippedEntry(
                    target: targetPath.path,
                    reason: .assessmentUnknown(.noTarget),
                    repositoryPath: repository.repositoryPath,
                    worktreePath: targetPath
                )
            }
            switch freshAssessment {
            case .hasRemainingContribution:
                reason = .notIntegrated
            case .unknown(let unknownReason):
                reason = .assessmentUnknown(unknownReason)
            case .integrated:
                return failedObservationEntry(targetPath: targetPath, assessment: assessment?.document)
            }
            return skippedEntry(
                target: targetPath.path,
                reason: reason,
                repositoryPath: repository.repositoryPath,
                worktreePath: targetPath
            )
        case .report(let report):
            return removalReportEntry(
                report,
                targetPath: targetPath,
                assessment: assessment,
                repository: repository
            )
        }
    }

    private func removalReportEntry(
        _ report: WorktreeRemovalReport,
        targetPath: URL,
        assessment: WorktreeRemovalRunner.BranchAssessment?,
        repository: WorktreeRemovalRunner.RepositoryContext
    ) -> WorktreePruneEntry {
        if report.fetchingReadFailure != nil {
            return failedObservationEntry(targetPath: targetPath, assessment: assessment?.document)
        }
        guard let entry = report.entries.first, report.entries.count == 1 else {
            return failedObservationEntry(targetPath: targetPath, assessment: assessment?.document)
        }

        switch entry {
        case .removed(let details):
            return .removed(details)
        case .failed(let details):
            return .failed(details)
        case .refused(let details):
            return skippedEntry(
                target: targetPath.path,
                reason: .stop(details.refusal.reason),
                details: details.refusal.details,
                repositoryPath: repository.repositoryPath,
                worktreePath: targetPath
            )
        case .alreadyRemoved:
            return skippedEntry(
                target: targetPath.path,
                reason: .stop(.notFound),
                details: .notFound(target: targetPath.path),
                repositoryPath: repository.repositoryPath,
                worktreePath: targetPath
            )
        case .planned:
            return failedObservationEntry(targetPath: targetPath, assessment: assessment?.document)
        }
    }

    private func removalRequest(
        repositoryPath: URL,
        callerDirectory: URL?,
        targetPath: URL,
        evidencePolicy: WorktreeEvidencePolicy,
        fetchPolicy: WorktreeFetchPolicy,
        dryRun: Bool
    ) -> WorktreeRemovalRequest {
        WorktreeRemovalRequest(
            start: repositoryPath,
            callerDirectory: callerDirectory,
            targets: [targetPath.path],
            discardWorkingChanges: false,
            branchPolicy: .deleteIfIntegrated,
            evidencePolicy: evidencePolicy,
            fetchPolicy: fetchPolicy,
            removeStaleLock: false,
            closePanes: false,
            removeWithOpenPanes: false,
            dryRun: dryRun
        )
    }

    private func firstStopInLifecycleOrder(_ stops: [WorktreeStopDetails]) -> WorktreeStopDetails? {
        stops.min { left, right in
            let order = WorktreeStopReason.lr11Order
            return (order.firstIndex(of: left.reason) ?? Int.max) < (order.firstIndex(of: right.reason) ?? Int.max)
        }
    }

    private func skippedEntry(
        target: String,
        reason: WorktreePruneSkipReason,
        details: WorktreeStopDetails? = nil,
        repositoryPath: URL,
        worktreePath: URL
    ) -> WorktreePruneEntry {
        .skipped(
            WorktreePruneSkippedDocument(
                target: target,
                skip: WorktreePruneSkip(
                    reason: reason,
                    details: details,
                    options: pruneOptions(
                        for: reason,
                        details: details,
                        repositoryPath: repositoryPath,
                        worktreePath: worktreePath
                    )
                )
            )
        )
    }

    private func failedObservationEntry(
        targetPath: URL,
        assessment: WorktreeIntegrationAssessmentDocument?
    ) -> WorktreePruneEntry {
        let effects = WorktreeRemovalEffectsDocument(
            directory: .unknown,
            administration: .unknown,
            branch: nil,
            evidence: .noEvidence,
            assessment: assessment,
            activity: .notChecked,
            lockResidue: []
        )
        return .failed(
            WorktreeFailedEntryDocument(
                target: targetPath.path,
                inputs: [targetPath.path],
                failure: WorktreeRemovalFailureDocument(kind: .observationFailed, effects: effects)
            )
        )
    }

    private func pruneOptions(
        for reason: WorktreePruneSkipReason,
        details: WorktreeStopDetails?,
        repositoryPath: URL,
        worktreePath: URL
    ) -> [String] {
        switch reason {
        case .notIntegrated, .assessmentUnknown:
            return [removeCommand(repositoryPath, worktreePath, flags: ["-D"])]
        case .detached:
            return [removeCommand(repositoryPath, worktreePath)]
        case .defaultBranch:
            return []
        case .stop:
            guard let details else { return [] }
            return stopOptions(details, repositoryPath: repositoryPath, worktreePath: worktreePath)
        }
    }

    private func stopOptions(
        _ details: WorktreeStopDetails,
        repositoryPath: URL,
        worktreePath: URL
    ) -> [String] {
        let retry = removeCommand(repositoryPath, worktreePath)
        switch details {
        case .creation, .defaultBranch, .mainWorktree, .notFound, .alreadyRemoved,
            .startBranchNotFound, .unsupportedWorkingState, .forkUnavailable:
            return []
        case .gitLockUnidentified:
            return [retry]
        case .targetIsCurrent, .worktreeLocked, .defaultBranchUnverified:
            return [retry]
        case .dirty:
            return [removeCommand(repositoryPath, worktreePath, flags: ["-f"])]
        case .changesUnknown:
            return [retry, removeCommand(repositoryPath, worktreePath, flags: ["-f"])]
        case .evidenceInTmp:
            return [
                removeCommand(repositoryPath, worktreePath, flags: ["--archive-to-main"]),
                removeCommand(repositoryPath, worktreePath, flags: ["--archive-to", "<folder>"]),
                removeCommand(repositoryPath, worktreePath, flags: ["--discard-tmp"]),
                pruneArchiveCommand(repositoryPath),
            ]
        case .evidenceUnknown:
            return [retry, removeCommand(repositoryPath, worktreePath, flags: ["--discard-tmp"])]
        case .openInPane:
            return [retry]
        case .gitLockHeld(let observation):
            return observation.looksStale
                ? [retry, removeCommand(repositoryPath, worktreePath, flags: ["--remove-stale-lock"])]
                : [retry]
        case .archiveDestinationExists, .archiveDestinationInsideWorktree:
            return [removeCommand(repositoryPath, worktreePath, flags: ["--archive-to", "<other-folder>"])]
        }
    }

    private func removeCommand(_ repositoryPath: URL, _ worktreePath: URL, flags: [String] = []) -> String {
        let repo = WorktreeListingProjector.shellArgument(repositoryPath.standardizedFileURL.path)
        let target = WorktreeListingProjector.shellArgument(worktreePath.standardizedFileURL.path)
        let flagArguments = flags.map(WorktreeListingProjector.shellArgument).joined(separator: " ")
        let suffix = flagArguments.isEmpty ? "" : " \(flagArguments)"
        return "agentstudio worktree remove --repo \(repo) \(target)\(suffix)"
    }

    private func pruneArchiveCommand(_ repositoryPath: URL) -> String {
        let repo = WorktreeListingProjector.shellArgument(repositoryPath.standardizedFileURL.path)
        return "agentstudio worktree prune --repo \(repo) --apply --archive-to-main"
    }
}
