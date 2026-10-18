import AgentStudioCore
import Foundation

package enum RepoExplorerPaneRowLine: Equatable, Sendable {
    case title(String)
    case worktreeBranch(String)
    case note(String)
    case agentLine(RepoExplorerPaneContextLine)
    case sessionStatus(RepoExplorerPaneContextLine)
    case connectionIssue(RepoExplorerPaneContextLine)

    package var kind: RepoExplorerPaneLineKind {
        switch self {
        case .title: .title
        case .worktreeBranch: .worktreeBranch
        case .note: .note
        case .agentLine: .agentLine
        case .sessionStatus: .sessionStatus
        case .connectionIssue: .connectionIssue
        }
    }
}

enum RepoExplorerPaneChipKind: Equatable, Sendable {
    case drawer
    case gitPR
    case changes
    case sync
    case messages
    case clock
    case active
}

struct RepoExplorerPaneRowVariant: Equatable, Sendable {
    let lines: [RepoExplorerPaneRowLine]
    let chips: [RepoExplorerPaneChipKind]
    let fallbackLineCount: Int
    var showsChipLine = true
}

package struct RepoExplorerPaneRowVariants: Equatable, Sendable {
    let compact: RepoExplorerPaneRowVariant
    let expanded: RepoExplorerPaneRowVariant

    package static func informationLines(
        title: String, note: String?, agentLine: AgentLineDetail?,
        sessionStatus: AgentSessionStatus?, connectionIssue: AgentConnectionRefusalReason?
    ) -> [RepoExplorerPaneRowLine] {
        make(
            title: title, branchContext: nil, note: note, isDrawer: false, branchStatus: nil, isActive: false,
            agentLine: agentLine, sessionStatus: sessionStatus, connectionIssue: connectionIssue
        ).expanded.lines
    }

    static func make(
        title: String,
        branchContext: String?,
        note: String?,
        isDrawer: Bool,
        branchStatus: GitBranchStatus?,
        isActive: Bool,
        agentLine: AgentLineDetail? = nil,
        sessionStatus: AgentSessionStatus? = nil,
        connectionIssue: AgentConnectionRefusalReason? = nil,
        messageCount: Int = 0
    ) -> Self {
        let candidates: [RepoExplorerPaneLineKind: RepoExplorerPaneRowLine?] = [
            .title: .title(title),
            .worktreeBranch: branchContext.map(RepoExplorerPaneRowLine.worktreeBranch),
            .note: note.map(RepoExplorerPaneRowLine.note),
            .agentLine: agentLine.map { .agentLine(RepoExplorerPaneContextLine.agent($0)) },
            .connectionIssue: connectionIssue.map { .connectionIssue(RepoExplorerPaneContextLine.connection($0)) },
            .sessionStatus: sessionStatus.flatMap(RepoExplorerPaneContextLine.session).map(
                RepoExplorerPaneRowLine.sessionStatus),
        ]
        let compactLines = RepoExplorerPaneLineVisibilityTable.lines(
            candidates.compactMapValues { $0 }, selected: false)
        let expandedLines = RepoExplorerPaneLineVisibilityTable.lines(
            candidates.compactMapValues { $0 }, selected: true)

        var compactChips: [RepoExplorerPaneChipKind] = []
        if isDrawer { compactChips.append(.drawer) }
        if let branchStatus,
            SidebarPullRequestChipSpec.presentation(
                branchStatus: branchStatus,
                usesPanesLoadingChip: true
            ) != .hidden
        {
            compactChips.append(.gitPR)
        }
        var expandedChips = compactChips
        if let branchStatus {
            if SidebarGitStatusChips.diffDetail(branchStatus: branchStatus) != nil {
                expandedChips.append(.changes)
            }
            if SidebarGitStatusChips.showsSync(branchStatus: branchStatus) {
                expandedChips.append(.sync)
            }
        }
        if messageCount > 0 {
            compactChips.append(.messages)
            expandedChips.append(.messages)
        }
        compactChips.append(.clock)
        expandedChips.append(.clock)
        if isActive {
            compactChips.append(.active)
            expandedChips.append(.active)
        }
        let compactChipLine = RepoExplorerPaneLineVisibilityTable.showsChips(selected: false)
        let expandedChipLine = RepoExplorerPaneLineVisibilityTable.showsChips(selected: true)
        return Self(
            compact: RepoExplorerPaneRowVariant(
                lines: compactLines,
                chips: compactChips,
                fallbackLineCount: compactLines.count + (compactChipLine ? 1 : 0),
                showsChipLine: compactChipLine
            ),
            expanded: RepoExplorerPaneRowVariant(
                lines: expandedLines,
                chips: expandedChips,
                fallbackLineCount: expandedLines.count + (expandedChipLine ? 1 : 0),
                showsChipLine: expandedChipLine
            )
        )
    }
}
