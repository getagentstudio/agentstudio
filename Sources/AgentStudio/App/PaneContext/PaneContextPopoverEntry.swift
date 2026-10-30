import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents

enum PaneContextMessagesTarget: Sendable, Equatable {
    case top
    case section(MessagesGroupModel.Kind)
    case message(PaneContextMessageKey)

    var initialFilterSelection: Int {
        switch self {
        case .section(.needsYou): 1
        case .section(.failed): 2
        case .section(.done): 4
        case .section(.info): 8
        case .top, .message, .section(.resolved): 15
        }
    }
}

enum PaneContextMessagesScrollTrigger: Sendable, Equatable {
    case opening(UInt64)
    case focusedMessageContent(MessagesPopoverModel)
}

/// App composes sidebar entries and card navigation without extending a Feature's contract.
enum PaneContextPopoverEntry {
    case kind(KindChipModel)
    case agentLine(RepoExplorerPaneContextLine)
    case messagesAction(PaneContextControlModel, target: PaneContextMessagesTarget)

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
        case .messagesAction(_, let target): return target
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
