import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    /// LR31: one line, `created <branch> at <path> (<how>[; notes])`. Notes appear only when they
    /// apply, in a fixed order; everything else is in `--json`.
    package static func createdHumanLine(_ summary: WorktreeCreatedSummary) -> String {
        let details = [materializationWord(summary.materialization)] + createdNotes(summary)
        return "created \(summary.branch.name) at \(absolutePath(summary.path)) (\(details.joined(separator: "; ")))"
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
                start: summary.start,
                fetch: summary.fetch,
                largeFiles: WorktreeLargeFilesProjector.document(
                    for: summary.largeFiles,
                    worktreePath: summary.path
                ),
                leftovers: WorktreeLargeFilesProjector.cleanupLeftovers(for: summary.largeFiles)
                    .map(WorktreeCleanupLeftoversFormatter.document)
            )
        )
    }

    private static func materializationWord(_ materialization: WorktreeCreatedMaterialization) -> String {
        switch materialization {
        case .copyOnWrite: "copy-on-write"
        case .checkout: "checkout"
        case .changesOnly: "changes-only"
        }
    }

    private static func createdNotes(_ summary: WorktreeCreatedSummary) -> [String] {
        var notes: [String] = []
        let startName = summary.start.reference.map(shortReferenceName)
        if summary.branch.status != .created {
            notes.append("existing branch")
        }
        if summary.branch.status == .fastForwarded, let startName {
            notes.append("fast-forwarded to \(startName)")
        }
        if let localOnlyCommits = summary.start.localOnlyCommits, let startName {
            notes.append(
                "kept local \(startName): \(counted(localOnlyCommits.count, "commit")) not on \(localOnlyCommits.remoteName)"
            )
        }
        if summary.start.source == .remoteBranch, summary.branch.status != .fastForwarded, let startName {
            notes.append("from \(startName)")
        }
        if case .failed(_, _, let failure) = summary.fetch {
            notes.append("fetch failed: \(failure.reason.rawValue); used local refs")
        }
        if let missingCount = summary.largeFiles?.missing.count, missingCount > 0 {
            notes.append("\(counted(missingCount, "large file")) left as pointers")
        }
        return notes
    }

    /// `refs/remotes/origin/feat` → `origin/feat`, `refs/heads/feat` → `feat`.
    private static func shortReferenceName(_ reference: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

package enum WorktreeCreatedMaterializationDocument: Encodable, Sendable {
    /// `largeFiles` is the reset copy's fill (LR4); an as-is copy has none.
    case copyOnWrite(GitWorktreeMaterializationReport, largeFiles: WorktreeLargeFilesDocument?)
    case checkout(WorktreeLargeFilesDocument)
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
        case sourceState
        case submodulesNotAtStart
        case trackedChanges
        case untrackedFiles
        case ignoredExcluded
    }

    package init(_ materialization: WorktreeCreatedMaterialization, worktreePath: URL) {
        switch materialization {
        case .checkout(let fill):
            self = .checkout(WorktreeLargeFilesDocument(fill: fill, worktreePath: worktreePath))
        case .copyOnWrite(let report):
            self = .copyOnWrite(
                report,
                largeFiles: report.largeFiles.map { WorktreeLargeFilesDocument(fill: $0, worktreePath: worktreePath) })
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
        case .checkout(let largeFiles):
            try container.encode("checkout", forKey: .kind)
            try container.encode(largeFiles, forKey: .largeFiles)
        case .copyOnWrite(let report, let largeFiles):
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
            try container.encode(report.sourceState, forKey: .sourceState)
            try container.encode(report.submodulesNotAtStart, forKey: .submodulesNotAtStart)
            try container.encodeIfPresent(largeFiles, forKey: .largeFiles)
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
    let branch: WorktreeCreatedBranch
    let path: String
    let repository: String
    let materialization: WorktreeCreatedMaterializationDocument
    let start: WorktreeCreationStart
    let fetch: WorktreeCreationFetchStatus
    let largeFiles: WorktreeLargeFilesDocument?
    let leftovers: WorktreeCleanupLeftoversDocument?
}
