import AgentStudioGit
import Foundation

private struct WorktreePruneNotCheckedActivityProbe: WorktreeActivityProbe {
    func activity(forWorktreeAt _: URL) async -> WorktreeActivityDocument {
        .notChecked
    }
}

package struct WorktreePruneRunner: Sendable {
    struct RepositoryContext: Sendable {
        let repositoryPath: URL
        let commonDirectory: URL
        let mainWorktreePath: URL?
    }

    struct BranchAssessment: Sendable {
        let branchName: String
        let grade: GitBranchIntegrationGrade?
        let commit: String?
        let document: WorktreeIntegrationAssessmentDocument
    }

    let client: any AgentStudioGitLocalClient
    let remoteClient: any AgentStudioGitRemoteClient
    let activityProbe: any WorktreeActivityProbe
    let staleLockAssessment: WorktreeStaleLockAssessment
    let evidenceArchiver: WorktreeEvidenceArchiver

    package init(
        client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient(),
        remoteClient: any AgentStudioGitRemoteClient = SystemGitRemoteClient(),
        activityProbe: any WorktreeActivityProbe = WorktreePruneNotCheckedActivityProbe(),
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
    package func run(_ request: WorktreePruneRequest) async -> WorktreeOperationOutcome {
        guard let repository = await repositoryContext(start: request.start) else {
            return .fetchingReadFailure(
                WorktreeFetchingReadFailure(fetch: .skipped(reason: .noTarget))
            )
        }

        let targetResolution = await WorktreeIntegrationTargetResolver(client: client)
            .resolve(repositoryPath: repository.repositoryPath)

        let fetchResult = await WorktreeFetchStep(localClient: client, remoteClient: remoteClient).run(
            repositoryPath: repository.repositoryPath,
            resolution: targetResolution,
            policy: request.fetchPolicy
        )

        let snapshots: [GitWorktreeSnapshot]
        do {
            snapshots = try await client.worktrees(for: repository.repositoryPath)
        } catch {
            return .fetchingReadFailure(WorktreeFetchingReadFailure(fetch: fetchResult.status))
        }

        let linkedWorktrees = snapshots.filter { !$0.isMainWorktree }
        let branchNames = Set(
            linkedWorktrees.compactMap { WorktreeListingProjector.branchName(in: $0.head) }
                .filter { $0 != fetchResult.resolution.branchName }
        ).sorted()
        let assessments = await branchAssessments(
            branchNames: branchNames,
            repositoryPath: repository.repositoryPath,
            resolution: fetchResult.resolution
        )
        let mainWorktreePath =
            repository.mainWorktreePath
            ?? snapshots.first(where: \.isMainWorktree)?.canonicalPath.standardizedFileURL
            ?? repository.repositoryPath
        let removalRepository = WorktreeRemovalRunner.RepositoryContext(
            repositoryPath: repository.repositoryPath,
            commonDirectory: repository.commonDirectory,
            mainWorktreePath: mainWorktreePath
        )
        let removalRunner = WorktreeRemovalRunner(
            client: client,
            remoteClient: remoteClient,
            activityProbe: activityProbe,
            staleLockAssessment: staleLockAssessment,
            evidenceArchiver: evidenceArchiver
        )
        let entryContext = WorktreePruneEntryContext(
            targetResolution: fetchResult.resolution,
            request: request,
            repository: removalRepository,
            mainWorktreePath: mainWorktreePath,
            removalRunner: removalRunner
        )

        var entries: [WorktreePruneEntry] = []
        entries.reserveCapacity(linkedWorktrees.count)
        for snapshot in linkedWorktrees {
            let assessment = WorktreeListingProjector.branchName(in: snapshot.head)
                .flatMap { assessments[$0] }
            entries.append(
                await pruneEntry(
                    snapshot,
                    assessment: assessment,
                    context: entryContext
                )
            )
        }

        return .pruned(
            WorktreePruneSummary(
                target: fetchResult.target.map {
                    WorktreeListingTargetDocument(ref: $0.referenceName, commit: $0.commit)
                },
                fetch: fetchResult.status,
                applied: request.apply,
                entries: entries
            )
        )
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

        return RepositoryContext(
            repositoryPath: identity.mainWorktreePath?.standardizedFileURL
                ?? snapshot.canonicalPath.standardizedFileURL,
            commonDirectory: identity.canonicalCommonDirectory.standardizedFileURL,
            mainWorktreePath: identity.mainWorktreePath?.standardizedFileURL
        )
    }

    private func branchAssessments(
        branchNames: [String],
        repositoryPath: URL,
        resolution: WorktreeIntegrationTargetResolution
    ) async -> [String: BranchAssessment] {
        guard !branchNames.isEmpty else { return [:] }
        if resolution.hasReadFailure {
            return Dictionary(
                uniqueKeysWithValues: branchNames.map { branchName in
                    (
                        branchName,
                        assessment(
                            branchName: branchName,
                            grade: .unknown(.readFailed),
                            commit: nil,
                            resolution: resolution
                        )
                    )
                }
            )
        }
        let target = resolution.target
        guard let target else {
            return Dictionary(
                uniqueKeysWithValues: branchNames.map { branchName in
                    (branchName, assessment(branchName: branchName, grade: nil, commit: nil, resolution: resolution))
                }
            )
        }

        let gradesByBranch: [String: (grade: GitBranchIntegrationGrade, commit: String?)]
        do {
            let report = try await client.assessBranchIntegration(
                GitBranchIntegrationRequest(
                    repositoryPath: repositoryPath,
                    branchNames: branchNames,
                    targetCommit: target.commit,
                    squashSearchCommitLimit: WorktreeLifecyclePolicy.squashSearchCommitLimit
                ))
            gradesByBranch = Dictionary(
                report.assessments.map { ($0.branchName, ($0.grade, $0.branchCommit)) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            gradesByBranch = Dictionary(
                uniqueKeysWithValues: branchNames.map { ($0, (.unknown(.readFailed), nil)) }
            )
        }

        return Dictionary(
            uniqueKeysWithValues: branchNames.map { branchName in
                let result = gradesByBranch[branchName] ?? (.unknown(.branchNotFound), nil)
                return (
                    branchName,
                    assessment(
                        branchName: branchName,
                        grade: result.grade,
                        commit: result.commit,
                        resolution: resolution
                    )
                )
            }
        )
    }

    private func assessment(
        branchName: String,
        grade: GitBranchIntegrationGrade?,
        commit: String?,
        resolution: WorktreeIntegrationTargetResolution
    ) -> BranchAssessment {
        BranchAssessment(
            branchName: branchName,
            grade: grade,
            commit: commit,
            document: WorktreeRemovalOutcomeProjector.assessmentDocument(
                branchName: branchName,
                resolution: resolution,
                grade: grade
            ) ?? .unknown(.readFailed)
        )
    }
}
