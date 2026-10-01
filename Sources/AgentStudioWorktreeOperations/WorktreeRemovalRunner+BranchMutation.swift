import AgentStudioGit
import Foundation

extension WorktreeRemovalRunner {
    func finishBranchDisposition(_ context: BranchDispositionContext) async -> WorktreeRemovalEntry {
        if let reason = branchRetentionReason(
            context.branchName,
            assessment: context.assessment,
            request: context.request,
            target: context.fetchTarget
        ) {
            return retainBranch(reason, context: context, commit: context.assessment?.commit)
        }

        guard let branchCommit = context.assessment?.commit else {
            return retainBranch(.unknownAssessment, context: context, commit: nil)
        }
        let deletion = await deleteBranchWithLockRecovery(
            context.branchName,
            expectedCommit: branchCommit,
            request: context.request,
            repositoryPath: context.repositoryPath
        )
        return branchDeletionEntry(deletion, expectedCommit: branchCommit, context: context)
    }

    private func retainBranch(
        _ reason: WorktreeBranchRetentionReason,
        context: BranchDispositionContext,
        commit: String?,
        lockResidue: [String]? = nil
    ) -> WorktreeRemovalEntry {
        let branch = WorktreeRemovalOutcomeProjector.branchDocument(
            name: context.branchName,
            commit: commit,
            reason: reason,
            repositoryPath: context.repositoryPath
        )
        return completedOrLockFailure(
            completion(context, branch: branch, lockResidue: lockResidue ?? context.completion.effects.lockResidue)
        )
    }

    private func branchDeletionEntry(
        _ deletion: BranchDeletionAttempt,
        expectedCommit: String,
        context: BranchDispositionContext
    ) -> WorktreeRemovalEntry {
        var lockResidue = Self.merging(
            context.completion.effects.lockResidue,
            Self.paths(deletion.failure?.lockResidue ?? [])
        )
        guard let result = deletion.result else {
            return branchDeletionFailure(
                deletion,
                expectedCommit: expectedCommit,
                lockResidue: lockResidue,
                context: context
            )
        }

        switch result {
        case .deleted(let cleanup, let residue):
            lockResidue = Self.merging(lockResidue, Self.paths(residue))
            let branch = WorktreeRemovalOutcomeProjector.deletedBranchDocument(
                name: context.branchName,
                commit: expectedCommit,
                cleanup: cleanup
            )
            return completedOrLockFailure(completion(context, branch: branch, lockResidue: lockResidue))
        case .retained(let reason, let residue):
            lockResidue = Self.merging(lockResidue, Self.paths(residue))
            let branch = retainedBranchDocument(reason, expectedCommit: expectedCommit, context: context)
            return completedOrLockFailure(completion(context, branch: branch, lockResidue: lockResidue))
        case .uncertain(let error, let residue):
            lockResidue = Self.merging(lockResidue, Self.paths(residue))
            let branch = WorktreeRemovalOutcomeProjector.unknownBranchDocument(
                name: context.branchName,
                commit: expectedCommit
            )
            let effects = removalEffects(completion(context, branch: branch, lockResidue: lockResidue).effects)
            return failedEntry(
                target: context.completion.target,
                inputs: context.completion.inputs,
                kind: .branchDeletionUncertain,
                effects: effects,
                stop: lockStopDetails(for: error)
            )
        }
    }

    private func branchDeletionFailure(
        _ deletion: BranchDeletionAttempt,
        expectedCommit: String,
        lockResidue: [String],
        context: BranchDispositionContext
    ) -> WorktreeRemovalEntry {
        guard let failure = deletion.failure else {
            let branch = WorktreeRemovalOutcomeProjector.unknownBranchDocument(
                name: context.branchName,
                commit: expectedCommit
            )
            let effects = removalEffects(completion(context, branch: branch, lockResidue: lockResidue).effects)
            return failedEntry(
                target: context.completion.target,
                inputs: context.completion.inputs,
                kind: .branchDeletionUncertain,
                effects: effects
            )
        }

        if case .checkoutUnreadable = failure.reason {
            return retainBranch(.checkoutUnknown, context: context, commit: expectedCommit, lockResidue: lockResidue)
        }
        let stop = deletion.lockStop ?? lockStopDetails(for: failure.reason, branchName: context.branchName)
        let branch = WorktreeBranchDispositionDocument(
            name: context.branchName,
            commit: expectedCommit,
            disposition: .retained
        )
        let effects = removalEffects(completion(context, branch: branch, lockResidue: lockResidue).effects)
        if stop != nil, !context.priorMutation, lockResidue.isEmpty, !deletion.removedStaleLock {
            return refusedEntry(target: context.completion.target, inputs: context.completion.inputs, stop: stop!)
        }
        return failedEntry(
            target: context.completion.target,
            inputs: context.completion.inputs,
            kind: .branchDeletionFailed(Self.branchDeletionErrorKind(failure.reason)),
            effects: effects,
            stop: stop
        )
    }

