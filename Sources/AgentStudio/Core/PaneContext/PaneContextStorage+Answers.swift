import Foundation
import GRDB

extension PaneContextStorage {
    static func answerFields(_ answer: AskAnswerValue) -> [String: DatabaseValue] {
        switch answer {
        case .text(let text): ["answer_kind": sqlValue("text"), "answer_text": sqlValue(text)]
        case .choices: ["answer_kind": sqlValue("choices")]
        case .form: ["answer_kind": sqlValue("form")]
        }
    }

    static func saveAnswer(_ answer: AskAnswerValue, database: Database, requestId: UUID) throws {
        switch answer {
        case .text: break
        case .choices(let choices):
            for (ordinal, choice) in choices.enumerated() {
                try insert(
                    database, table: "pane_request_answer_value",
                    fields: [
                        "request_id": sqlValue(requestId.uuidString), "ordinal": sqlValue(ordinal),
                        "value_kind": sqlValue("choice"), "text_value": sqlValue(choice.value),
                    ])
            }
        case .form(let values):
            for (ordinal, name) in values.properties.keys.sorted().enumerated() {
                guard let value = values.properties[name] else { continue }
                var fields: [String: DatabaseValue] = [
                    "request_id": sqlValue(requestId.uuidString), "ordinal": sqlValue(ordinal),
                    "field_name": sqlValue(name),
                ]
                switch value {
                case .string(let text):
                    fields["value_kind"] = sqlValue("string")
                    fields["text_value"] = sqlValue(text)
                case .number(let number):
                    fields["value_kind"] = sqlValue("number")
                    fields["text_value"] = sqlValue(String(number))
                case .integer(let number):
                    fields["value_kind"] = sqlValue("integer")
                    fields["integer_value"] = sqlValue(number)
                case .boolean(let value):
                    fields["value_kind"] = sqlValue("boolean")
                    fields["integer_value"] = sqlValue(value ? 1 : 0)
                }
                try insert(database, table: "pane_request_answer_value", fields: fields)
            }
        }
    }

    static func answer(_ row: Row, children: PaneContextMessageChildren) throws -> AskAnswerValue {
        let kind: String = try required(row, "answer_kind")
        if kind == "text" { return .text(try required(row, "answer_text")) }
        let rows = children.answers[try uuid(row, "id")] ?? []
        if kind == "choices" {
            let choices = try rows.map { value in
                guard try required(value, "value_kind") as String == "choice" else {
                    throw PaneContextStorageFailure.decode("answer_kind")
                }
                do { return try AskChoiceId(required(value, "text_value")) } catch {
                    throw PaneContextStorageFailure.decode("answer_choice")
                }
            }
            return .choices(choices)
        }
        guard kind == "form" else { throw PaneContextStorageFailure.decode("answer_kind") }
        var values: [String: ElicitationValue] = [:]
        for value in rows {
            let name: String = try required(value, "field_name")
            guard values[name] == nil else { throw PaneContextStorageFailure.decode("answer_field") }
            let valueKind: String = try required(value, "value_kind")
            switch valueKind {
            case "string": values[name] = .string(try required(value, "text_value"))
            case "number":
                let text: String = try required(value, "text_value")
                guard let number = Double(text), number.isFinite else {
                    throw PaneContextStorageFailure.decode("answer_number")
                }
                values[name] = .number(number)
            case "integer": values[name] = .integer(try required(value, "integer_value"))
            case "boolean": values[name] = .boolean(try flag(value, "integer_value"))
            default: throw PaneContextStorageFailure.decode("answer_value_kind")
            }
        }
        return .form(ElicitationValues(properties: values))
    }

    static func askState(_ row: Row, children: PaneContextMessageChildren) throws -> AskState {
        let state: String = try required(row, "state")
        switch state {
        case "open": return .open
        case "handedBack": return .handedBack
        case "dismissed": return .dismissed
        case "expired": return .expired
        case "withdrawn": return .withdrawn
        case "stale": return .stale
        case "answered":
            guard try required(row, "answered_by") as String == "localUser" else {
                throw PaneContextStorageFailure.decode("answered_by")
            }
            let receipt = try answerReceipt(row)
            return .answered(by: .localUser, value: try answer(row, children: children), receipt: receipt)
        default: throw PaneContextStorageFailure.decode("state")
        }
    }

    static func answerReceipt(_ row: Row) throws -> AnswerReceipt {
        let receiptKind: String = try required(row, "receipt")
        switch receiptKind {
        case "notYetConfirmed": return .notYetConfirmed
        case "confirmed": return .confirmed(at: try date(row, "receipt_at"))
        case "unconfirmed": return .unconfirmed
        default: throw PaneContextStorageFailure.decode("receipt")
        }
    }

    static func outcome(_ state: AskState) -> AskOutcome? {
        switch state {
        case .open: nil
        case .answered(_, let value, _): .answered(value)
        case .handedBack, .dismissed: .handedBack
        case .expired: .expired
        case .withdrawn: .withdrawn
        case .stale: .stale
        }
    }

    static func refusal(_ state: AskState) -> AnswerRefusal {
        switch state {
        case .answered: .alreadyAnswered
        case .handedBack: .handedBack
        case .dismissed: .dismissed
        case .expired: .expired
        case .withdrawn: .withdrawn
        case .stale: .stale
        case .open: .notFound
        }
    }

    static func terminal(_ state: AskState) -> AskTerminalState? {
        switch state {
        case .open: nil
        case .answered(let person, let value, let receipt): .answered(by: person, value: value, receipt: receipt)
        case .handedBack: .handedBack
        case .dismissed: .dismissed
        case .expired: .expired
        case .withdrawn: .withdrawn
        case .stale: .stale
        }
    }
}
