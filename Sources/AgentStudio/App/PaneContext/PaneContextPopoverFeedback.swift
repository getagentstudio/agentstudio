import AgentStudioCore
import Foundation

enum PaneContextPopoverFeedback {
    @concurrent nonisolated static func unavailable(_ failure: StorageFailureSummary) async -> String {
        storage(failure)
    }
    private nonisolated static func storage(_ failure: StorageFailureSummary) -> String {
        switch failure {
        case .databaseUnavailable: "database unavailable"
        case .commitFailed: "commit failed"
        case .decodeFailed(let field): "decode failed: \(field)"
        }
    }
    @concurrent nonisolated static func answer(_ result: AnswerAskResult) async -> String {
        switch result {
        case .answered: "Answered"
        case .unavailable(let failure): "Answer unavailable: \(storage(failure))"
        case .refused(let refusal): refusalText(refusal)
        }
    }
    private nonisolated static func refusalText(_ refusal: AnswerRefusal) -> String {
        switch refusal {
        case .alreadyAnswered: "Already answered"
        case .handedBack: "Handed back"
        case .dismissed: "Dismissed"
        case .expired: "Expired"
        case .withdrawn: "Withdrawn"
        case .stale: "Stale"
        case .notFound: "Message not found"
        case .invalidAnswer(let invalidity):
            switch invalidity {
            case .formMismatch: "Invalid answer: form mismatch"
            case .unknownChoice(let choice): "Invalid answer: unknown choice \(choice.value)"
            case .choiceCount: "Invalid answer: choice count"
            case .textTooLarge: "Invalid answer: text too large"
            case .invalidField(let field): "Invalid answer: field \(field)"
            }
        }
    }
    @concurrent nonisolated static func dismiss(
        _ result: DismissResult, messageId: AgentMessageId, detail: PaneContextDetail?
    ) async -> String {
        switch result {
        case .done:
            if let message = PaneContextPopoverAnswerParsing.message(messageId, detail: detail),
                case .ask(_, _, .blocking, _) = message.shape
            {
                return "Handed back"
            }
            return "Dismissed"
        case .alreadySettled(let terminal):
            switch terminal {
            case .ask(.answered): return "Already answered"
            case .ask(.handedBack): return "Already handed back"
            case .ask(.dismissed), .notice(.dismissed): return "Already dismissed"
            case .ask(.expired): return "Already expired"
            case .ask(.withdrawn), .notice(.withdrawn): return "Already withdrawn"
            case .ask(.stale): return "Already stale"
            }
        case .notFound: return "Message not found"
        case .unavailable(let failure): return "Dismiss unavailable: \(storage(failure))"
        }
    }
    @concurrent nonisolated static func markRead(_ result: MarkReadResult) async -> String {
        switch result {
        case .done: "Marked read"
        case .alreadyRead: "Already read"
        case .notFound: "Message not found"
        case .unavailable(let failure): "Mark read unavailable: \(storage(failure))"
        }
    }
    @concurrent nonisolated static func dismissAll(_ result: DismissAllNoticesResult) async -> String {
        switch result {
        case .dismissed(let count): "Dismissed \(count) notices"
        case .unavailable(let failure): "Dismiss unavailable: \(storage(failure))"
        }
    }
    @concurrent nonisolated static func action(_ result: MessageActionResult) async -> String {
        switch result {
        case .openFile(.opened): "File opened"
        case .openFile(.shown): "File shown"
        case .openFile(.declined): "File take-over declined"
        case .openFile(.notFound): "File not found"
        case .openFile(.paneUnavailable): "Pane unavailable"
        case .openPullRequest(.opened): "Pull request opened"
        case .openPullRequest(.notFound): "Pull request not found"
        case .openPullRequest(.failed): "Pull request open failed"
        case .goToPane(.focused): "Pane focused"
        case .goToPane(.paneGone): "Pane gone"
        case .notFound: "Message not found"
        case .unavailable(let failure): "Action unavailable: \(storage(failure))"
        }
    }
}
