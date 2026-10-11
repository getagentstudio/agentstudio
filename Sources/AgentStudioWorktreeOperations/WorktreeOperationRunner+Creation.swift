import AgentStudioGit
import Foundation

extension WorktreeOperationRunner {
    /// LR1: copy the source, then set the branch. Every check before the SDK call is read-only; the
    /// one write before it is LR30's reported fetch.
    func create(_ request: WorktreeCreateRequest) async -> WorktreeOperationOutcome {
        if request.materialization == .changesOnly, request.source == .mainWorktree {
            return .refused(.creationStopped(.changesOnlyNeedsFrom))
        }
        let prepared: PreparedWorktreeCreation
        switch await preflightCreation(
            start: request.start, branch: request.branch, forkSource: request.source != .mainWorktree)
        {
        case .outcome(let outcome): return outcome
        case .ready(let value): prepared = value
        }

        let copyRules: GitWorktreeCopyRules?
        switch await creationCopyRules(request.materialization, mainWorktree: prepared.repositoryPath) {
        case .outcome(let outcome): return outcome
        case .ready(let rules): copyRules = rules
        }

        let sourceWorktreePath: URL
        switch await creationSource(request, prepared: prepared) {
        case .outcome(let outcome): return outcome
        case .ready(let path): sourceWorktreePath = path
        }

        let branchRequest = WorktreeCreationBranchRequest(
            branch: prepared.branchName.rawValue,
            create: request.create,
            startBranch: request.startBranch,
            changesOnly: request.materialization == .changesOnly
        )
        let branch: WorktreeCreationBranchDecision
        switch await decideBranch(branchRequest, prepared: prepared, fetchPolicy: request.fetchPolicy) {
        case .outcome(let outcome): return outcome
        case .ready(let decision): branch = decision
        }

        // LR30: once the fetch has run, a refusal or failure still reports it.
        guard let copyRules else {
            return await createCheckout(prepared, sourceWorktreePath: sourceWorktreePath, branch: branch)
                .carryingCreationFetch(branch.fetch)
        }
        return await createFork(
            prepared, sourceWorktreePath: sourceWorktreePath, request: request, copyRules: copyRules,
            branch: branch
        ).carryingCreationFetch(branch.fetch)
    }

