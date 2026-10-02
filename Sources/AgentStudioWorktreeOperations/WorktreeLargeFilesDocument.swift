import AgentStudioGit
import Foundation

package struct WorktreeLargeFilesDocument: Encodable, Sendable, Equatable {
    package let materialized: Int
    package let missing: [GitLargeFileFillMiss]
    package let missingCount: Int
    package let options: [String]?
    package let scan: WorktreeLargeFileScanDocument

    package init(fill: GitLargeFileFill, worktreePath: URL) {
        materialized = fill.materializedCount
        missing = Array(fill.missing.prefix(WorktreeLifecyclePolicy.firstPathsLimit))
        missingCount = fill.missing.count
        if fill.missing.isEmpty, case .complete = fill.scan {
            options = nil
        } else {
            let quotedPath = WorktreeListingProjector.shellArgument(worktreePath.standardizedFileURL.path)
            options = ["git -C \(quotedPath) lfs pull"]
        }
        scan = WorktreeLargeFileScanDocument(fill.scan)
    }
}

package enum WorktreeLargeFileScanDocument: Encodable, Sendable, Equatable {
    case complete
    case incompleteReadFailed(errno: Int32)
    case incompleteGitFailure(kind: String)

    private enum CodingKeys: String, CodingKey {
        case incomplete
    }

    private enum FailureKeys: String, CodingKey {
        case readFailed
        case gitFailure
    }

    package init(_ scan: GitLargeFileScan) {
        switch scan {
        case .complete:
            self = .complete
        case .incomplete(.readFailed(let errno)):
            self = .incompleteReadFailed(errno: errno)
        case .incomplete(.gitFailure(let kind)):
            self = .incompleteGitFailure(kind: kind.rawValue)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .complete:
            var container = encoder.singleValueContainer()
            try container.encode("complete")
        case .incompleteReadFailed(let errno):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var incomplete = container.nestedContainer(keyedBy: FailureKeys.self, forKey: .incomplete)
            try incomplete.encode(errno, forKey: .readFailed)
        case .incompleteGitFailure(let kind):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var incomplete = container.nestedContainer(keyedBy: FailureKeys.self, forKey: .incomplete)
            try incomplete.encode(kind, forKey: .gitFailure)
        }
    }
}

package enum WorktreeLargeFilesProjector {
    package static func fill(from materialization: GitWorktreeMaterializationResult) -> GitLargeFileFill? {
        guard case .changesOnly(let report) = materialization else { return nil }
        return report.largeFiles
    }

    package static func document(for fill: GitLargeFileFill?, worktreePath: URL) -> WorktreeLargeFilesDocument? {
        guard let fill, shouldInclude(fill) else { return nil }
        return WorktreeLargeFilesDocument(fill: fill, worktreePath: worktreePath)
    }

    package static func cleanupLeftovers(for fill: GitLargeFileFill?) -> WorktreeLeftoverStatus? {
        guard let fill, !fill.residuePaths.isEmpty else { return nil }
        return .incomplete(
            fill.residuePaths.map {
                WorktreeCleanupLeftover(kind: .temporaryArtifact, location: $0, base: .temporary)
            }
        )
    }

    private static func shouldInclude(_ fill: GitLargeFileFill) -> Bool {
        if case .incomplete = fill.scan { return true }
        return fill.materializedCount > 0 || !fill.missing.isEmpty || !fill.residuePaths.isEmpty
    }
}
