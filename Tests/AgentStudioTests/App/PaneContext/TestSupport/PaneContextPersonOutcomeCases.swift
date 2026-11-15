import AgentStudioCore
import Foundation

/// Literal user-visible outcome oracles shared by person-command tests.
enum PaneContextPersonOutcomeCases {
    struct AnswerCase: Sendable {
        let result: AnswerAskResult
        let shown: String
    }
    static let answerCases: [AnswerCase] = [
        .init(result: .answered, shown: "Answered"),
        .init(result: .refused(.alreadyAnswered), shown: "Already answered"),
        .init(result: .refused(.handedBack), shown: "Handed back"),
        .init(result: .refused(.dismissed), shown: "Dismissed"),
        .init(result: .refused(.expired), shown: "Expired"),
        .init(result: .refused(.withdrawn), shown: "Withdrawn"),
        .init(result: .refused(.stale), shown: "Stale"),
        .init(result: .refused(.notFound), shown: "Message not found"),
        .init(result: .refused(.invalidAnswer(.formMismatch)), shown: "Invalid answer: form mismatch"),
        .init(
            result: .refused(.invalidAnswer(.unknownChoice(try! .init("unknown")))),
            shown: "Invalid answer: unknown choice unknown"),
        .init(result: .refused(.invalidAnswer(.choiceCount)), shown: "Invalid answer: choice count"),
        .init(result: .refused(.invalidAnswer(.textTooLarge)), shown: "Invalid answer: text too large"),
        .init(result: .refused(.invalidAnswer(.invalidField("count"))), shown: "Invalid answer: field count"),
        .init(result: .unavailable(.databaseUnavailable), shown: "Answer unavailable: database unavailable"),
        .init(result: .unavailable(.commitFailed), shown: "Answer unavailable: commit failed"),
        .init(result: .unavailable(.decodeFailed("field")), shown: "Answer unavailable: decode failed: field"),
    ]

    struct DismissCase: Sendable {
        let result: DismissResult
        let shown: String
    }
    static let dismissCases: [DismissCase] = [
        .init(result: .done, shown: "Dismissed"),
        .init(
            result: .alreadySettled(
                .ask(.answered(by: .localUser, value: .text("Yes"), receipt: .confirmed(at: .distantPast)))),
            shown: "Already answered"),
        .init(result: .alreadySettled(.ask(.handedBack)), shown: "Already handed back"),
        .init(result: .alreadySettled(.ask(.dismissed)), shown: "Already dismissed"),
        .init(result: .alreadySettled(.ask(.expired)), shown: "Already expired"),
        .init(result: .alreadySettled(.ask(.withdrawn)), shown: "Already withdrawn"),
        .init(result: .alreadySettled(.ask(.stale)), shown: "Already stale"),
        .init(result: .alreadySettled(.notice(.dismissed)), shown: "Already dismissed"),
        .init(result: .alreadySettled(.notice(.withdrawn)), shown: "Already withdrawn"),
        .init(result: .notFound, shown: "Message not found"),
        .init(result: .unavailable(.databaseUnavailable), shown: "Dismiss unavailable: database unavailable"),
    ]
    struct ActionCase: Sendable {
        let result: MessageActionResult
        let shown: String
    }
    static let actionCases: [ActionCase] = [
        .init(result: .openFile(.opened), shown: "File opened"),
        .init(result: .openFile(.notFound), shown: "File not found"),
        .init(result: .openFile(.sourceUnavailable), shown: "Source pane unavailable"),
        .init(result: .openFile(.editorUnavailable), shown: "Editor unavailable"),
        .init(result: .openFile(.launchFailed), shown: "File open failed"),
        .init(result: .openPullRequest(.opened), shown: "Pull request opened"),
        .init(result: .openPullRequest(.notFound), shown: "Pull request not found"),
        .init(result: .openPullRequest(.failed), shown: "Pull request open failed"),
        .init(result: .goToPane(.focused), shown: "Pane focused"),
        .init(result: .goToPane(.paneGone), shown: "Pane gone"),
        .init(result: .notFound, shown: "Message not found"),
        .init(result: .unavailable(.databaseUnavailable), shown: "Action unavailable: database unavailable"),
    ]
}
