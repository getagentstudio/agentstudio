import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func createdHumanLine(_ summary: WorktreeCreatedSummary) -> String {
        "created \(summary.branch) at \(absolutePath(summary.path))"
    }

    package static func createdJSONText(_ summary: WorktreeCreatedSummary) throws -> String {
        try encodeJSON(
            WorktreeCreatedCommandLineJSON(
                operation: summary.operation.rawValue,
                branch: summary.branch,
                path: absolutePath(summary.path),
                repository: absolutePath(summary.repository),
                materialization: summary.materialization
            )
        )
    }
}

private struct WorktreeCreatedCommandLineJSON: Encodable {
    let outcome = "created"
    let operation: String
    let branch: String
    let path: String
    let repository: String
    let materialization: GitWorktreeMaterializationReport?
}
