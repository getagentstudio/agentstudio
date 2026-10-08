import AgentStudioGit
import Foundation

extension WorktreeOperationRunner {
    /// `--no-fork`: a plain checkout of tracked files at the plan's start, with LR27's fill.
    func createCheckout(
        _ prepared: PreparedWorktreeCreation,
        sourceWorktreePath: URL,
        branch: WorktreeCreationBranchDecision
    ) async -> WorktreeOperationOutcome {
        let branchName = prepared.branchName.rawValue
        let mode: GitWorktreeCreateMode
        let plannedCommit: String
        switch branch.plan.target {
        case .newBranch(let start, let upstream):
            switch await checkoutStartCommit(start, sourceWorktreePath: sourceWorktreePath) {
            case .outcome(let outcome): return outcome
            case .ready(let commit): plannedCommit = commit
            }
            mode = .newBranch(name: branchName, startPoint: .named(plannedCommit), upstream: upstream)
        case .existingBranch(let expectedTip, let fastForwardTo):
            plannedCommit = fastForwardTo ?? expectedTip
            mode = .existingBranch(name: branchName, expectedTip: expectedTip, fastForwardTo: fastForwardTo)
        }
        do throws(GitDataPlaneError) {
            let creation = try await client.createWorktree(
                GitCreateWorktreeRequest(
                    repositoryPath: prepared.repositoryPath, destinationPath: prepared.destinationPath, mode: mode))
            return .created(
                createdSummary(
                    prepared, branch: branch, worktree: creation.worktree, plannedCommit: plannedCommit,
                    materialization: .checkout(creation.largeFiles)))
        } catch {
            return WorktreeOperationErrorMapper.createOutcome(error)
        }
    }

    /// A copy-on-write or changes-only fork of the source, attached to the plan's branch. A start other
    /// than the source's HEAD resets the copy to it (LR29).
    func createFork(
        _ prepared: PreparedWorktreeCreation,
        sourceWorktreePath: URL,
        request: WorktreeCreateRequest,
        copyRules: GitWorktreeCopyRules,
        branch: WorktreeCreationBranchDecision
    ) async -> WorktreeOperationOutcome {
        let branchName = prepared.branchName.rawValue
        let sdkMaterialization: GitWorktreeForkMaterialization
        switch request.materialization {
        case .copyOnWrite: sdkMaterialization = .copyOnWrite
        case .changesOnly: sdkMaterialization = .changesOnly
        case .checkout: preconditionFailure("A checkout must use createWorktree.")
        }
        let mode: GitForkWorktreeMode
        let plannedCommit: String?
        switch branch.plan.target {
        case .newBranch(let start, let upstream):
            mode = .newBranch(name: branchName, start: start, upstream: upstream)
            if case .commit(let commit) = start { plannedCommit = commit } else { plannedCommit = nil }
        case .existingBranch(let expectedTip, let fastForwardTo):
            mode = .existingBranch(name: branchName, expectedTip: expectedTip, fastForwardTo: fastForwardTo)
            plannedCommit = fastForwardTo ?? expectedTip
        }
        do throws(GitWorktreeForkError) {
            let fork = try await client.forkWorktree(
                GitForkWorktreeRequest(
                    sourceWorktreePath: sourceWorktreePath, destinationPath: prepared.destinationPath, mode: mode,
                    materialization: sdkMaterialization, copyRules: copyRules
                ))
            return .created(
                createdSummary(
                    prepared, branch: branch, worktree: fork.worktree, plannedCommit: plannedCommit,
                    materialization: WorktreeCreatedMaterialization(fork.materialization)))
        } catch {
            let outcome = WorktreeOperationErrorMapper.forkOutcome(
                error, destinationPath: prepared.destinationPath, branchName: branchName)
            if case .refused(.forkUnavailable(let reason, _), _) = outcome {
                return .refused(.forkUnavailable(reason, source: request.source))
            }
            return outcome
        }
    }

    /// `--no-fork` starts where the fork would: at the source checkout's HEAD commit. An unborn HEAD
    /// refuses as the plain checkout always has.
    private func checkoutStartCommit(
        _ start: GitForkStart,
        sourceWorktreePath: URL
    ) async -> WorktreeCreationStep<String> {
        switch start {
        case .commit(let commit):
            return .ready(commit)
        case .sourceHead:
            do throws(GitDataPlaneError) {
                let head = try await client.resolveRevision(
                    GitRevisionResolutionRequest(repositoryPath: sourceWorktreePath, target: .named("HEAD")))
                return .ready(head.oid)
            } catch {
                switch error {
                case .headUnavailable, .revisionUnavailable:
                    return .outcome(.refused(.noDefaultBranch))
                default:
                    if WorktreeReferenceRead.isNotFound(error) { return .outcome(.refused(.noDefaultBranch)) }
                    return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
                }
            }
        }
    }

    private func createdSummary(
        _ prepared: PreparedWorktreeCreation,
        branch: WorktreeCreationBranchDecision,
        worktree: GitWorktreeSnapshot,
        plannedCommit: String?,
        materialization: WorktreeCreatedMaterialization
    ) -> WorktreeCreatedSummary {
        let plan = branch.plan
        return WorktreeCreatedSummary(
            operation: .new,
            branch: WorktreeCreatedBranch(
                name: prepared.branchName.rawValue, status: plan.status, upstream: plan.upstreamReference),
            path: worktree.canonicalPath,
            repository: prepared.repositoryPath,
            materialization: materialization,
            start: WorktreeCreationStart(
                commit: worktree.head?.oid ?? plannedCommit,
                source: plan.startSource,
                reference: plan.startReference,
                localOnlyCommits: plan.localOnlyCommits
            ),
            fetch: branch.fetch
        )
    }
}
