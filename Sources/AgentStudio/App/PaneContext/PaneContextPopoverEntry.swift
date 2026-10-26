import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents

/// App composes sidebar entries and card navigation without extending a Feature's contract.
enum PaneContextPopoverEntry {
    case kind(KindChipModel)
    case agentLine(RepoExplorerPaneContextLine)
    case messagesAction(PaneContextControlModel, focusedMessage: PaneContextMessageKey?)

    init(_ control: RepoExplorerPaneContextControlPresentation) {
        switch control {
        case .kind(let chip): self = .kind(chip)
        case .agentLine(let line): self = .agentLine(line)
        }
    }
}
