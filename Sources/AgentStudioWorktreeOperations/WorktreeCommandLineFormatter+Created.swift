import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func createdHumanLine(_ summary: WorktreeCreatedSummary) -> String {
        var lines = ["created \(summary.branch) at \(absolutePath(summary.path))"]
        if let largeFiles = WorktreeLargeFilesProjector.document(
            for: summary.largeFiles,
            worktreePath: summary.path
        ) {
            lines.append(largeFilesHumanLine(largeFiles))
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
                largeFiles: WorktreeLargeFilesProjector.document(
                    for: summary.largeFiles,
                    worktreePath: summary.path
                ),
                leftovers: WorktreeLargeFilesProjector.cleanupLeftovers(for: summary.largeFiles)
                    .map(WorktreeCleanupLeftoversFormatter.document)
            )
        )
    }

    private static func largeFilesHumanLine(_ largeFiles: WorktreeLargeFilesDocument) -> String {
        var line = "LFS: \(largeFiles.materialized) filled, \(largeFiles.missingCount) missing"
        switch largeFiles.scan {
        case .complete:
            break
        case .incompleteReadFailed(let errno):
            line += ", scan incomplete (readFailed errno \(errno))"
        case .incompleteGitFailure(let kind):
            line += ", scan incomplete (gitFailure \(kind))"
        }
        if let option = largeFiles.options?.first {
            line += " (run: \(option))"
        }
        return line
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
