import AgentStudioGit
import Foundation

package struct WorktreeLargeFilesDocument: Encodable, Sendable, Equatable {
    package let materialized: Int
    package let missing: [GitLargeFileFillMiss]
    package let missingCount: Int
    package let scan: GitLargeFileScan

    package init(fill: GitLargeFileFill) {
        materialized = fill.materializedCount
        missing = Array(fill.missing.prefix(WorktreeLifecyclePolicy.firstPathsLimit))
        missingCount = fill.missing.count
        scan = fill.scan
    }
}

package enum WorktreeLargeFilesProjector {
    package static func fill(from materialization: GitWorktreeMaterializationResult) -> GitLargeFileFill? {
        guard case .changesOnly(let report) = materialization else { return nil }
        return report.largeFiles
    }

    package static func document(for fill: GitLargeFileFill?) -> WorktreeLargeFilesDocument? {
        guard let fill, shouldInclude(fill) else { return nil }
        return WorktreeLargeFilesDocument(fill: fill)
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
