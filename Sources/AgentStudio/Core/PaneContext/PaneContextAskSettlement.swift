import Foundation
import GRDB

struct PaneContextSettlementCommit: Sendable {
    let result: AskSettlementResult
    let outcome: AskOutcome?
    let openAsks: PaneContextOpenAskUpdate?
}

enum PaneContextAskSettlement {
    static func commit(_ database: Database, paneId: PaneId, id: AgentMessageId, cause: AskSettlementCause, now: Date)
        throws -> PaneContextSettlementCommit
    {
        guard let message = try PaneContextStorage.message(database, paneId: paneId, messageId: id),
            case .ask(_, let form, let waiting, let state) = message.detail.shape
        else { return unchanged(.notFound) }
        guard state == .open else {
            if case .answer = cause { return unchanged(.refused(PaneContextStorage.refusal(state))) }
            return unchanged(.alreadySettled(state), outcome: PaneContextStorage.outcome(state))
        }
        let terminal: AskState
        let changeKind: String?
        var answer: AskAnswerValue?
        var answerWasExpired = false
        if case .blocking(let deadline) = waiting, deadline <= now {
            terminal = .expired
            changeKind = nil
            if case .answer = cause { answerWasExpired = true }
        } else {
            switch cause {
            case .answer(_, let value):
                if let invalid = PaneContextAdmission.answerInvalidity(value, form: form) {
                    return unchanged(.refused(.invalidAnswer(invalid)))
                }
                terminal = .answered(by: .localUser, value: value, receipt: .notYetConfirmed)
                answer = value
                changeKind = "answer"
            case .dismiss:
                if case .blocking = waiting { terminal = .handedBack } else { terminal = .dismissed }
                changeKind = "dismissal"
            case .withdraw(let writer):
                guard message.detail.sender == writer else { return unchanged(.refused(.notFound)) }
                terminal = .withdrawn
                changeKind = "withdrawal"
            case .callerGone:
                guard case .blocking = waiting else { return unchanged(.stillOpen) }
                terminal = .withdrawn
                changeKind = "withdrawal"
            case .appStopping:
                guard case .blocking = waiting else { return unchanged(.stillOpen) }
                terminal = .stale
                changeKind = nil
            case .deadline:
                return unchanged(.stillOpen)
            }
        }
        let position: UInt64
        if let changeKind {
            position = try PaneContextStorage.appendChange(database, message: message, kind: changeKind, now: now)
        } else {
            position = try PaneContextStorage.nextPosition(database, paneId: paneId)
        }
        var fields: [String: DatabaseValue] = [
            "state": PaneContextStorage.sqlValue(stateName(terminal)),
            "settled_at": PaneContextStorage.sqlValue(try PaneContextStorage.timestamp(now)),
            "position": PaneContextStorage.sqlValue(try PaneContextStorage.integer(position, field: "position")),
        ]
        if let answer {
            fields.merge(PaneContextStorage.answerFields(answer), uniquingKeysWith: { _, new in new })
            fields["answered_by"] = PaneContextStorage.sqlValue("localUser")
            fields["answered_at"] = PaneContextStorage.sqlValue(try PaneContextStorage.timestamp(now))
            fields["answer_position"] = PaneContextStorage.sqlValue(
                try PaneContextStorage.integer(position, field: "answer_position"))
            fields["receipt"] = PaneContextStorage.sqlValue("notYetConfirmed")
        }
        let names = fields.keys.sorted()
        var arguments = StatementArguments(names.map { fields[$0] ?? .null })
        arguments += [message.rowId.uuidString]
        try database.execute(
            sql:
                "UPDATE pane_request SET \(names.map { "\($0) = ?" }.joined(separator: ",")) WHERE id = ? AND state = 'open'",
            arguments: arguments)
        guard database.changesCount == 1 else {
            // The transaction reads and writes one open row; losing it is storage corruption.
            throw PaneContextStorageFailure.decode("state")
        }
        if let answer { try PaneContextStorage.saveAnswer(answer, database: database, requestId: message.rowId) }
        try PaneContextStorage.bumpRevision(database, paneId: paneId)
        let update = try PaneContextStorage.openAskUpdate(
            database, paneId: paneId, sender: message.detail.sender, advancing: true)
        return PaneContextSettlementCommit(
            result: answerWasExpired ? .refused(.expired) : .settled(terminal),
            outcome: PaneContextStorage.outcome(terminal), openAsks: update
        )
    }

    private static func unchanged(_ result: AskSettlementResult, outcome: AskOutcome? = nil)
        -> PaneContextSettlementCommit
    {
        PaneContextSettlementCommit(result: result, outcome: outcome, openAsks: nil)
    }

    private static func stateName(_ state: AskState) -> String {
        switch state {
        case .open: "open"
        case .answered: "answered"
        case .handedBack: "handedBack"
        case .dismissed: "dismissed"
        case .expired: "expired"
        case .withdrawn: "withdrawn"
        case .stale: "stale"
        }
    }
}
