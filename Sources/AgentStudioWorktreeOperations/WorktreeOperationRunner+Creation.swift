import AgentStudioGit
import Foundation

extension WorktreeOperationRunner {
    func create(_ request: WorktreeCreateRequest) async -> WorktreeOperationOutcome {
        if request.materialization == .changesOnly, request.source == .mainWorktree {
            return .refused(.creationStopped(.changesOnlyNeedsFrom))
        }
        if case .trackedOnly = request.materialization, case .worktree = request.source {
            return .refused(.creationStopped(.trackedOnlyExcludesSource))
        }
        let prepared: PreparedWorktreeCreation
        switch await preflightCreation(
            start: request.start, branch: request.branch, forkSource: request.source != .mainWorktree)
        {
        case .outcome(let outcome): return outcome
        case .ready(let value): prepared = value
        }
        let config: AgentStudioRepositoryConfig
        do {
            config = try await AgentStudioRepositoryConfigReader.read(mainWorktree: prepared.repositoryPath)
        } catch let stop as WorktreeCreationStop {
            return .refused(.creationStopped(stop))
        } catch {
            return .refused(
                .creationStopped(
                    .configInvalid(
                        path: prepared.repositoryPath.appending(path: ".agentstudio.config.json").path,
                        error: String(describing: error)
                    )))
        }
        if case .trackedOnly(let startBranch) = request.materialization {
            return await createTrackedOnly(prepared, startBranch: startBranch)
        }
        let source: WorktreeDiscovery
        let sourcePath: URL
        switch request.source {
        case .mainWorktree: sourcePath = prepared.repositoryPath
        case .worktree(let path): sourcePath = path
        }
        switch await discover(start: sourcePath, forkSource: true) {
        case .outcome(let outcome): return outcome
        case .found(let value): source = value
        }
        // --repo and --from must identify the same repository.
        guard source.repositoryPath == prepared.repositoryPath else {
            return .refused(.notInWorktree(sourcePath))
        }
        if request.materialization == .copyOnWrite {
            if request.source == .mainWorktree,
                let outcome = await defaultCopySourceRefusal(
                    source: source.sourceWorktreePath, repository: prepared.repositoryPath)
            {
                return outcome
            }
            // Stage A: only literal paths. The pinned SDK has no pattern grammar yet.
            let lockFiles = config.worktree.busyLocks.filter { !$0.contains(where: { "*?[".contains($0) }) }
                .map { source.sourceWorktreePath.appending(path: $0) }
            if let stop = await WorktreeSourceBusyLockProbe.refusal(lockFiles: lockFiles) {
                return .refused(.creationStopped(stop))
            }
        }
        return await copySource(prepared, source: source.sourceWorktreePath, request: request)
    }

    private func defaultCopySourceRefusal(source: URL, repository: URL) async -> WorktreeOperationOutcome? {
        do {
            let status = try await client.statusFacts(
                for: source, options: GitStatusOptions(includeIgnored: false, includeUntracked: true),
                observationPlan: nil
            )
            let facts = status.facts
            let conflicts = facts.entries.filter { $0.indexState == .unmerged || $0.worktreeState == .unmerged }.count
            if facts.summary.changedFileCount > 0 || facts.summary.stagedFileCount > 0
                || facts.summary.unstagedFileCount > 0 || facts.summary.untrackedFileCount > 0 || conflicts > 0
            {
                return .refused(
                    .creationStopped(
                        .sourceDirty(
                            WorktreeDirtyStopDetails(
                                staged: facts.summary.stagedFileCount, unstaged: facts.summary.unstagedFileCount,
                                untracked: facts.summary.untrackedFileCount, conflicted: conflicts,
                                firstPaths: Array(
                                    facts.entries.filter { !$0.ignored }.map(\.path).prefix(
                                        WorktreeLifecyclePolicy.firstPathsLimit))
                            ))))
            }
            let resolution = await WorktreeIntegrationTargetResolver(client: client).resolve(repositoryPath: repository)
            switch resolution {
            case .absent: return .refused(.noDefaultBranch)
            case .unreadable(_, let cause): return .failed(WorktreeOperationErrorMapper.readFailure(cause))
            case .resolved(let target):
                guard facts.head.kind == .branch, facts.head.shortName == target.branchName else {
                    return .refused(
                        .creationStopped(
                            .sourceNotOnDefaultBranch(
                                actual: facts.head.shortName, expected: target.branchName
                            )))
                }
            }
            return nil
        } catch {
            return .failed(WorktreeOperationErrorMapper.readFailure(error))
        }
    }

    private func createTrackedOnly(_ prepared: PreparedWorktreeCreation, startBranch: String?) async
        -> WorktreeOperationOutcome
    {
        let startPoint: String
        if let startBranch {
            guard prepared.branches.contains(where: { $0.name == startBranch }) else {
                return .refused(.startBranchNotFound(startBranch))
            }
            startPoint = "refs/heads/\(startBranch)"
        } else {
            do {
                switch try await defaultStartPointResolver.resolveDefaultStartPoint(
                    repositoryPath: prepared.repositoryPath)
                {
                case .noDefaultBranch: return .refused(.noDefaultBranch)
                case .resolved(_, let resolved): startPoint = resolved
                }
            } catch {
                return .failed(WorktreeOperationErrorMapper.readFailure(error))
            }
        }
        do {
            let creation = try await client.createWorktree(
                GitCreateWorktreeRequest(
                    repositoryPath: prepared.repositoryPath, destinationPath: prepared.destinationPath,
                    mode: .newBranch(name: prepared.branchName.rawValue, startPoint: .named(startPoint))
                ))
            return .created(
                WorktreeCreatedSummary(
                    operation: .new, branch: prepared.branchName.rawValue, path: creation.worktree.canonicalPath,
                    repository: prepared.repositoryPath, materialization: .trackedOnly(creation.largeFiles)
                ))
        } catch {
            return .failed(WorktreeOperationErrorMapper.createFailure(error))
        }
    }

    private func copySource(
        _ prepared: PreparedWorktreeCreation, source: URL, request: WorktreeCreateRequest
    ) async -> WorktreeOperationOutcome {
        let sdkMaterialization: GitWorktreeForkMaterialization
        switch request.materialization {
        case .copyOnWrite: sdkMaterialization = .copyOnWrite
        case .changesOnly: sdkMaterialization = .changesOnly
        case .trackedOnly: preconditionFailure("Tracked-only creation must use createWorktree.")
        }
        do throws(GitWorktreeForkError) {
            let fork = try await client.forkWorktree(
                GitForkWorktreeRequest(
                    sourceWorktreePath: source, destinationPath: prepared.destinationPath,
                    mode: .newBranch(name: prepared.branchName.rawValue), materialization: sdkMaterialization
                ))
            return .created(
                WorktreeCreatedSummary(
                    operation: .new, branch: prepared.branchName.rawValue, path: fork.worktree.canonicalPath,
                    repository: prepared.repositoryPath,
                    materialization: WorktreeCreatedMaterialization(fork.materialization)
                ))
        } catch {
            let outcome = WorktreeOperationErrorMapper.forkOutcome(
                error, destinationPath: prepared.destinationPath, branchName: prepared.branchName.rawValue)
            if case .refused(.forkUnavailable(let reason, _)) = outcome {
                return .refused(.forkUnavailable(reason, source: request.source))
            }
            return outcome
        }
    }
}