    /// The worktree whose files are copied, or whose HEAD a plain checkout starts at. Preflight
    /// already found the main worktree; a fork re-validates its source as a worktree root, and
    /// `--from` must name a worktree of the same repository as `--repo`.
    private func creationSource(
        _ request: WorktreeCreateRequest,
        prepared: PreparedWorktreeCreation
    ) async -> WorktreeCreationStep<URL> {
        let sourcePath: URL
        switch request.source {
        case .mainWorktree:
            guard request.materialization != .checkout else { return .ready(prepared.repositoryPath) }
            sourcePath = prepared.repositoryPath
        case .worktree(let path):
            sourcePath = path
        }
        switch await discover(start: sourcePath, forkSource: true) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let source):
            guard source.repositoryPath == prepared.repositoryPath else {
                return .outcome(.refused(.notInWorktree(sourcePath)))
            }
            return .ready(source.sourceWorktreePath)
        }
    }

    /// The copy rules a fork needs: none for a plain checkout, everything for changes-only, and the
    /// repository's declared includes for copy-on-write (read only then, so `--no-fork` stays the way
    /// past a bad config).
    private func creationCopyRules(
        _ materialization: WorktreeCreateMaterialization,
        mainWorktree: URL
    ) async -> WorktreeCreationStep<GitWorktreeCopyRules?> {
        let configurationPath = mainWorktree.appending(path: ".agentstudio.config.json")
        switch materialization {
        case .checkout:
            return .ready(nil)
        case .changesOnly:
            return .ready(GitWorktreeCopyRules(ignoredPaths: .copyAll))
        case .copyOnWrite:
            do {
                let config = try await AgentStudioRepositoryConfigReader.read(mainWorktree: mainWorktree)
                let includePatterns = try config.worktree.compiledIncludePatterns(
                    configurationPath: configurationPath)
                return .ready(GitWorktreeCopyRules(ignoredPaths: .copyMatching(includePatterns)))
            } catch let stop as WorktreeCreationStop {
                return .outcome(.refused(.creationStopped(stop)))
            } catch {
                return .outcome(
                    .refused(
                        .creationStopped(
                            .configInvalid(path: configurationPath.path, error: String(describing: error)))))
            }
        }
    }

    /// `-c`'s name check (D23), LR30's fetch, then the branch resolution. LR1 step (1) already ran in preflight.
    private func decideBranch(
        _ branchRequest: WorktreeCreationBranchRequest,
        prepared: PreparedWorktreeCreation,
        fetchPolicy: WorktreeFetchPolicy
    ) async -> WorktreeCreationStep<WorktreeCreationBranchDecision> {
        let resolver = WorktreeCreationBranchResolver(client: client)
        let fetchStep = WorktreeCreationFetchStep(remoteClient: remoteClient)
        let remoteNames: [String]
        do throws(GitDataPlaneError) {
            remoteNames = try await client.remoteNames(for: prepared.repositoryPath)
        } catch {
            return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
        }

        let fetchTarget = WorktreeCreationBranchResolver.fetchTarget(
            for: branchRequest, remoteNames: remoteNames, fetchPolicy: fetchPolicy)
        let fetch: WorktreeCreationFetchStatus
        if branchRequest.create {
            switch await resolver.checkNameIsFree(
                branchRequest.branch, repositoryPath: prepared.repositoryPath, localBranches: prepared.branches,
                originAnswer: await originNameAnswer(
                    branchRequest.branch, prepared: prepared, remoteNames: remoteNames, fetchPolicy: fetchPolicy,
                    fetchStep: fetchStep))
            {
            case .refused(let stop):
                return .outcome(.refused(.creationStopped(stop)))
            case .unreadable(let error):
                return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
            case .free(let originAnswer) where branchRequest.startBranch == nil && !branchRequest.changesOnly:
                // With nothing to refresh, origin's answer about the name is the creation fetch.
                fetch = originAnswer
            case .free:
                fetch = await fetchStep.run(repositoryPath: prepared.repositoryPath, target: fetchTarget)
            }
        } else {
            fetch = await fetchStep.run(repositoryPath: prepared.repositoryPath, target: fetchTarget)
        }
        switch await resolver.resolve(
            branchRequest, repositoryPath: prepared.repositoryPath, localBranches: prepared.branches,
            remoteNames: remoteNames, fetch: fetch)
        {
        case .planned(let plan):
            return .ready(WorktreeCreationBranchDecision(plan: plan, fetch: fetch))
        case .refused(let refusal):
            return .outcome(.refused(refusal, creationFetch: fetch))
        case .unreadable(let error):
            return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)).carryingCreationFetch(fetch))
        }
    }

    /// Asks origin about `-c`'s name, unless `--no-fetch` or there is no origin. It fetches nothing (LR30).
    private func originNameAnswer(
        _ branch: String,
        prepared: PreparedWorktreeCreation,
        remoteNames: [String],
        fetchPolicy: WorktreeFetchPolicy,
        fetchStep: WorktreeCreationFetchStep
    ) async -> WorktreeOriginNameAnswer {
        let origin = WorktreeStartReference.defaultRemoteName
        guard fetchPolicy == .fetch else { return .notAskedNoFetch(originConfigured: remoteNames.contains(origin)) }
        guard remoteNames.contains(origin) else { return .noOrigin }
        return .asked(
            await fetchStep.probe(repositoryPath: prepared.repositoryPath, remoteName: origin, branchName: branch))
    }
}

/// A creation step either yields its value or ends the call with an outcome.
enum WorktreeCreationStep<Value> {
    case ready(Value)
    case outcome(WorktreeOperationOutcome)
}

/// The resolved branch plan and the fetch it was resolved after.
struct WorktreeCreationBranchDecision {
    let plan: WorktreeBranchPlan
    let fetch: WorktreeCreationFetchStatus
}
