import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents

enum PaneContextMessagesTarget: Sendable, Equatable {
    case top
    case section(MessagesGroupModel.Kind)
    case message(PaneContextMessageKey)
}

enum PaneContextMessagesScrollTrigger: Sendable, Equatable {
    case opening(UInt64)
    case focusedMessageContent(MessagesPopoverModel)
}

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

    var messagesTarget: PaneContextMessagesTarget {
        switch self {
        case .kind(let chip):
            let section: MessagesGroupModel.Kind =
                switch chip.kind {
                case .failure: .failed
                case .needsYou: .needsYou
                case .done: .done
                case .info: .info
                }
            return .section(section)
        case .messagesAction(_, let key): return key.map(PaneContextMessagesTarget.message) ?? .top
        case .agentLine: return .top
        }
    }

    func messagesScrollTrigger(openRequest: UInt64, messages: MessagesPopoverModel) -> PaneContextMessagesScrollTrigger
    {
        switch messagesTarget {
        case .message: .focusedMessageContent(messages)
        case .top, .section: .opening(openRequest)
        }
    }
}
