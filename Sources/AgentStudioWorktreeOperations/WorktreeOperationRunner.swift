import AgentStudioGit
import Foundation

package struct WorktreeOperationRunner {
    let client: any AgentStudioGitLocalClient
    let defaultStartPointResolver: any WorktreeDefaultStartPointResolving
    private let remoteClient: any AgentStudioGitRemoteClient
    private let staleLockAssessment: WorktreeStaleLockAssessment

    package init(
        client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient(),
        defaultStartPointResolver: any WorktreeDefaultStartPointResolving = SDKWorktreeDefaultStartPointResolver(),
        remoteClient: any AgentStudioGitRemoteClient = SystemGitRemoteClient(),
        staleLockAssessment: WorktreeStaleLockAssessment = WorktreeStaleLockAssessment()
    ) {
        self.client = client
        self.defaultStartPointResolver = defaultStartPointResolver
        self.remoteClient = remoteClient
        self.staleLockAssessment = staleLockAssessment
    }

    package func run(_ request: WorktreeOperationRequest) async -> WorktreeOperationOutcome {
        switch request {
        case .create(let creationRequest):
            return await create(creationRequest)
        case .list(let start, let callerDirectory, let targets, let fetchPolicy):
            return await list(
                start: start,
                callerDirectory: callerDirectory,
                targets: targets,
                fetchPolicy: fetchPolicy
            )
        case .remove(let removalRequest):
            let report = await WorktreeRemovalRunner(
                client: client,
                remoteClient: remoteClient,
                staleLockAssessment: staleLockAssessment
            ).run(removalRequest)
            if let failure = report.fetchingReadFailure {
                return .fetchingReadFailure(failure)
            }
            return .removal(report)
        case .prune(let pruneRequest):
            return await WorktreePruneRunner(client: client, remoteClient: remoteClient).run(pruneRequest)
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
                commonDirectory: discovered.identity.canonicalCommonDirectory,
                callerDirectory: callerDirectory,
                targets: targets,
                fetchPolicy: fetchPolicy
            )
        }
    }

    private func list(
        repositoryPath: URL,
        commonDirectory: URL,
        callerDirectory: URL?,
        targets: [String],
        fetchPolicy: WorktreeFetchPolicy
    ) async -> WorktreeOperationOutcome {
        let targetResolution = await WorktreeIntegrationTargetResolver(client: client)
            .resolve(repositoryPath: repositoryPath)

        let fetchResult = await WorktreeFetchStep(localClient: client, remoteClient: remoteClient).run(
            repositoryPath: repositoryPath,
            resolution: targetResolution,
            policy: fetchPolicy
        )

        do {
            let snapshots = try await client.worktrees(for: repositoryPath)
            let summary = await listingSummary(
                repositoryPath: repositoryPath,
                commonDirectory: commonDirectory,
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
        commonDirectory: URL,
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
        let branchNames = branchNames(in: selectedSnapshots, excluding: fetchResult.resolution.branchName)
        let gradesByBranch = await integrationGrades(
            repositoryPath: repositoryPath,
            branchNames: branchNames,
            resolution: fetchResult.resolution
        )
        let rows = await listingRows(
            selectedSnapshots,
            repositoryPath: repositoryPath,
            commonDirectory: commonDirectory,
            callerDirectory: callerDirectory,
            targetResolution: fetchResult.resolution,
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
        resolution: WorktreeIntegrationTargetResolution
    ) async -> [String: GitBranchIntegrationGrade] {
        guard !branchNames.isEmpty else { return [:] }
        if resolution.hasReadFailure {
            return Dictionary(
                uniqueKeysWithValues: branchNames.map { ($0, GitBranchIntegrationGrade.unknown(.readFailed)) }
            )
        }
        guard let target = resolution.target else { return [:] }
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
        commonDirectory: URL,
        callerDirectory: URL?,
        targetResolution: WorktreeIntegrationTargetResolution,
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
            let integrationGrade = branch.flatMap { gradesByBranch[$0] }
            let lockObservations = await listingLockObservations(
                snapshot: snapshot,
                commonDirectory: commonDirectory,
                branch: branch,
                targetResolution: targetResolution,
                integrationGrade: integrationGrade
            )
            rows.append(
                WorktreeListingProjector.listing(
                    WorktreeListingProjectionInput(
                        snapshot: snapshot,
                        repositoryPath: repositoryPath,
                        callerDirectory: callerDirectory,
                        targetResolution: targetResolution,
                        integrationGrade: integrationGrade,
                        status: status,
                        evidence: evidence,
                        lockObservations: lockObservations
                    )
                ))
        }
        return rows
    }

    @concurrent
    private func listingLockObservations(
        snapshot: GitWorktreeSnapshot,
        commonDirectory: URL,
        branch: String?,
        targetResolution: WorktreeIntegrationTargetResolution,
        integrationGrade: GitBranchIntegrationGrade?
    ) async -> [WorktreeLockObservation] {
        guard !snapshot.isMainWorktree else { return [] }
        var facts = [
            GitLockFact(
                path: URL(fileURLWithPath: snapshot.indexPath.path + ".lock"),
                resource: .index(worktreePath: snapshot.canonicalPath)
            )
        ]
        if let branch,
            !targetResolution.hasUnreadableBranchName,
            branch != targetResolution.branchName,
            case .integrated? = integrationGrade
        {
            let referenceName = "refs/heads/\(branch)"
            facts.append(
                GitLockFact(
                    path: commonDirectory.appending(path: "\(referenceName).lock"),
                    resource: .reference(name: referenceName)
                ))
            facts.append(GitLockFact(path: commonDirectory.appending(path: "packed-refs.lock"), resource: .packedRefs))
        }

        return facts.compactMap { fact in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fact.path.path),
                attributes[.type] as? FileAttributeType == .typeRegular
            else {
                return nil
            }
            return staleLockAssessment.inspect(fact).observation
        }
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

    func discover(start: URL, forkSource: Bool) async -> WorktreeDiscoveryResult {
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

struct WorktreeDiscovery {
    let sourceWorktreePath: URL
    let repositoryPath: URL
    let identity: GitRepositoryIdentity
}

enum WorktreeDiscoveryResult {
    case found(WorktreeDiscovery)
    case outcome(WorktreeOperationOutcome)
}
