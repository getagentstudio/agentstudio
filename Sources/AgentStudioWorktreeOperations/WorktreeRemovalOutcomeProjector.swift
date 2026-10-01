import AgentStudioGit
import Foundation

package enum WorktreeRemovalOutcomeProjector {
    package static func assessmentDocument(
        branchName: String?,
        target: WorktreeIntegrationTarget?,
        grade: GitBranchIntegrationGrade?
    ) -> WorktreeIntegrationAssessmentDocument? {
        guard let branchName else { return nil }
        guard let target else { return .unknown(.noTarget) }
        guard branchName != target.branchName else { return nil }
        guard let grade else { return .unknown(.readFailed) }

        return switch grade {
        case .integrated(let proof):
            switch proof {
            case .sameCommit:
                .integrated(.sameCommit)
            case .ancestor:
                .integrated(.ancestor)
            case .sameContent:
                .integrated(.sameContent)
            case .emptyDelta:
                .integrated(.emptyDelta)
            case .squash(let commit):
                .integrated(.squash(commit: commit))
            }
        case .hasRemainingContribution:
            .hasRemainingContribution
        case .unknown(let reason):
            switch reason {
            case .branchNotFound:
                .unknown(.branchNotFound)
            case .noMergeBase:
                .unknown(.noMergeBase)
            case .multipleMergeBases:
                .unknown(.multipleMergeBases)
            case .historyLimitReached:
                .unknown(.historyLimitReached)
            case .incompleteHistory:
                .unknown(.incompleteHistory)
            case .missingObjects:
                .unknown(.missingObjects)
            case .readFailed:
                .unknown(.readFailed)
            }
        }
    }

    package static func branchDocument(
        name: String,
        commit: String?,
        reason: WorktreeBranchRetentionReason,
        repositoryPath: URL,
        cleanupWarnings: [WorktreeBranchCleanupWarning] = []
    ) -> WorktreeBranchDispositionDocument {
        let normalizedReason: WorktreeBranchRetentionReason
        if case .checkedOut(let paths) = reason, paths.isEmpty {
            normalizedReason = .checkoutUnknown
        } else {
            normalizedReason = reason
        }
        return WorktreeBranchDispositionDocument(
            name: name,
            commit: commit,
            disposition: .retained,
            reason: normalizedReason,
            cleanupWarnings: cleanupWarnings,
            options: branchOptions(for: normalizedReason, branchName: name, repositoryPath: repositoryPath)
        )
    }

    package static func branchOptions(
        for reason: WorktreeBranchRetentionReason,
        branchName: String,
        repositoryPath: URL
    ) -> [String] {
        let repositoryArgument = WorktreeListingProjector.shellArgument(repositoryPath.standardizedFileURL.path)
        let branchArgument = WorktreeListingProjector.shellArgument(branchName)
        return switch reason {
        case .defaultBranch, .branchPolicyKeep:
            []
        case .hasRemainingContribution, .unknownAssessment:
            ["agentstudio worktree remove --repo \(repositoryArgument) \(branchArgument) -D"]
        case .movedSinceAssessment, .checkoutUnknown:
            ["agentstudio worktree remove --repo \(repositoryArgument) \(branchArgument)"]
        case .checkedOut(let worktreePaths):
            worktreePaths.map { path in
                "agentstudio worktree remove --repo \(repositoryArgument) \(WorktreeListingProjector.shellArgument(path))"
            }
        }
    }

    package static func deletedBranchDocument(
        name: String,
        commit: String?,
        cleanup: GitBranchMetadataCleanup
    ) -> WorktreeBranchDispositionDocument {
        var warnings: [WorktreeBranchCleanupWarning] = []
        if case .leftInPlace = cleanup.configuration {
            warnings.append(.configurationLeftInPlace)
        }
        if case .leftInPlace = cleanup.reflog {
            warnings.append(.reflogLeftInPlace)
        }
        return WorktreeBranchDispositionDocument(
            name: name,
            commit: commit,
            disposition: .deleted,
            cleanupWarnings: warnings
        )
    }

    package static func alreadyAbsentBranchDocument(
        name: String,
        commit: String?
    ) -> WorktreeBranchDispositionDocument {
        WorktreeBranchDispositionDocument(name: name, commit: commit, disposition: .alreadyAbsent)
    }

    package static func unknownBranchDocument(
        name: String,
        commit: String?
    ) -> WorktreeBranchDispositionDocument {
        WorktreeBranchDispositionDocument(name: name, commit: commit, disposition: .unknown)
    }
}
