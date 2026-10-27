import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

/// Loading has no body to measure. The first ready content fixes the width until the next opening.
enum MessagesPopoverWidthState: Equatable {
    case loading(CGFloat)
    case content(CGFloat)

    var width: CGFloat {
        switch self {
        case .loading(let width), .content(let width): width
        }
    }

    static func loading(screenVisibleWidth: CGFloat) -> Self {
        .loading(resolve(hasMultilineBody: false, screenVisibleWidth: screenVisibleWidth))
    }

    func receivingContent(hasMultilineBody: Bool, screenVisibleWidth: CGFloat) -> Self {
        switch self {
        case .loading:
            .content(Self.resolve(hasMultilineBody: hasMultilineBody, screenVisibleWidth: screenVisibleWidth))
        case .content: self
        }
    }

    static func resolve(hasMultilineBody: Bool, screenVisibleWidth: CGFloat) -> CGFloat {
        let available = max(0, screenVisibleWidth - 2 * AppStyles.Components.PaneContext.popoverScreenInset)
        let preferred =
            hasMultilineBody
            ? AppStyles.Components.PaneContext.messagesPopoverMaximumWidth
            : AppStyles.Components.PaneContext.messagesPopoverIdealWidth
        return min(available, max(AppStyles.Components.PaneContext.messagesPopoverMinimumWidth, preferred))
    }

    static func hasMultilineBody(in model: MessagesPopoverModel) -> Bool {
        model.groups.contains { group in
            group.items.contains { item in
                switch item {
                case .message(let row): row.body.contains(where: \.isNewline)
                case .providerPrompt(let prompt):
                    (prompt.summary.map { prompt.reasonText + ": " + $0 } ?? prompt.reasonText).contains(
                        where: \.isNewline)
                }
            }
        }
    }
}
