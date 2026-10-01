import AgentStudioGit
import Foundation

package protocol WorktreeActivityProbe: Sendable {
    func activity(forWorktreeAt canonicalPath: URL) async -> WorktreeActivityDocument
}

private struct WorktreeNotCheckedActivityProbe: WorktreeActivityProbe {
    func activity(forWorktreeAt _: URL) async -> WorktreeActivityDocument {
        .notChecked
    }
}

package struct WorktreeRemovalRunner: Sendable {
    struct RepositoryContext: Sendable {
        let repositoryPath: URL
        let commonDirectory: URL
        let mainWorktreePath: URL?
    }

    struct BranchAssessment: Sendable {
        let branchName: String
        let grade: GitBranchIntegrationGrade?
        let commit: String?
        let document: WorktreeIntegrationAssessmentDocument?
    }

    struct WorktreePreflight: Sendable {
        let stop: WorktreeStopDetails?
        let status: GitStatusFactsRead?
        let evidence: WorktreeTmpEvidenceScanResult
        let activity: WorktreeActivityDocument
        let archiveDestination: URL?
        let archiveDestinationStop: WorktreeStopDetails?
    }

    struct GitRemovalAttempt: Sendable {
        let result: GitWorktreeRemovalResult?
        let error: GitDataPlaneError?
        let lockStop: WorktreeStopDetails?
        let removedStaleLock: Bool
    }

    struct BranchDeletionAttempt: Sendable {
        let result: GitDeleteLocalBranchResult?
        let failure: GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>?
        let lockStop: WorktreeStopDetails?
        let removedStaleLock: Bool
    }

    struct WorktreeRemovalEffectsState: Sendable {
        let directory: WorktreeDirectoryEffect
        let administration: WorktreeAdministrationEffect
        let branch: WorktreeBranchDispositionDocument?
        let evidence: WorktreeEvidenceDispositionDocument
        let assessment: WorktreeIntegrationAssessmentDocument?
        let activity: WorktreeActivityDocument
        let lockResidue: [String]
    }

    struct WorktreeRemovalCompletion: Sendable {
        let target: String
        let inputs: [String]
        let effects: WorktreeRemovalEffectsState
    }

    struct BranchDispositionContext: Sendable {
        let branchName: String
        let request: WorktreeRemovalRequest
        let repositoryPath: URL
        let fetchTarget: WorktreeIntegrationTarget?
        let assessment: BranchAssessment?
        let completion: WorktreeRemovalCompletion
        let priorMutation: Bool
    }

    struct WorktreeRemovalExecutionContext: Sendable {
        let snapshot: GitWorktreeSnapshot
        let targetName: String
        let inputs: [String]
        let branchName: String?
        let assessment: BranchAssessment?
        let preflight: WorktreePreflight
        let request: WorktreeRemovalRequest
        let repository: RepositoryContext
        let fetchTarget: WorktreeIntegrationTarget?
    }

    struct WorktreePlanEntryRequest: Sendable {
        let target: String
        let inputs: [String]
        let isWorktree: Bool
        let request: WorktreeRemovalRequest
        let fetchStatus: WorktreeFetchStatus
        let preflight: WorktreePreflight?
        let assessment: BranchAssessment?
        let fetchTarget: WorktreeIntegrationTarget?
        let stop: WorktreeStopDetails?
        let wouldRemoveLockPaths: [String]
    }

    struct DryRunLockCheck: Sendable {
        let stop: WorktreeStopDetails?
        let wouldRemovePaths: [String]
    }

    let client: any AgentStudioGitLocalClient
    let remoteClient: any AgentStudioGitRemoteClient
    let activityProbe: any WorktreeActivityProbe
    let staleLockAssessment: WorktreeStaleLockAssessment
    let evidenceArchiver: WorktreeEvidenceArchiver

    package init(
        client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient(),
        remoteClient: any AgentStudioGitRemoteClient = SystemGitRemoteClient(),
        activityProbe: any WorktreeActivityProbe = WorktreeNotCheckedActivityProbe(),
        staleLockAssessment: WorktreeStaleLockAssessment = WorktreeStaleLockAssessment(),
        evidenceArchiver: WorktreeEvidenceArchiver = WorktreeEvidenceArchiver()
    ) {
        self.client = client
        self.remoteClient = remoteClient
        self.activityProbe = activityProbe
        self.staleLockAssessment = staleLockAssessment
        self.evidenceArchiver = evidenceArchiver
    }

    @concurrent
    package func run(_ request: WorktreeRemovalRequest) async -> WorktreeRemovalReport {
        guard let repository = await repositoryContext(start: request.start) else {
            return failureReport(fetch: .skipped(reason: .noTarget))
        }

        let initialTarget = try? await WorktreeIntegrationTargetResolver(client: client)
            .resolve(repositoryPath: repository.repositoryPath)
        let fetchResult = await WorktreeFetchStep(localClient: client, remoteClient: remoteClient).run(
            repositoryPath: repository.repositoryPath,
            target: initialTarget,
            policy: request.fetchPolicy
        )

        let worktrees: [GitWorktreeSnapshot]
        let branches: [GitBranchSnapshot]
        do {
            worktrees = try await client.worktrees(for: repository.repositoryPath)
            branches = try await client.branches(for: repository.repositoryPath)
        } catch {
            return failureReport(fetch: fetchResult.status)
        }

        let mainWorktreePath =
            repository.mainWorktreePath
            ?? worktrees.first(where: \.isMainWorktree)?.canonicalPath.standardizedFileURL
            ?? repository.repositoryPath
        let targets = WorktreeRemovalTargetResolver().resolve(
            request.targets,
            callerDirectory: request.callerDirectory,
            repositoryPath: mainWorktreePath,
            worktrees: worktrees,
            branches: branches
        )

        var entries: [WorktreeRemovalEntry] = []
        entries.reserveCapacity(targets.count)
        for target in targets {
            switch target {
            case .alreadyRemoved(let name, let inputs):
                if request.dryRun {
                    entries.append(
                        plannedEntry(
                            WorktreePlanEntryRequest(
                                target: name,
                                inputs: inputs,
                                isWorktree: false,
                                request: request,
                                fetchStatus: fetchResult.status,
                                preflight: nil,
                                assessment: nil,
                                fetchTarget: fetchResult.target,
                                stop: .alreadyRemoved(target: name),
                                wouldRemoveLockPaths: []
                            )
                        ))
                } else {
                    entries.append(.alreadyRemoved(WorktreeAlreadyRemovedEntryDocument(target: name, inputs: inputs)))
                }
            case .notFound(let name, let inputs):
                if request.dryRun {
                    entries.append(
                        plannedEntry(
                            WorktreePlanEntryRequest(
                                target: name,
                                inputs: inputs,
                                isWorktree: false,
                                request: request,
                                fetchStatus: fetchResult.status,
                                preflight: nil,
                                assessment: nil,
                                fetchTarget: fetchResult.target,
                                stop: .notFound(target: name),
                                wouldRemoveLockPaths: []
                            )
                        ))
                } else {
                    entries.append(
                        .refused(
                            WorktreeRefusedEntryDocument(
                                target: name,
                                inputs: inputs,
                                refusal: WorktreeRefusalDocument(details: .notFound(target: name))
                            )))
                }
            case .worktree(let snapshot, let inputs):
                entries.append(
                    await removeWorktree(
                        snapshot,
                        inputs: inputs,
                        request: request,
                        repository: repository,
                        fetchResult: fetchResult
                    ))
            case .branch(let branchName, let inputs):
                entries.append(
                    await removeBranch(
                        branchName,
                        inputs: inputs,
                        request: request,
                        repository: repository,
                        fetchResult: fetchResult
                    ))
            }
        }
        return WorktreeRemovalReport(entries: entries, fetch: fetchResult.status)
    }

    private func repositoryContext(start: URL) async -> RepositoryContext? {
        let validation: GitWorktreeValidation
        do {
            validation = try await client.validateWorktree(GitValidateWorktreeRequest(worktreePath: start))
        } catch {
            return nil
        }
        guard validation.isValid, let snapshot = validation.snapshot else { return nil }

        let identity: GitRepositoryIdentity
        do {
            identity = try await client.repositoryIdentity(for: snapshot.canonicalPath)
        } catch {
            return nil
        }

        let repositoryPath =
            identity.mainWorktreePath?.standardizedFileURL ?? snapshot.canonicalPath.standardizedFileURL
        return RepositoryContext(
            repositoryPath: repositoryPath,
            commonDirectory: identity.canonicalCommonDirectory.standardizedFileURL,
            mainWorktreePath: identity.mainWorktreePath?.standardizedFileURL
        )
    }

    private func failureReport(fetch: WorktreeFetchStatus) -> WorktreeRemovalReport {
        WorktreeRemovalReport(
            entries: [],
            fetch: fetch,
            fetchingReadFailure: WorktreeFetchingReadFailure(fetch: fetch)
        )
    }
}
