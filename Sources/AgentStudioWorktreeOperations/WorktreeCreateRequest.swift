import AgentStudioGit
import Foundation

package struct WorktreeCreateRequest: Sendable, Equatable {
    package let start: URL
    package let branch: String
    package let source: WorktreeCreateSource
    /// `--from-branch <start>` as typed: a local branch, `<remote>/<name>`, or origin's branch.
    package let startBranch: String?
    package let materialization: WorktreeCreateMaterialization
    package let fetchPolicy: WorktreeFetchPolicy

    package init(
        start: URL,
        branch: String,
        source: WorktreeCreateSource,
        startBranch: String?,
        materialization: WorktreeCreateMaterialization,
        fetchPolicy: WorktreeFetchPolicy
    ) {
        self.start = start
        self.branch = branch
        self.source = source
        self.startBranch = startBranch
        self.materialization = materialization
        self.fetchPolicy = fetchPolicy
    }
}

package enum WorktreeCreateSource: Sendable, Equatable {
    case mainWorktree
    case worktree(URL)
}

package enum WorktreeCreateMaterialization: Sendable, Equatable {
    case copyOnWrite
    /// `--no-fork`: a plain checkout of tracked files at the same start commit.
    case checkout
    case changesOnly
}

package enum WorktreeCreatedMaterialization: Sendable, Equatable {
    case copyOnWrite(GitWorktreeMaterializationReport)
    case changesOnly(GitChangesOnlyMaterializationReport)
    case checkout(GitLargeFileFill)

    init(_ result: GitWorktreeMaterializationResult) {
        switch result {
        case .copyOnWrite(let report): self = .copyOnWrite(report)
        case .changesOnly(let report): self = .changesOnly(report)
        }
    }

    package var largeFiles: GitLargeFileFill? {
        switch self {
        case .copyOnWrite(let report): report.largeFiles
        case .changesOnly(let report): report.largeFiles
        case .checkout(let fill): fill
        }
    }
}
