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
        let copyRules: GitWorktreeCopyRules
        switch request.materialization {
        case .trackedOnly(let startBranch):
            return await createTrackedOnly(prepared, startBranch: startBranch)
        case .changesOnly:
            copyRules = GitWorktreeCopyRules(ignoredPaths: .copyAll)
        case .copyOnWrite:
            do {
                let config = try await AgentStudioRepositoryConfigReader.read(mainWorktree: prepared.repositoryPath)
                let includePatterns = try config.worktree.compiledIncludePatterns(
                    configurationPath: prepared.repositoryPath.appending(path: ".agentstudio.config.json"))
                copyRules = GitWorktreeCopyRules(ignoredPaths: .copyMatching(includePatterns))
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
        return await copySource(
            prepared, source: source.sourceWorktreePath, request: request, copyRules: copyRules)
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
        _ prepared: PreparedWorktreeCreation, source: URL, request: WorktreeCreateRequest,
        copyRules: GitWorktreeCopyRules
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
                    mode: .newBranch(name: prepared.branchName.rawValue), materialization: sdkMaterialization,
                    copyRules: copyRules
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
