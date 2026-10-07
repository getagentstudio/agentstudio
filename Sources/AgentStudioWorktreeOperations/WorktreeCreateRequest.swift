import AgentStudioGit
import Foundation

package struct WorktreeCreateRequest: Sendable, Equatable {
    package let start: URL
    package let branch: String
    package let source: WorktreeCreateSource
    package let materialization: WorktreeCreateMaterialization

    package init(
        start: URL, branch: String, source: WorktreeCreateSource, materialization: WorktreeCreateMaterialization
    ) {
        self.start = start
        self.branch = branch
        self.source = source
        self.materialization = materialization
    }
}

package enum WorktreeCreateSource: Sendable, Equatable {
    case mainWorktree
    case worktree(URL)
}

package enum WorktreeCreateMaterialization: Sendable, Equatable {
    case copyOnWrite
    case changesOnly
    case trackedOnly(startBranch: String?)
}

package enum WorktreeCreatedMaterialization: Sendable, Equatable {
    case copyOnWrite(GitWorktreeMaterializationReport)
    case changesOnly(GitChangesOnlyMaterializationReport)
    case trackedOnly(GitLargeFileFill)

    init(_ result: GitWorktreeMaterializationResult) {
        switch result {
        case .copyOnWrite(let report): self = .copyOnWrite(report)
        case .changesOnly(let report): self = .changesOnly(report)
        }
    }

    package var largeFiles: GitLargeFileFill? {
        switch self {
        case .copyOnWrite: nil
        case .changesOnly(let report): report.largeFiles
        case .trackedOnly(let fill): fill
        }
    }
}
