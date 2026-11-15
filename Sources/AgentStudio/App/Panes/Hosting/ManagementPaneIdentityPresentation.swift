import AgentStudioCore
import AgentStudioRepoExplorer
import Foundation

/// Card-only projection. Context remains the authority for verified session identity.
@MainActor
struct ManagementPaneIdentityPresentation {
    static let widestCaption = "worktree"

    let title: String
    let status: RepoExplorerPaneContextLine?
    let rows: [PaneManagementIdentityRow]
    let secondaryLines: [RepoExplorerPaneRowLine]

    init(context: PaneManagementContext, lines: [RepoExplorerPaneRowLine]) {
        title = lines.compactMap { if case .title(let text) = $0 { text } else { nil } }.first ?? ""
        status = lines.compactMap { if case .sessionStatus(let value) = $0 { value } else { nil } }.first
        let repo = context.identityRows.first { $0.id == "repo" }
        let worktree = context.identityRows.first { $0.id == "worktree" }
        let cwdIsWorktreeRoot =
            worktree?.toolTip.map {
                URL(filePath: $0).standardizedFileURL.path == context.targetPath?.standardizedFileURL.path
            } ?? false
        let order = ["repo", "branch", "worktree", "cwd", "session", "pane", "fallback"]
        rows = order.compactMap { identifier in
            guard let row = context.identityRows.first(where: { $0.id == identifier }) else { return nil }
            if identifier == "worktree", row.text == repo?.text { return nil }
            if identifier == "cwd", cwdIsWorktreeRoot { return nil }
            return row
        }
        let secondaryKinds: [RepoExplorerPaneLineKind] = [.agentLine, .connectionIssue, .note]
        secondaryLines = secondaryKinds.compactMap { kind in
            lines.first { $0.kind == kind }
        }
    }

    func accessibilityLabel(for row: PaneManagementIdentityRow) -> String {
        let name =
            switch row.id {
            case "repo": "Repo"
            case "worktree": "Worktree"
            case "branch": "Branch"
            case "cwd": "Current directory"
            case "session": "Session"
            case "pane": "Pane"
            default: ""
            }
        return name.isEmpty ? row.text : "\(name) \(row.text)"
    }

    func caption(for row: PaneManagementIdentityRow) -> String {
        switch row.id {
        case "repo": "repo"
        case "branch": "branch"
        case "worktree": Self.widestCaption
        case "cwd": "cwd"
        case "session": "session"
        case "pane": "pane"
        default: ""
        }
    }

    func copyAction(for row: PaneManagementIdentityRow) -> ActionSpec {
        (row.id == "session" ? LocalActionSpec.copySessionId : .copyPaneId).actionSpec
    }
}
