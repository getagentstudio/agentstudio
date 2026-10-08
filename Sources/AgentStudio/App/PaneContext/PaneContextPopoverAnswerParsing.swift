import AgentStudioCore
import AgentStudioSharedComponents

enum PaneContextPopoverParsedAnswer: Sendable {
    case success(AskAnswerValue)
    case failure(AnswerRefusal)
}
enum PaneContextPopoverAnswerParsing {
    nonisolated static func message(_ id: AgentMessageId, detail: PaneContextDetail?) -> AgentMessageDetail? {
        guard let detail else { return nil }
        return detail.messages.first { $0.id == id }
            ?? detail.drawerMessages.lazy.flatMap(\.messages).first { $0.id == id }
    }

    @concurrent nonisolated static func parse(
        messageId: AgentMessageId, detail: PaneContextDetail?, draft: AskFormDraft
    ) async -> PaneContextPopoverParsedAnswer {
        guard let message = message(messageId, detail: detail) else { return .failure(.notFound) }
        guard case .ask(_, let form, _, _) = message.shape else { return .failure(.invalidAnswer(.formMismatch)) }
        switch form {
        case .choice:
            do { return .success(.choices(try draft.selectedChoices.map { try AskChoiceId($0) })) } catch {
                return .failure(.invalidAnswer(.choiceCount))
            }
        case .freeText:
            return .success(.text(draft.text))
        case .elicitation(let schema):
            var fields: [String: ElicitationValue] = [:]
            for property in schema.properties {
                switch property.type {
                case .boolean:
                    fields[property.name] = .boolean(draft.booleans[property.name] ?? false)
                case .string:
                    if let text = draft.fields[property.name] { fields[property.name] = .string(text) }
                case .number:
                    if let text = draft.fields[property.name] {
                        guard let number = Double(text) else {
                            return .failure(.invalidAnswer(.invalidField(property.name)))
                        }
                        fields[property.name] = .number(number)
                    }
                case .integer:
                    if let text = draft.fields[property.name] {
                        guard let integer = Int64(text) else {
                            return .failure(.invalidAnswer(.invalidField(property.name)))
                        }
                        fields[property.name] = .integer(integer)
                    }
                }
            }
            return .success(.form(.init(properties: fields)))
        }
    }

    @concurrent nonisolated static func canDismiss(
        messageId: AgentMessageId, detail: PaneContextDetail?, location: PaneContextPopoverLocation
    ) async -> Bool {
        if location == .pane { return true }
        guard let message = message(messageId, detail: detail) else { return false }
        if case .notice = message.shape { return true }
        return false
    }

}
