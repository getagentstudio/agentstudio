import AgentStudioGit
import Foundation

extension WorktreeRemovalRunner {
    func removeWorktree(
        _ snapshot: GitWorktreeSnapshot,
        inputs: [String],
        request: WorktreeRemovalRequest,
        repository: RepositoryContext,
        fetchResult: WorktreeFetchStepResult,
        requireIntegratedCandidate: Bool
    ) async -> WorktreeRemovalAttemptResult {
        let targetName = snapshot.canonicalPath.standardizedFileURL.path
        let branchName = WorktreeListingProjector.branchName(in: snapshot.head)
        let preflight = await preflight(
            snapshot,
            request: request,
            mainWorktreePath: repository.mainWorktreePath ?? repository.repositoryPath
        )
        if let stop = preflight.stop {
            return .entry(
                request.dryRun
                    ? plannedEntry(
                        WorktreePlanEntryRequest(
                            target: targetName,
                            inputs: inputs,
                            isWorktree: true,
                            request: request,
                            fetchStatus: fetchResult.status,
                            preflight: preflight,
                            assessment: nil,
                            targetResolution: fetchResult.resolution,
                            stop: stop,
                            wouldRemoveLockPaths: []
                        )
                    )
                    : refusedEntry(target: targetName, inputs: inputs, stop: stop)
            )
        }

        let assessment: BranchAssessment?
        if let branchName {
            assessment = await branchAssessment(
                branchName,
                repositoryPath: repository.repositoryPath,
                resolution: fetchResult.resolution
            )
        } else {
            assessment = nil
        }
        if requireIntegratedCandidate {
            guard let freshAssessment = assessment,
                case .integrated? = freshAssessment.document
            else {
                return .candidateRejected(
                    PruneCandidateAssessmentRejection(
                        branchName: branchName,
                        assessment: assessment?.document
                    ))
            }
        }
        let lockCheck = preEffectLockCheck(
            snapshot: snapshot,
            branchName: branchName,
            assessment: assessment,
            request: request,
            repository: repository,
            targetResolution: fetchResult.resolution
        )
        let plannedRequest = WorktreePlanEntryRequest(
            target: targetName,
            inputs: inputs,
            isWorktree: true,
            request: request,
            fetchStatus: fetchResult.status,
            preflight: preflight,
            assessment: assessment,
            targetResolution: fetchResult.resolution,
            stop: nil,
            wouldRemoveLockPaths: lockCheck.wouldRemovePaths
        )
        if let stop = lockCheck.stop {
            return .entry(preflightStopEntry(stop, request: request, plannedRequest: plannedRequest))
        }

        if let stop = preflight.archiveDestinationStop {
            return .entry(preflightStopEntry(stop, request: request, plannedRequest: plannedRequest))
        }

        if request.dryRun {
            return .entry(plannedEntry(plannedRequest))
        }

        return .entry(
            await executeWorktreeRemoval(
                WorktreeRemovalExecutionContext(
                    snapshot: snapshot,
                    targetName: targetName,
                    inputs: inputs,
                    branchName: branchName,
                    assessment: assessment,
                    preflight: preflight,
                    request: request,
                    repository: repository,
                    targetResolution: fetchResult.resolution
                )
            )
        )
    }

