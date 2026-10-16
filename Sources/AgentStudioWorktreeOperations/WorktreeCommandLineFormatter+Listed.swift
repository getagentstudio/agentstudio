import Foundation

extension WorktreeCommandLineFormatter {
    package static func listedHumanLine(_ summary: WorktreeListingSummary) -> String {
        let rows = summary.worktrees.map { worktree in
            let kind = worktree.isMain ? "main" : "worktree"
            let changes = worktree.changes.status.rawValue
            let integration = humanIntegration(worktree.integration, branch: worktree.branch)
            return
                "\(kind) \(worktree.branch ?? "detached") at \(absolutePath(worktree.path))  \(changes)  \(integration)"
        }
        return ([fetchHumanLine(summary.fetch)] + rows).joined(separator: "\n")
    }

    package static func listedJSONText(_ summary: WorktreeListingSummary) throws -> String {
        let worktrees = summary.worktrees.map { worktree in
            WorktreeListingCommandLineJSON.Worktree(
                path: absolutePath(worktree.path),
                branch: worktree.branch,
                isMain: worktree.isMain,
                isCurrent: worktree.isCurrent,
                isLocked: worktree.isLocked,
                changes: worktree.changes,
                integration: worktree.integration,
                tmp: worktree.tmp,
                activity: worktree.activity,
                removable: worktree.removable,
                blockers: worktree.blockers,
                remove: worktree.remove
            )
        }
        return try encodeJSON(
            WorktreeListingCommandLineJSON(
                repository: absolutePath(summary.repository),
                target: summary.target,
                fetch: summary.fetch,
                worktrees: worktrees
            )
        )
    }

    private static func humanIntegration(
        _ integration: WorktreeIntegrationAssessmentDocument?,
        branch: String?
    ) -> String {
        guard let integration else { return branch == nil ? "detached" : "isTarget" }
        switch integration {
        case .integrated(let proof):
            switch proof {
            case .sameCommit:
                return "integrated (sameCommit)"
            case .ancestor:
                return "integrated (ancestor)"
            case .sameContent:
                return "integrated (sameContent)"
            case .emptyDelta:
                return "integrated (emptyDelta)"
            case .squash(let commit):
                return "integrated (squash \(commit))"
            }
        case .hasRemainingContribution:
            return "hasRemainingContribution"
        case .unknown(let reason):
            return "unknown (\(reason.rawValue))"
        }
    }

    package static func fetchingReadFailureHumanLine(_ failure: WorktreeFetchingReadFailure) -> String {
        "failed: readFailed; leftovers: notNeeded; \(fetchHumanLine(failure.fetch))"
    }
}

private struct WorktreeListingCommandLineJSON: Encodable {
    let outcome = "listed"
    let repository: String
    let target: WorktreeListingTargetDocument?
    let fetch: WorktreeFetchStatus
    let worktrees: [Worktree]

    private enum CodingKeys: String, CodingKey {
        case outcome
        case repository
        case target
        case fetch
        case worktrees
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(repository, forKey: .repository)
        try container.encode(target, forKey: .target)
        try container.encode(fetch, forKey: .fetch)
        try container.encode(worktrees, forKey: .worktrees)
    }

    struct Worktree: Encodable {
        let path: String
        let branch: String?
        let isMain: Bool
        let isCurrent: Bool
        let isLocked: Bool
        let changes: WorktreeChangesDocument
        let integration: WorktreeIntegrationAssessmentDocument?
        let tmp: WorktreeTmpEvidenceStatusDocument
        let activity: WorktreeListActivityDocument
        let removable: Bool
        let blockers: [WorktreeRefusalDocument]
        let remove: String?

        private enum CodingKeys: String, CodingKey {
            case path
            case branch
            case isMain
            case isCurrent
            case isLocked
            case changes
            case integration
            case tmp
            case activity
            case removable
            case blockers
            case remove
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(branch, forKey: .branch)
            try container.encode(isMain, forKey: .isMain)
            try container.encode(isCurrent, forKey: .isCurrent)
            try container.encode(isLocked, forKey: .isLocked)
            try container.encode(changes, forKey: .changes)
            try container.encode(integration, forKey: .integration)
            try container.encode(tmp, forKey: .tmp)
            try container.encode(activity, forKey: .activity)
            try container.encode(removable, forKey: .removable)
            try container.encode(blockers, forKey: .blockers)
            try container.encode(remove, forKey: .remove)
        }
    }
}
