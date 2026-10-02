import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func createdHumanLine(_ summary: WorktreeCreatedSummary) -> String {
        var lines = ["created \(summary.branch) at \(absolutePath(summary.path))"]
        if let largeFiles = WorktreeLargeFilesProjector.document(for: summary.largeFiles) {
            lines.append(largeFilesHumanLine(largeFiles, worktreePath: summary.path))
        }
        if let leftovers = WorktreeLargeFilesProjector.cleanupLeftovers(for: summary.largeFiles) {
            lines.append("leftovers: \(WorktreeCleanupLeftoversFormatter.human(leftovers))")
        }
        return lines.joined(separator: "\n")
    }

    package static func createdJSONText(_ summary: WorktreeCreatedSummary) throws -> String {
        try encodeJSON(
            WorktreeCreatedCommandLineJSON(
                operation: summary.operation.rawValue,
                branch: summary.branch,
                path: absolutePath(summary.path),
                repository: absolutePath(summary.repository),
                materialization: summary.materialization,
                largeFiles: WorktreeLargeFilesProjector.document(for: summary.largeFiles),
                leftovers: WorktreeLargeFilesProjector.cleanupLeftovers(for: summary.largeFiles)
                    .map(WorktreeCleanupLeftoversFormatter.document)
            )
        )
    }

    private static func largeFilesHumanLine(
        _ largeFiles: WorktreeLargeFilesDocument,
        worktreePath: URL
    ) -> String {
        var line = "LFS: \(largeFiles.materialized) filled, \(largeFiles.missingCount) missing"
        let isIncomplete: Bool
        if case .incomplete(let failure) = largeFiles.scan {
            isIncomplete = true
            line += ", scan incomplete (\(humanScanFailure(failure)))"
        } else {
            isIncomplete = false
        }
        if largeFiles.missingCount > 0 || isIncomplete {
            line += " (run: git -C \(absolutePath(worktreePath)) lfs pull)"
        }
        return line
    }

    private static func humanScanFailure(_ failure: GitLargeFileScanFailure) -> String {
        switch failure {
        case .readFailed(let errorNumber):
            "readFailed errno \(errorNumber)"
        case .gitFailure(let kind):
            "gitFailure \(kind.rawValue)"
        }
    }
}

private struct WorktreeCreatedCommandLineJSON: Encodable {
    let outcome = "created"
    let operation: String
    let branch: String
    let path: String
    let repository: String
    let materialization: GitWorktreeMaterializationResult?
    let largeFiles: WorktreeLargeFilesDocument?
    let leftovers: WorktreeCleanupLeftoversDocument?
}