    func removeBranch(
        _ branchName: String,
        inputs: [String],
        request: WorktreeRemovalRequest,
        repository: RepositoryContext,
        fetchResult: WorktreeFetchStepResult
    ) async -> WorktreeRemovalEntry {
        let targetName = branchName
        if let stop = branchProtectionStop(branchName, resolution: fetchResult.resolution) {
            return request.dryRun
                ? plannedEntry(
                    WorktreePlanEntryRequest(
                        target: targetName,
                        inputs: inputs,
                        isWorktree: false,
                        request: request,
                        fetchStatus: fetchResult.status,
                        preflight: nil,
                        assessment: nil,
                        targetResolution: fetchResult.resolution,
                        stop: stop,
                        wouldRemoveLockPaths: []
                    )
                )
                : refusedEntry(target: targetName, inputs: inputs, stop: stop)
        }

        let assessment = await branchAssessment(
            branchName,
            repositoryPath: repository.repositoryPath,
            resolution: fetchResult.resolution
        )
        if request.dryRun {
            let lockCheck = preEffectLockCheck(
                snapshot: nil,
                branchName: branchName,
                assessment: assessment,
                request: request,
                repository: repository,
                targetResolution: fetchResult.resolution
            )
            return plannedEntry(
                WorktreePlanEntryRequest(
                    target: targetName,
                    inputs: inputs,
                    isWorktree: false,
                    request: request,
                    fetchStatus: fetchResult.status,
                    preflight: nil,
                    assessment: assessment,
                    targetResolution: fetchResult.resolution,
                    stop: lockCheck.stop,
                    wouldRemoveLockPaths: lockCheck.wouldRemovePaths
                )
            )
        }

        return await finishBranchDisposition(
            BranchDispositionContext(
                branchName: branchName,
                request: request,
                repositoryPath: repository.repositoryPath,
                targetResolution: fetchResult.resolution,
                assessment: assessment,
                completion: WorktreeRemovalCompletion(
                    target: targetName,
                    inputs: inputs,
                    effects: WorktreeRemovalEffectsState(
                        directory: .notApplicable,
                        administration: .notApplicable,
                        branch: nil,
                        evidence: .noEvidence,
                        assessment: assessment.document,
                        activity: .notChecked,
                        lockResidue: []
                    )
                ),
                priorMutation: false
            )
        )
    }

    func executeWorktreeRemoval(_ context: WorktreeRemovalExecutionContext) async -> WorktreeRemovalEntry {
        let initialEvidence = Self.evidenceDisposition(
            for: context.preflight.evidence,
            policy: context.request.evidencePolicy
        )
        let archive = archiveEvidence(for: context, initialEvidence: initialEvidence)
        if let failure = archive.failure { return failure }

        let finalActivity = await activityProbe.activity(forWorktreeAt: context.snapshot.canonicalPath)
        if let activityFailure = activityFailure(
            finalActivity,
            archive: archive,
            context: context
        ) {
            return activityFailure
        }

        let removalAttempt = await removeWorktreeWithLockRecovery(context.snapshot, request: context.request)
        return await finishWorktreeRemoval(
            removalAttempt,
            archive: archive,
            activity: finalActivity,
            context: context
        )
    }

    private struct WorktreeEvidenceArchiveOutcome {
        let evidence: WorktreeEvidenceDispositionDocument
        let archiveWritten: Bool
        let failure: WorktreeRemovalEntry?
    }

    private func archiveEvidence(
        for context: WorktreeRemovalExecutionContext,
        initialEvidence: WorktreeEvidenceDispositionDocument
    ) -> WorktreeEvidenceArchiveOutcome {
        guard let destination = context.preflight.archiveDestination else {
            return WorktreeEvidenceArchiveOutcome(evidence: initialEvidence, archiveWritten: false, failure: nil)
        }
        switch evidenceArchiver.archive(
            source: context.snapshot.canonicalPath.appending(path: "tmp", directoryHint: .isDirectory),
            destination: destination
        ) {
        case .archived(let path, let fileCount):
            return WorktreeEvidenceArchiveOutcome(
                evidence: .archived(path: path.standardizedFileURL.path, files: fileCount),
                archiveWritten: true,
                failure: nil
            )
        case .partialCopy(let path):
            return WorktreeEvidenceArchiveOutcome(
                evidence: .partialCopy(path: path.standardizedFileURL.path),
                archiveWritten: false,
                failure: failedEntry(
                    target: context.targetName,
                    inputs: context.inputs,
                    kind: .archiveFailed,
                    effects: removalEffects(
                        WorktreeRemovalEffectsState(
                            directory: .retained,
                            administration: .retained,
                            branch: context.branchName.map { retainedBranch($0, assessment: context.assessment) },
                            evidence: .partialCopy(path: path.standardizedFileURL.path),
                            assessment: context.assessment?.document,
                            activity: context.preflight.activity,
                            lockResidue: []
                        )
                    )
                )
            )
        }
    }

