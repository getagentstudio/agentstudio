import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func createdHumanLine(_ summary: WorktreeCreatedSummary) -> String {
        var lines = ["created \(summary.branch) at \(absolutePath(summary.path))"]
        if case .copyOnWrite(let report) = summary.materialization {
            lines.append(
                "copyOnWrite: ignoredIncludedPatterns=[\(report.ignoredIncludedPatterns.joined(separator: ", "))] ignoredExcludedCount=\(report.ignoredExcludedCount) nestedWorktreesSkipped=[\(report.nestedWorktreesSkipped.joined(separator: ", "))]"
            )
        }
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
                materialization: WorktreeCreatedMaterializationDocument(
                    summary.materialization, worktreePath: summary.path),
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

package enum WorktreeCreatedMaterializationDocument: Encodable, Sendable {
    case copyOnWrite(GitWorktreeMaterializationReport)
    case trackedOnly(WorktreeLargeFilesDocument)
    case changesOnly(trackedChanges: Int, untrackedFiles: Int, ignoredExcluded: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case largeFiles
        case clonedRegularFileCount
        case createdDirectoryCount
        case recreatedSymbolicLinkCount
        case preservedHardLinkCount
        case preservedGitRepositoryCount
        case recreatedFIFOCount
        case logicalRegularFileBytes
        case skippedEntries
        case normalizedEntries
        case ignoredIncludedPatterns
        case ignoredExcludedCount
        case nestedWorktreesSkipped
        case trackedChanges
        case untrackedFiles
        case ignoredExcluded
    }

    package init(_ materialization: WorktreeCreatedMaterialization, worktreePath: URL) {
        switch materialization {
        case .trackedOnly(let fill):
            self = .trackedOnly(WorktreeLargeFilesDocument(fill: fill, worktreePath: worktreePath))
        case .copyOnWrite(let report):
            self = .copyOnWrite(report)
        case .changesOnly(let report):
            self = .changesOnly(
                trackedChanges: report.trackedChanges,
                untrackedFiles: report.untrackedFiles,
                ignoredExcluded: report.ignoredExcluded
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trackedOnly(let largeFiles):
            try container.encode("trackedOnly", forKey: .kind)
            try container.encode(largeFiles, forKey: .largeFiles)
        case .copyOnWrite(let report):
            try container.encode("copyOnWrite", forKey: .kind)
            try container.encode(report.clonedRegularFileCount, forKey: .clonedRegularFileCount)
            try container.encode(report.createdDirectoryCount, forKey: .createdDirectoryCount)
            try container.encode(report.recreatedSymbolicLinkCount, forKey: .recreatedSymbolicLinkCount)
            try container.encode(report.preservedHardLinkCount, forKey: .preservedHardLinkCount)
            try container.encode(report.preservedGitRepositoryCount, forKey: .preservedGitRepositoryCount)
            try container.encode(report.recreatedFIFOCount, forKey: .recreatedFIFOCount)
            try container.encode(report.logicalRegularFileBytes, forKey: .logicalRegularFileBytes)
            try container.encode(report.skippedEntries, forKey: .skippedEntries)
            try container.encode(report.normalizedEntries, forKey: .normalizedEntries)
            try container.encode(report.ignoredIncludedPatterns, forKey: .ignoredIncludedPatterns)
            try container.encode(report.ignoredExcludedCount, forKey: .ignoredExcludedCount)
            try container.encode(report.nestedWorktreesSkipped, forKey: .nestedWorktreesSkipped)
        case .changesOnly(let trackedChanges, let untrackedFiles, let ignoredExcluded):
            try container.encode("changesOnly", forKey: .kind)
            try container.encode(trackedChanges, forKey: .trackedChanges)
            try container.encode(untrackedFiles, forKey: .untrackedFiles)
            try container.encode(ignoredExcluded, forKey: .ignoredExcluded)
        }
    }
}

private struct WorktreeCreatedCommandLineJSON: Encodable {
    let outcome = "created"
    let operation: String
    let branch: String
    let path: String
    let repository: String
    let materialization: WorktreeCreatedMaterializationDocument
    let largeFiles: WorktreeLargeFilesDocument?
    let leftovers: WorktreeCleanupLeftoversDocument?
}
