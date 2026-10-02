import AgentStudioGit
import Foundation

package struct WorktreeOperationRunner {
    private let client: any AgentStudioGitLocalClient
    private let defaultStartPointResolver: any WorktreeDefaultStartPointResolving
    private let remoteClient: any AgentStudioGitRemoteClient

    package init(
        client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient(),
        defaultStartPointResolver: any WorktreeDefaultStartPointResolving = SDKWorktreeDefaultStartPointResolver(),
        remoteClient: any AgentStudioGitRemoteClient = SystemGitRemoteClient()
    ) {
        self.client = client
        self.defaultStartPointResolver = defaultStartPointResolver
        self.remoteClient = remoteClient
    }

    package func run(_ request: WorktreeOperationRequest) async -> WorktreeOperationOutcome {
        switch request {
        case .createFromDefault(let start, let branch):
            return await createFromDefault(start: start, branch: branch)
        case .createFromBranch(let start, let branch, let startBranch):
            return await createFromBranch(start: start, branch: branch, startBranch: startBranch)
        case .fork(let start, let branch, let materialization):
            return await fork(start: start, branch: branch, materialization: materialization)
        case .list(let start, let callerDirectory, let targets, let fetchPolicy):
            return await list(
                start: start,
                callerDirectory: callerDirectory,
                targets: targets,
                fetchPolicy: fetchPolicy
            )
        case .remove(let removalRequest):
            let report = await WorktreeRemovalRunner(client: client, remoteClient: remoteClient).run(removalRequest)
            if let failure = report.fetchingReadFailure {
                return .fetchingReadFailure(failure)
            }
            return .removal(report)
        case .prune(let pruneRequest):
            return await WorktreePruneRunner(client: client, remoteClient: remoteClient).run(pruneRequest)
        }
    }

    private func createFromDefault(start: URL, branch: String) async -> WorktreeOperationOutcome {
        switch await preflightCreation(start: start, branch: branch, operation: .new) {
        case .outcome(let outcome):
            return outcome
        case .ready(let prepared):
            let startPoint: String
            do {
                switch try await defaultStartPointResolver.resolveDefaultStartPoint(
                    repositoryPath: prepared.repositoryPath)
                {
                case .resolved(_, let resolvedStartPoint):
                    startPoint = resolvedStartPoint
                case .noDefaultBranch:
                    return .refused(.noDefaultBranch)
                }
            } catch {
                return .failed(WorktreeOperationErrorMapper.readFailure(error))
            }
            return await createNewBranch(prepared, startPoint: startPoint)
        }
    }

    private func createFromBranch(
        start: URL,
        branch: String,
        startBranch: String
    ) async -> WorktreeOperationOutcome {
        switch await preflightCreation(start: start, branch: branch, operation: .new) {
        case .outcome(let outcome):
            return outcome
        case .ready(let prepared):
            guard prepared.branches.contains(where: { $0.name == startBranch }) else {
                return .refused(.startBranchNotFound(startBranch))
            }
            return await createNewBranch(prepared, startPoint: "refs/heads/\(startBranch)")
        }
    }

    private func createNewBranch(
        _ prepared: PreparedWorktreeCreation,
        startPoint: String
    ) async -> WorktreeOperationOutcome {
        do {
            let creation = try await client.createWorktree(
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
                    path: creation.worktree.canonicalPath,
                    repository: prepared.repositoryPath,
                    materialization: nil,
                    largeFiles: creation.largeFiles
                ))
        } catch {
            return .failed(WorktreeOperationErrorMapper.createFailure(error))
        }
    }

    private func fork(
        start: URL,
        branch: String,
        materialization: WorktreeForkMaterialization
    ) async -> WorktreeOperationOutcome {
        switch await preflightCreation(start: start, branch: branch, operation: .fork) {
        case .outcome(let outcome):
            return outcome
        case .ready(let prepared):
            let sdkMaterialization: GitWorktreeForkMaterialization
            switch materialization {
            case .copyOnWrite:
                sdkMaterialization = .copyOnWrite
            case .changesOnly:
                sdkMaterialization = .changesOnly
            }
            do throws(GitWorktreeForkError) {
                let fork = try await client.forkWorktree(
                    GitForkWorktreeRequest(
                        sourceWorktreePath: prepared.sourceWorktreePath,
                        destinationPath: prepared.destinationPath,
                        mode: .newBranch(name: prepared.branchName.rawValue),
                        materialization: sdkMaterialization
                    ))
                return .created(
                    WorktreeCreatedSummary(
                        operation: .fork,
                        branch: prepared.branchName.rawValue,
                        path: fork.worktree.canonicalPath,
                        repository: prepared.repositoryPath,
                        materialization: fork.materialization,
                        largeFiles: WorktreeLargeFilesProjector.fill(from: fork.materialization)
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

    private func list(
        start: URL,
        callerDirectory: URL?,
        targets: [String],
        fetchPolicy: WorktreeFetchPolicy
    ) async -> WorktreeOperationOutcome {
        switch await discover(start: start, forkSource: false) {
        case .outcome(let outcome):
            if case .failed = outcome {
                return .fetchingReadFailure(WorktreeFetchingReadFailure(fetch: .skipped(reason: .noTarget)))
            }
            return outcome
        case .found(let discovered):
            return await list(
                repositoryPath: discovered.repositoryPath,
                callerDirectory: callerDirectory,
                targets: targets,
                fetchPolicy: fetchPolicy
            )
        }
    }

    private func list(
        repositoryPath: URL,
        callerDirectory: URL?,
        targets: [String],
        fetchPolicy: WorktreeFetchPolicy
    ) async -> WorktreeOperationOutcome {
        let initialTarget: WorktreeIntegrationTarget?
        do {
            initialTarget = try await WorktreeIntegrationTargetResolver(client: client)
                .resolve(repositoryPath: repositoryPath)
        } catch {
            return .fetchingReadFailure(WorktreeFetchingReadFailure(fetch: .skipped(reason: .noTarget)))
        }

        let fetchResult = await WorktreeFetchStep(localClient: client, remoteClient: remoteClient).run(
            repositoryPath: repositoryPath,
            target: initialTarget,
            policy: fetchPolicy
        )

        do {
            let snapshots = try await client.worktrees(for: repositoryPath)
            let summary = await listingSummary(
                repositoryPath: repositoryPath,
                callerDirectory: callerDirectory,
                targets: targets,
                fetchResult: fetchResult,
                snapshots: snapshots
            )
            return .listed(summary)
        } catch {
            return .fetchingReadFailure(WorktreeFetchingReadFailure(fetch: fetchResult.status))
        }
    }

    private func listingSummary(
        repositoryPath: URL,
        callerDirectory: URL?,
        targets: [String],
        fetchResult: WorktreeFetchStepResult,
        snapshots: [GitWorktreeSnapshot]
    ) async -> WorktreeListingSummary {
        let selectedSnapshots = WorktreeListingProjector.filteredWorktrees(
            snapshots,
            targets: targets,
            callerDirectory: callerDirectory
        )
        let branchNames = branchNames(in: selectedSnapshots, excluding: fetchResult.target?.branchName)
        let gradesByBranch = await integrationGrades(
            repositoryPath: repositoryPath,
            branchNames: branchNames,
            target: fetchResult.target
        )
        let rows = await listingRows(
            selectedSnapshots,
            repositoryPath: repositoryPath,
            callerDirectory: callerDirectory,
            target: fetchResult.target,
            gradesByBranch: gradesByBranch
        )
        return WorktreeListingSummary(
            repository: repositoryPath,
            target: fetchResult.target.map {
                WorktreeListingTargetDocument(ref: $0.referenceName, commit: $0.commit)
            },
            fetch: fetchResult.status,
            worktrees: rows
        )
    }

    private func integrationGrades(
        repositoryPath: URL,
        branchNames: [String],
        target: WorktreeIntegrationTarget?
    ) async -> [String: GitBranchIntegrationGrade] {
        guard let target, !branchNames.isEmpty else { return [:] }
        do {
            let report = try await client.assessBranchIntegration(
                GitBranchIntegrationRequest(
                    repositoryPath: repositoryPath,
                    branchNames: branchNames,
                    targetCommit: target.commit,
                    squashSearchCommitLimit: WorktreeLifecyclePolicy.squashSearchCommitLimit
                ))
            return Dictionary(
                report.assessments.map { ($0.branchName, $0.grade) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            return Dictionary(
                uniqueKeysWithValues: branchNames.map {
                    ($0, GitBranchIntegrationGrade.unknown(.readFailed))
                }
            )
        }
    }

    private func listingRows(
        _ snapshots: [GitWorktreeSnapshot],
        repositoryPath: URL,
        callerDirectory: URL?,
        target: WorktreeIntegrationTarget?,
        gradesByBranch: [String: GitBranchIntegrationGrade]
    ) async -> [WorktreeListing] {
        let evidenceScanner = WorktreeTmpEvidenceScanner()
        var rows: [WorktreeListing] = []
        rows.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let status = try? await client.statusFacts(
                for: snapshot.canonicalPath,
                options: GitStatusOptions(includeIgnored: false, includeUntracked: true),
                observationPlan: nil
            )
            let evidence = await evidenceScanner.scan(worktreePath: snapshot.canonicalPath)
            let branch = WorktreeListingProjector.branchName(in: snapshot.head)
            rows.append(
                WorktreeListingProjector.listing(
                    WorktreeListingProjectionInput(
                        snapshot: snapshot,
                        repositoryPath: repositoryPath,
                        callerDirectory: callerDirectory,
                        target: target,
                        integrationGrade: branch.flatMap { gradesByBranch[$0] },
                        status: status,
                        evidence: evidence
                    )
                ))
        }
        return rows
    }

    private func branchNames(
        in snapshots: [GitWorktreeSnapshot],
        excluding targetBranch: String?
    ) -> [String] {
        Set(
            snapshots.compactMap { snapshot -> String? in
                guard let head = snapshot.head else { return nil }
                switch head.kind {
                case .branch, .unborn:
                    return head.shortName
                case .detached:
                    return nil
                }
            }.filter { $0 != targetBranch }
        ).sorted()
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

        let branches: [GitBranchSnapshot]
        do {
            branches = try await client.branches(for: discovery.repositoryPath)
            guard !branches.contains(where: { $0.name == branchName.rawValue }) else {
                return .outcome(.refused(.branchAlreadyExists(branchName.rawValue)))
            }
        } catch {
            return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
        }

        return .ready(
            PreparedWorktreeCreation(
                branchName: branchName,
                sourceWorktreePath: discovery.sourceWorktreePath,
                repositoryPath: discovery.repositoryPath,
                destinationPath: destinationPath,
                branches: branches
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
    let branches: [GitBranchSnapshot]
}

private enum WorktreeCreationPreparation {
    case ready(PreparedWorktreeCreation)
    case outcome(WorktreeOperationOutcome)
}