    private func activityFailure(
        _ activity: WorktreeActivityDocument,
        archive: WorktreeEvidenceArchiveOutcome,
        context: WorktreeRemovalExecutionContext
    ) -> WorktreeRemovalEntry? {
        guard case .openPanes(let panes) = activity,
            !context.request.closePanes,
            !context.request.removeWithOpenPanes
        else {
            return nil
        }
        let stop = WorktreeStopDetails.openInPane(
            panes: panes.map { WorktreeStopPaneDetails(paneId: $0.id, title: $0.displayTitle) }
        )
        guard archive.archiveWritten else {
            return refusedEntry(target: context.targetName, inputs: context.inputs, stop: stop)
        }
        return failedEntry(
            target: context.targetName,
            inputs: context.inputs,
            kind: .activityChanged,
            effects: removalEffects(
                WorktreeRemovalEffectsState(
                    directory: .retained,
                    administration: .retained,
                    branch: context.branchName.map { retainedBranch($0, assessment: context.assessment) },
                    evidence: archive.evidence,
                    assessment: context.assessment?.document,
                    activity: activity,
                    lockResidue: []
                )
            )
        )
    }

    private func finishWorktreeRemoval(
        _ removalAttempt: GitRemovalAttempt,
        archive: WorktreeEvidenceArchiveOutcome,
        activity: WorktreeActivityDocument,
        context: WorktreeRemovalExecutionContext
    ) async -> WorktreeRemovalEntry {
        guard let sdkResult = removalAttempt.result else {
            let effects = removalEffects(
                WorktreeRemovalEffectsState(
                    directory: .retained,
                    administration: .retained,
                    branch: context.branchName.map { retainedBranch($0, assessment: context.assessment) },
                    evidence: archive.evidence,
                    assessment: context.assessment?.document,
                    activity: activity,
                    lockResidue: []
                )
            )
            if let stop = removalAttempt.lockStop, !archive.archiveWritten, !removalAttempt.removedStaleLock {
                return refusedEntry(target: context.targetName, inputs: context.inputs, stop: stop)
            }
            return failedEntry(
                target: context.targetName,
                inputs: context.inputs,
                kind: .removalIncomplete,
                effects: effects,
                stop: removalAttempt.lockStop
            )
        }

        let directory = WorktreeOperationErrorMapper.removalDirectoryEffect(for: sdkResult.effects.workingDirectory)
        let administration = WorktreeOperationErrorMapper.removalAdministrationEffect(
            for: sdkResult.effects.administration)
        let lockResidue = Self.paths(sdkResult.effects.lockResidue)
        guard sdkResult.effects.failure == nil, directory == .removed, administration == .removed else {
            let failureKind =
                sdkResult.effects.failure.map(WorktreeOperationErrorMapper.removalFailureKind(for:))
                ?? .removalIncomplete
            return failedEntry(
                target: context.targetName,
                inputs: context.inputs,
                kind: failureKind,
                effects: removalEffects(
                    WorktreeRemovalEffectsState(
                        directory: directory,
                        administration: administration,
                        branch: context.branchName.map { retainedBranch($0, assessment: context.assessment) },
                        evidence: archive.evidence,
                        assessment: context.assessment?.document,
                        activity: activity,
                        lockResidue: lockResidue
                    )
                )
            )
        }

        guard let branchName = context.branchName else {
            let completion = WorktreeRemovalCompletion(
                target: context.targetName,
                inputs: context.inputs,
                effects: WorktreeRemovalEffectsState(
                    directory: .removed,
                    administration: .removed,
                    branch: nil,
                    evidence: archive.evidence,
                    assessment: nil,
                    activity: activity,
                    lockResidue: lockResidue
                )
            )
            return lockResidue.isEmpty
                ? .removed(
                    WorktreeRemovedEntryDocument(
                        target: completion.target, inputs: completion.inputs,
                        effects: removalEffects(completion.effects)))
                : failedEntry(
                    target: completion.target, inputs: completion.inputs, kind: .lockCleanupIncomplete,
                    effects: removalEffects(completion.effects))
        }

        return await finishBranchDisposition(
            BranchDispositionContext(
                branchName: branchName,
                request: context.request,
                repositoryPath: context.repository.repositoryPath,
                targetResolution: context.targetResolution,
                assessment: context.assessment,
                completion: WorktreeRemovalCompletion(
                    target: context.targetName,
                    inputs: context.inputs,
                    effects: WorktreeRemovalEffectsState(
                        directory: .removed,
                        administration: .removed,
                        branch: nil,
                        evidence: archive.evidence,
                        assessment: context.assessment?.document,
                        activity: activity,
                        lockResidue: lockResidue
                    )
                ),
                priorMutation: true
            )
        )
    }
    func removeWorktreeWithLockRecovery(
        _ snapshot: GitWorktreeSnapshot,
        request: WorktreeRemovalRequest
    ) async -> GitRemovalAttempt {
        var removedStaleLock = false
        var lastError: GitDataPlaneError = .unsupported(message: "worktree removal did not return an outcome")
        for _ in 0..<4 {
            if let fact = existingIndexLockFact(for: snapshot) {
                let assessment = staleLockAssessment.inspect(fact)
                if request.removeStaleLock,
                    assessment.observation.looksStale,
                    staleLockAssessment.removeIfStillStale(assessment, lockPath: fact.path)
                {
                    removedStaleLock = true
                    continue
                }
                guard let currentFact = existingIndexLockFact(for: snapshot) else { continue }
                let observation = staleLockAssessment.inspect(currentFact).observation
                return GitRemovalAttempt(
                    result: nil,
                    error: .lockHeld(currentFact),
                    lockStop: .gitLockHeld(observation),
                    removedStaleLock: removedStaleLock
                )
            }
            do {
                let result = try await client.removeWorktree(
                    GitRemoveWorktreeRequest(
                        worktreeID: snapshot.id,
                        canonicalPath: snapshot.canonicalPath,
                        removeWorkingDirectory: true,
                        forceDiscardChanges: request.discardWorkingChanges
                    ))
                return GitRemovalAttempt(
                    result: result,
                    error: nil,
                    lockStop: nil,
                    removedStaleLock: removedStaleLock
                )
            } catch {
                lastError = error
                guard case .lockHeld(let fact) = error else {
                    return GitRemovalAttempt(
                        result: nil,
                        error: error,
                        lockStop: lockStopDetails(for: error),
                        removedStaleLock: removedStaleLock
                    )
                }
                let assessment = staleLockAssessment.inspect(fact)
                if request.removeStaleLock,
                    assessment.observation.looksStale,
                    staleLockAssessment.removeIfStillStale(assessment, lockPath: fact.path)
                {
                    removedStaleLock = true
                    continue
                }
                let currentAssessment = staleLockAssessment.inspect(fact)
                return GitRemovalAttempt(
                    result: nil,
                    error: error,
                    lockStop: .gitLockHeld(currentAssessment.observation),
                    removedStaleLock: removedStaleLock
                )
            }
        }
        return GitRemovalAttempt(
            result: nil,
            error: lastError,
            lockStop: lockStopDetails(for: lastError),
            removedStaleLock: removedStaleLock
        )
    }

