import Foundation

extension WorktreeCommandLineFormatter {
    package static func listedHumanLine(_ summary: WorktreeListingSummary) -> String {
        summary.worktrees.map { worktree in
            let kind = worktree.isMain ? "main" : "worktree"
            return "\(kind) \(worktree.branch ?? "detached") at \(absolutePath(worktree.path))"
        }.joined(separator: "\n")
    }

    package static func listedJSONText(_ summary: WorktreeListingSummary) throws -> String {
        let worktrees = summary.worktrees.map { worktree in
            WorktreeListingCommandLineJSON.Worktree(
                path: absolutePath(worktree.path),
                branch: worktree.branch,
                isMain: worktree.isMain
            )
        }
        return try encodeJSON(
            WorktreeListingCommandLineJSON(
                repository: absolutePath(summary.repository),
                worktrees: worktrees
            )
        )
    }
}

private struct WorktreeListingCommandLineJSON: Encodable {
    let outcome = "listed"
    let repository: String
    let worktrees: [Worktree]

    struct Worktree: Encodable {
        let path: String
        let branch: String?
        let isMain: Bool
    }
}
