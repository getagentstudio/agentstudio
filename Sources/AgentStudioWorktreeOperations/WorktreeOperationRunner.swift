import AgentStudioGit
import Foundation

package struct WorktreeOperationRunner {
    private let client: any AgentStudioGitLocalClient
    private let defaultStartPointResolver: any WorktreeDefaultStartPointResolving

    package init(
        client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient(),
        defaultStartPointResolver: any WorktreeDefaultStartPointResolving = SDKWorktreeDefaultStartPointResolver()
    ) {
        self.client = client
        self.defaultStartPointResolver = defaultStartPointResolver
    }

    package func run(_ request: WorktreeOperationRequest) async -> WorktreeOperationOutcome {
        switch request {
        case .createFromDefault(let start, let branch):
            await createFromDefault(start: start, branch: branch)
        case .fork(let start, let branch):
            await fork(start: start, branch: branch)
        case .list(let start):
            await list(start: start)
        }
    }

    private func createFromDefault(start: URL, branch: String) async -> WorktreeOperationOutcome {
        switch await preflightCreation(start: start, branch: branch, operation: .new) {
        case .outcome(let outcome):
            return outcome
        case .ready(let prepared):
            guard case .resolved(_, let startPoint) = prepared.defaultStartPoint else {
                return .refused(.noDefaultBranch)
            }
            do {
                let worktree = try await client.createWorktree(
                    GitCreateWorktreeRequest(
                        repositoryPath: prepared.repositoryPath,
                        destinationPath: prepared.destinationPath,
                        mode: .newBranch(
                            name: prepared.branchName.rawValue,
                            startPoint: GitRevisionTarget.named(startPoint)
                        )
                    ))
                return .created(
                    WorktreeCreatedSummary(
                        operation: .new,
                        branch: prepared.branchName.rawValue,
                        path: worktree.canonicalPath,
                        repository: prepared.repositoryPath,
                        materialization: nil
                    ))
            } catch {
                return .failed(WorktreeOperationErrorMapper.createFailure(error))
            }
        }
    }

    private func fork(start: URL, branch: String) async -> WorktreeOperationOutcome {
        switch await preflightCreation(start: start, branch: branch, operation: .fork) {
        case .outcome(let outcome):
            return outcome
        case .ready(let prepared):
            do throws(GitWorktreeForkError) {
                let fork = try await client.forkWorktree(
                    GitForkWorktreeRequest(
                        sourceWorktreePath: prepared.sourceWorktreePath,
                        destinationPath: prepared.destinationPath,
                        mode: .newBranch(name: prepared.branchName.rawValue),
                        materialization: .copyOnWrite
                    ))
                return .created(
                    WorktreeCreatedSummary(
                        operation: .fork,
                        branch: prepared.branchName.rawValue,
                        path: fork.worktree.canonicalPath,
                        repository: prepared.repositoryPath,
                        materialization: fork.materialization
                    ))
            } catch {
                return WorktreeOperationErrorMapper.forkOutcome(
                    error,
                    destinationPath: prepared.destinationPath,
                    branchName: prepared.branchName.rawValue
                )
            }
        }
    }

    private func list(start: URL) async -> WorktreeOperationOutcome {
        switch await discover(start: start, forkSource: false) {
        case .outcome(let outcome):
            return outcome
        case .found(let discovered):
            do {
                let worktrees = try await client.worktrees(for: discovered.repositoryPath)
                return .listed(
                    WorktreeListingSummary(
                        repository: discovered.repositoryPath,
                        worktrees: worktrees.map(worktreeListing)
                    ))
            } catch {
                return .failed(WorktreeOperationErrorMapper.readFailure(error))
            }
        }
    }

    private func preflightCreation(
        start: URL,
        branch: String,
        operation: WorktreeOperationKind
    ) async -> WorktreeCreationPreparation {
        let discovery: WorktreeDiscovery
        switch await discover(start: start, forkSource: operation == .fork) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let value):
            discovery = value
        }

        guard let mainWorktreePath = discovery.identity.mainWorktreePath?.standardizedFileURL else {
            return .outcome(.refused(.unsupportedRepositoryLayout(discovery.sourceWorktreePath)))
        }

        let branchName: WorktreeBranchName
        switch WorktreeBranchName.validated(branch) {
        case .success(let value):
            branchName = value
        case .failure(let rejection):
            return .outcome(.refused(.invalidBranchName(.local(rejection))))
        }

        guard
            let destinationPath = WorktreeDestinationNaming.siblingPath(
                repositoryPath: mainWorktreePath,
                branchName: branchName
            )
        else {
            return .outcome(.refused(.emptyBranchSlug))
        }

        if FileManager.default.fileExists(atPath: destinationPath.path) {
            return .outcome(.refused(.destinationExists(destinationPath)))
        }

        let destinationParent = destinationPath.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &parentIsDirectory),
            parentIsDirectory.boolValue
        else {
            return .outcome(.refused(.destinationParentMissing(destinationParent)))
        }

        do {
            let branches = try await client.branches(for: discovery.repositoryPath)
            guard !branches.contains(where: { $0.name == branchName.rawValue }) else {
                return .outcome(.refused(.branchAlreadyExists(branchName.rawValue)))
            }
        } catch {
            return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
        }

        var defaultStartPoint: WorktreeDefaultStartPoint = .noDefaultBranch
        if operation == .new {
            do {
                defaultStartPoint = try await defaultStartPointResolver.resolveDefaultStartPoint(
                    repositoryPath: discovery.repositoryPath)
            } catch {
                return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
            }
            guard defaultStartPoint != .noDefaultBranch else {
                return .outcome(.refused(.noDefaultBranch))
            }
        }

        return .ready(
            PreparedWorktreeCreation(
                branchName: branchName,
                sourceWorktreePath: discovery.sourceWorktreePath,
                repositoryPath: discovery.repositoryPath,
                destinationPath: destinationPath,
                defaultStartPoint: defaultStartPoint
            ))
    }

    private func discover(start: URL, forkSource: Bool) async -> WorktreeDiscoveryResult {
        let validation: GitWorktreeValidation
        do {
            validation = try await client.validateWorktree(GitValidateWorktreeRequest(worktreePath: start))
        } catch {
            return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
        }

        guard validation.isValid, let snapshot = validation.snapshot else {
            return .outcome(
                .refused(forkSource ? .notInWorktree(start) : .notInRepository(start)))
        }

        let sourceWorktreePath = snapshot.canonicalPath.standardizedFileURL
        let identity: GitRepositoryIdentity
        do {
            identity = try await client.repositoryIdentity(for: sourceWorktreePath)
        } catch {
            return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
        }

        return .found(
            WorktreeDiscovery(
                sourceWorktreePath: sourceWorktreePath,
                repositoryPath: identity.mainWorktreePath?.standardizedFileURL ?? sourceWorktreePath,
                identity: identity
            ))
    }

    private func worktreeListing(_ snapshot: GitWorktreeSnapshot) -> WorktreeListing {
        let branch: String?
        switch snapshot.head?.kind {
        case .branch, .unborn:
            branch = snapshot.head?.shortName
        case .detached, .none:
            branch = nil
        }
        return WorktreeListing(path: snapshot.canonicalPath, branch: branch, isMain: snapshot.isMainWorktree)
    }
}

private struct WorktreeDiscovery {
    let sourceWorktreePath: URL
    let repositoryPath: URL
    let identity: GitRepositoryIdentity
}

private enum WorktreeDiscoveryResult {
    case found(WorktreeDiscovery)
    case outcome(WorktreeOperationOutcome)
}

private struct PreparedWorktreeCreation {
    let branchName: WorktreeBranchName
    let sourceWorktreePath: URL
    let repositoryPath: URL
    let destinationPath: URL
    let defaultStartPoint: WorktreeDefaultStartPoint
}

private enum WorktreeCreationPreparation {
    case ready(PreparedWorktreeCreation)
    case outcome(WorktreeOperationOutcome)
}