    private func existingIndexLockFact(for snapshot: GitWorktreeSnapshot) -> GitLockFact? {
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock").standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: lockPath.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return nil
        }
        return GitLockFact(path: lockPath, resource: .index(worktreePath: snapshot.canonicalPath))
    }

    func refusedEntry(target: String, inputs: [String], stop: WorktreeStopDetails) -> WorktreeRemovalEntry {
        .refused(
            WorktreeRefusedEntryDocument(
                target: target,
                inputs: inputs,
                refusal: WorktreeRefusalDocument(details: stop)
            ))
    }

    func failedEntry(
        target: String,
        inputs: [String],
        kind: WorktreeRemovalFailureKindDocument,
        effects: WorktreeRemovalEffectsDocument,
        stop: WorktreeStopDetails? = nil
    ) -> WorktreeRemovalEntry {
        .failed(
            WorktreeFailedEntryDocument(
                target: target,
                inputs: inputs,
                failure: WorktreeRemovalFailureDocument(
                    kind: kind,
                    effects: effects,
                    stop: stop.map(WorktreeRefusalDocument.init(details:))
                )
            ))
    }

    func retainedBranch(
        _ name: String,
        assessment: BranchAssessment?
    ) -> WorktreeBranchDispositionDocument {
        WorktreeBranchDispositionDocument(
            name: name,
            commit: assessment?.commit,
            disposition: .retained
        )
    }

    func removalEffects(_ state: WorktreeRemovalEffectsState) -> WorktreeRemovalEffectsDocument {
        WorktreeRemovalEffectsDocument(
            directory: state.directory,
            administration: state.administration,
            branch: state.branch,
            evidence: state.evidence,
            assessment: state.assessment,
            activity: state.activity,
            lockResidue: state.lockResidue
        )
    }

}