    private func retainedBranchDocument(
        _ reason: GitBranchRetentionReason,
        expectedCommit: String,
        context: BranchDispositionContext
    ) -> WorktreeBranchDispositionDocument {
        let document =
            switch reason {
            case .notFound:
                WorktreeRemovalOutcomeProjector.alreadyAbsentBranchDocument(
                    name: context.branchName,
                    commit: expectedCommit
                )
            case .moved(let currentCommit):
                WorktreeRemovalOutcomeProjector.branchDocument(
                    name: context.branchName,
                    commit: currentCommit,
                    reason: .movedSinceAssessment,
                    repositoryPath: context.repositoryPath
                )
            case .checkedOut(let worktreePaths):
                checkedOutBranchDocument(worktreePaths, expectedCommit: expectedCommit, context: context)
            }
        return document
    }

    private func checkedOutBranchDocument(
        _ worktreePaths: [URL],
        expectedCommit: String,
        context: BranchDispositionContext
    ) -> WorktreeBranchDispositionDocument {
        let paths = worktreePaths.map { $0.standardizedFileURL.path }
        return WorktreeRemovalOutcomeProjector.branchDocument(
            name: context.branchName,
            commit: expectedCommit,
            reason: paths.isEmpty ? .checkoutUnknown : .checkedOut(worktreePaths: paths),
            repositoryPath: context.repositoryPath
        )
    }

    private func completion(
        _ context: BranchDispositionContext,
        branch: WorktreeBranchDispositionDocument,
        lockResidue: [String]
    ) -> WorktreeRemovalCompletion {
        let effects = context.completion.effects
        return WorktreeRemovalCompletion(
            target: context.completion.target,
            inputs: context.completion.inputs,
            effects: WorktreeRemovalEffectsState(
                directory: effects.directory,
                administration: effects.administration,
                branch: branch,
                evidence: effects.evidence,
                assessment: effects.assessment,
                activity: effects.activity,
                lockResidue: lockResidue
            )
        )
    }

    func completedOrLockFailure(_ completion: WorktreeRemovalCompletion) -> WorktreeRemovalEntry {
        let effects = removalEffects(completion.effects)
        if completion.effects.lockResidue.isEmpty {
            return .removed(
                WorktreeRemovedEntryDocument(target: completion.target, inputs: completion.inputs, effects: effects)
            )
        }
        return failedEntry(
            target: completion.target,
            inputs: completion.inputs,
            kind: .lockCleanupIncomplete,
            effects: effects
        )
    }

    func deleteBranchWithLockRecovery(
        _ branchName: String,
        expectedCommit: String,
        request: WorktreeRemovalRequest,
        repositoryPath: URL
    ) async -> BranchDeletionAttempt {
        var removedStaleLock = false
        var lastFailure: GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>?
        for _ in 0..<4 {
            do {
                let result = try await client.deleteLocalBranch(
                    GitDeleteLocalBranchRequest(
                        repositoryPath: repositoryPath,
                        branchName: branchName,
                        expectedCommit: expectedCommit
                    ))
                return BranchDeletionAttempt(
                    result: result,
                    failure: nil,
                    lockStop: nil,
                    removedStaleLock: removedStaleLock
                )
            } catch {
                lastFailure = error
                let stop = lockStopDetails(for: error.reason, branchName: branchName)
                guard case .gitFailure(.lockHeld(let fact)) = error.reason else {
                    return BranchDeletionAttempt(
                        result: nil,
                        failure: error,
                        lockStop: stop,
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
                return BranchDeletionAttempt(
                    result: nil,
                    failure: error,
                    lockStop: .gitLockHeld(staleLockAssessment.inspect(fact).observation),
                    removedStaleLock: removedStaleLock
                )
            }
        }
        return BranchDeletionAttempt(
            result: nil,
            failure: lastFailure,
            lockStop: lastFailure.flatMap { lockStopDetails(for: $0.reason, branchName: branchName) },
            removedStaleLock: removedStaleLock
        )
    }

    func lockStopDetails(for error: GitDataPlaneError) -> WorktreeStopDetails? {
        switch error {
        case .lockHeld(let fact):
            .gitLockHeld(staleLockAssessment.inspect(fact).observation)
        case .lockUnidentified(let resource):
            .gitLockUnidentified(resource: resource)
        default:
            nil
        }
    }

    func lockStopDetails(
        for reason: GitDeleteLocalBranchErrorReason,
        branchName: String
    ) -> WorktreeStopDetails? {
        switch reason {
        case .refLockContended:
            .gitLockUnidentified(resource: .reference(name: "refs/heads/\(branchName)"))
        case .gitFailure(let error):
            lockStopDetails(for: error)
        case .invalidBranchName, .checkoutUnreadable, .notADirectCommitReference:
            nil
        }
    }

    static func branchDeletionErrorKind(_ reason: GitDeleteLocalBranchErrorReason) -> WorktreeGitErrorKind {
        switch reason {
        case .invalidBranchName, .notADirectCommitReference:
            .unsupported
        case .refLockContended:
            .lockUnidentified
        case .checkoutUnreadable:
            .worktreeNotFound
        case .gitFailure(let error):
            WorktreeOperationErrorMapper.gitErrorKind(for: error)
        }
    }

    static func paths(_ urls: [URL]) -> [String] {
        urls.map { $0.standardizedFileURL.path }
    }

    static func merging(_ first: [String], _ second: [String]) -> [String] {
        var result = first
        for path in second where !result.contains(path) {
            result.append(path)
        }
        return result
    }

}
