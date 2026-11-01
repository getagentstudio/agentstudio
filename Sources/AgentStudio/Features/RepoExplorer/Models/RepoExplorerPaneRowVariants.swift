import AgentStudioCore
import AgentStudioSharedComponents
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

struct RepoExplorerPaneRowVariant: Equatable, Sendable {
    let lines: [RepoExplorerPaneRowLine]
    let statusLine: StatusLine?
    let chips: [KindCount]
    let activityChip: AgeText?
    let chipModels: [KindChipModel]

    var showsChipLine: Bool { !chips.isEmpty || activityChip != nil }
    var fallbackLineCount: Int { lines.count + (showsChipLine ? 1 : 0) }

    init(
        lines: [RepoExplorerPaneRowLine], statusLine: StatusLine? = nil,
        chips: [KindCount] = [], activityChip: AgeText? = nil
    ) {
        self.lines = lines
        self.statusLine = statusLine
        self.chips = chips
        self.activityChip = activityChip
        self.chipModels = chips.map(PaneMessageKindChipProjection.model)
    }
}

package struct RepoExplorerPaneRowVariants: Equatable, Sendable {
    let compact: RepoExplorerPaneRowVariant
    let expanded: RepoExplorerPaneRowVariant

    package static func informationLines(
        title: String, note: String?, agentLine: AgentLineDetail?,
        sessionStatus: AgentSessionStatus?, connectionIssue: AgentConnectionRefusalReason?,
        now: Date
    ) -> [RepoExplorerPaneRowLine] {
        var lines: [RepoExplorerPaneRowLine] = [.title(title)]
        if let note { lines.append(.note(note)) }
        if let status = sessionStatus.flatMap(RepoExplorerPaneContextLine.session) {
            lines.append(.sessionStatus(status))
        }
        if let agentLine { lines.append(.agentLine(.agent(agentLine, now: now))) }
        if let connectionIssue { lines.append(.connectionIssue(.connection(connectionIssue))) }
        return lines
    }

    static func make(
        title: String,
        agentLine: AgentLineDetail? = nil,
        sessionPresentation: PaneAgentStatusPresentation? = nil,
        scopedPrompt: (source: PaneId, prompt: CompactProviderPrompt)? = nil,
        counts: PaneMessageKindCounts = .zero,
        activityDate: Date? = nil,
        now: Date
    ) -> Self {
        let status = PaneContextPresentationRules.statusLine(sessionPresentation, scopedPrompt: scopedPrompt)
        var lines: [RepoExplorerPaneRowLine] = [
            .title(PaneContextPresentationRules.displayTitle(raw: title, cwd: nil, shell: nil))
        ]
        if let status, let rendered = RepoExplorerPaneContextLine.status(status, presentation: sessionPresentation) {
            lines.append(.sessionStatus(rendered))
        }
        if let agentLine { lines.append(.agentLine(.agent(agentLine, now: now))) }
        let variant = RepoExplorerPaneRowVariant(
            lines: lines, statusLine: status, chips: PaneContextPresentationRules.kindChips(counts),
            activityChip: PaneContextPresentationRules.activityChip(
                agentLine: agentLine, activity: activityDate, now: now))
        return Self(compact: variant, expanded: variant)
    }
}
