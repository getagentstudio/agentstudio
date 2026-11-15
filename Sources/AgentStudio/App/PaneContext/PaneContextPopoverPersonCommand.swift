import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

enum PaneContextPopoverPersonIntent: Sendable {
    case answer(PaneContextMessageKey, AskFormDraft)
    case dismiss(PaneContextMessageKey)
    case runAction(PaneContextMessageKey, MessageActionModel)
    case dismissAllNotices

    nonisolated var messageKey: PaneContextMessageKey? {
        switch self {
        case .answer(let key, _), .dismiss(let key), .runAction(let key, _): key
        case .dismissAllNotices: nil
        }
    }
}

struct PaneContextPopoverPersonCompletion: Sendable, Equatable {
    enum Refusal: Sendable, Equatable {
        case answerInMessages, dismissNotAvailable, actionNotAvailable, requestNotCurrent, openingRetired
    }
    enum Resolution: Sendable, Equatable {
        case answer(AnswerAskResult)
        case dismiss(DismissResult)
        case action(MessageActionResult)
        case dismissAll(DismissAllNoticesResult)
        case refused(Refusal)
    }
    enum Presentation: Sendable, Equatable {
        case keepPopover, dismissPopover, openingRetired
    }
    let id: UUID
    let resolution: Resolution
    let presentation: Presentation
}
