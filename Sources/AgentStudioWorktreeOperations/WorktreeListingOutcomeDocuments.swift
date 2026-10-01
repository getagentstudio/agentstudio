import Foundation

package struct WorktreeListingTargetDocument: Codable, Sendable, Equatable {
    package let ref: String
    package let commit: String

    package init(ref: String, commit: String) {
        self.ref = ref
        self.commit = commit
    }
}

package enum WorktreeChangesStatusDocument: String, Codable, Sendable {
    case clean
    case dirty
    case unknown
}

package struct WorktreeChangesDocument: Codable, Sendable, Equatable {
    package let status: WorktreeChangesStatusDocument
    package let staged: Int?
    package let unstaged: Int?
    package let untracked: Int?
    package let conflicted: Int?

    package init(
        status: WorktreeChangesStatusDocument,
        staged: Int?,
        unstaged: Int?,
        untracked: Int?,
        conflicted: Int?
    ) {
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case staged
        case unstaged
        case untracked
        case conflicted
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(WorktreeChangesStatusDocument.self, forKey: .status)
        staged = try container.decodeIfPresent(Int.self, forKey: .staged)
        unstaged = try container.decodeIfPresent(Int.self, forKey: .unstaged)
        untracked = try container.decodeIfPresent(Int.self, forKey: .untracked)
        conflicted = try container.decodeIfPresent(Int.self, forKey: .conflicted)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(staged, forKey: .staged)
        try container.encode(unstaged, forKey: .unstaged)
        try container.encode(untracked, forKey: .untracked)
        try container.encode(conflicted, forKey: .conflicted)
    }
}

package enum WorktreeTmpEvidenceStatusDocument: String, Codable, Sendable {
    case empty
    case nonEmpty
    case unknown
}

package enum WorktreeListActivityDocument: Codable, Sendable, Equatable {
    case notChecked
    case openPanes(Int)

    private enum CodingKeys: String, CodingKey {
        case openPanes
    }

    package init(from decoder: any Decoder) throws {
        if let scalar = try? decoder.singleValueContainer(),
            let value = try? scalar.decode(String.self),
            value == "notChecked"
        {
            self = .notChecked
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .openPanes(try container.decode(Int.self, forKey: .openPanes))
    }

    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .notChecked:
            var container = encoder.singleValueContainer()
            try container.encode("notChecked")
        case .openPanes(let count):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(count, forKey: .openPanes)
        }
    }
}

package struct WorktreeListing: Codable, Sendable, Equatable {
    package let path: URL
    package let branch: String?
    package let isMain: Bool
    package let isCurrent: Bool
    package let isLocked: Bool
    package let changes: WorktreeChangesDocument
    package let integration: WorktreeIntegrationAssessmentDocument?
    package let tmp: WorktreeTmpEvidenceStatusDocument
    package let activity: WorktreeListActivityDocument
    package let removable: Bool
    package let blockers: [WorktreeRefusalDocument]
    package let remove: String?

    package init(
        path: URL,
        branch: String?,
        isMain: Bool,
        isCurrent: Bool,
        isLocked: Bool,
        changes: WorktreeChangesDocument,
        integration: WorktreeIntegrationAssessmentDocument?,
        tmp: WorktreeTmpEvidenceStatusDocument,
        activity: WorktreeListActivityDocument,
        removable: Bool,
        blockers: [WorktreeRefusalDocument],
        remove: String?
    ) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.isCurrent = isCurrent
        self.isLocked = isLocked
        self.changes = changes
        self.integration = integration
        self.tmp = tmp
        self.activity = activity
        self.removable = removable
        self.blockers = blockers
        self.remove = remove
    }

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

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = URL(fileURLWithPath: try container.decode(String.self, forKey: .path), isDirectory: true)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        isMain = try container.decode(Bool.self, forKey: .isMain)
        isCurrent = try container.decode(Bool.self, forKey: .isCurrent)
        isLocked = try container.decode(Bool.self, forKey: .isLocked)
        changes = try container.decode(WorktreeChangesDocument.self, forKey: .changes)
        integration = try container.decodeIfPresent(WorktreeIntegrationAssessmentDocument.self, forKey: .integration)
        tmp = try container.decode(WorktreeTmpEvidenceStatusDocument.self, forKey: .tmp)
        activity = try container.decode(WorktreeListActivityDocument.self, forKey: .activity)
        removable = try container.decode(Bool.self, forKey: .removable)
        blockers = try container.decode([WorktreeRefusalDocument].self, forKey: .blockers)
        remove = try container.decodeIfPresent(String.self, forKey: .remove)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path.standardizedFileURL.path, forKey: .path)
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

package struct WorktreeListingSummary: Codable, Sendable, Equatable {
    package let repository: URL
    package let target: WorktreeListingTargetDocument?
    package let fetch: WorktreeFetchStatus
    package let worktrees: [WorktreeListing]

    package init(
        repository: URL,
        target: WorktreeListingTargetDocument?,
        fetch: WorktreeFetchStatus,
        worktrees: [WorktreeListing]
    ) {
        self.repository = repository
        self.target = target
        self.fetch = fetch
        self.worktrees = worktrees
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case repository
        case target
        case fetch
        case worktrees
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        guard outcome == "listed" else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Expected a listed worktree outcome document."
            )
        }
        repository = URL(fileURLWithPath: try container.decode(String.self, forKey: .repository), isDirectory: true)
        target = try container.decodeIfPresent(WorktreeListingTargetDocument.self, forKey: .target)
        fetch = try container.decode(WorktreeFetchStatus.self, forKey: .fetch)
        worktrees = try container.decode([WorktreeListing].self, forKey: .worktrees)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("listed", forKey: .outcome)
        try container.encode(repository.standardizedFileURL.path, forKey: .repository)
        try container.encode(target, forKey: .target)
        try container.encode(fetch, forKey: .fetch)
        try container.encode(worktrees, forKey: .worktrees)
    }
}

package struct WorktreeListFailureDocument: Codable, Sendable, Equatable {
    package let fetch: WorktreeFetchStatus

    package init(fetch: WorktreeFetchStatus) {
        self.fetch = fetch
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case failure
        case leftovers
        case fetch
    }

    private struct Failure: Codable, Equatable {
        let kind: String
    }

    private struct Leftovers: Codable, Equatable {
        let status: String
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        let failure = try container.decode(Failure.self, forKey: .failure)
        let leftovers = try container.decode(Leftovers.self, forKey: .leftovers)
        guard outcome == "failed", failure.kind == "readFailed", leftovers.status == "notNeeded" else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Invalid worktree list failure outcome."
            )
        }
        fetch = try container.decode(WorktreeFetchStatus.self, forKey: .fetch)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("failed", forKey: .outcome)
        try container.encode(Failure(kind: "readFailed"), forKey: .failure)
        try container.encode(Leftovers(status: "notNeeded"), forKey: .leftovers)
        try container.encode(fetch, forKey: .fetch)
    }
}
