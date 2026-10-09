import Foundation

package enum WorktreeCreatedBranchStatus: String, Codable, Sendable {
    case created
    /// LR1 step (2): an existing local branch, opened as it was.
    case existing
    /// LR1 step (2): an existing local branch strictly behind its remote, moved up to it first.
    case fastForwarded
}

/// The branch a created worktree is on (LR31 `branch`).
package struct WorktreeCreatedBranch: Encodable, Sendable, Equatable {
    package let name: String
    package let status: WorktreeCreatedBranchStatus
    /// The branch's upstream as a full ref (`refs/remotes/origin/feat`), or nil when it has none.
    package let upstream: String?

    package init(name: String, status: WorktreeCreatedBranchStatus, upstream: String?) {
        self.name = name
        self.status = status
        self.upstream = upstream
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case status
        case upstream
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encode(upstream, forKey: .upstream)
    }
}

/// Where a created worktree's start commit came from (E16).
package enum WorktreeCreationStartSource: String, Codable, Sendable {
    case sourceHead
    case localBranch
    case remoteBranch
}

/// Commits the local branch used as the start has that its remote's branch lacks. Set only when
/// the local tip was kept over a remote branch that diverged from it or is behind it (LR1).
package struct WorktreeLocalOnlyCommits: Sendable, Equatable {
    package let count: Int
    /// The remote compared with, named in LR31's "kept local" note.
    package let remoteName: String

    package init(count: Int, remoteName: String) {
        self.count = count
        self.remoteName = remoteName
    }
}

/// The commit a created worktree's branch is at when its files are written, and where it came
/// from (LR31 `start`).
package struct WorktreeCreationStart: Encodable, Sendable, Equatable {
    /// The branch's resulting tip; nil only when the created worktree's HEAD couldn't be read back.
    package let commit: String?
    package let source: WorktreeCreationStartSource
    /// The full ref the start was read from (`refs/heads/x`, `refs/remotes/origin/x`); nil for the
    /// source's HEAD.
    package let reference: String?
    package let localOnlyCommits: WorktreeLocalOnlyCommits?

    package init(
        commit: String?,
        source: WorktreeCreationStartSource,
        reference: String?,
        localOnlyCommits: WorktreeLocalOnlyCommits?
    ) {
        self.commit = commit
        self.source = source
        self.reference = reference
        self.localOnlyCommits = localOnlyCommits
    }

    private enum CodingKeys: String, CodingKey {
        case commit
        case from
        case ref
        case localOnlyCommits
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commit, forKey: .commit)
        try container.encode(source, forKey: .from)
        try container.encode(reference, forKey: .ref)
        try container.encode(localOnlyCommits?.count, forKey: .localOnlyCommits)
    }
}
