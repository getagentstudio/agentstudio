import AgentStudioCore
import AgentStudioSharedComponents

enum PaneContextPopoverParsedAnswer: Sendable {
    case success(AskAnswerValue)
    case failure(AnswerRefusal)
}
enum PaneContextPopoverAnswerParsing {
    nonisolated static func message(_ id: AgentMessageId, source: PaneId, detail: PaneContextDetail?)
        -> AgentMessageDetail?
    {
        guard let detail else { return nil }
        if source == detail.paneId { return detail.messages.first { $0.id == id && $0.sourcePaneId == source } }
        return detail.drawerMessages.first { $0.sourcePaneId == source }?.messages.first { $0.id == id }
    }

    @concurrent nonisolated static func parse(
        messageId: AgentMessageId, source: PaneId, detail: PaneContextDetail?, draft: AskFormDraft
    ) async -> PaneContextPopoverParsedAnswer {
        guard let message = message(messageId, source: source, detail: detail) else { return .failure(.notFound) }
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

    @concurrent nonisolated static func answerPresentation(
        messageId: AgentMessageId, source: PaneId, detail: PaneContextDetail?, location: PaneContextPopoverLocation
    ) async -> PaneContextInteractionPresentation {
        guard let message = message(messageId, source: source, detail: detail),
            case .ask(_, let form, _, _) = message.shape
        else { return .notApplicable }
        return location.presentation(for: .answer(PaneContextPopoverShaping.form(form)))
    }

    @concurrent nonisolated static func canDismiss(
        messageId: AgentMessageId, source: PaneId, detail: PaneContextDetail?, location: PaneContextPopoverLocation
    ) async -> Bool {
        guard let message = message(messageId, source: source, detail: detail) else { return false }
        switch message.shape {
        case .notice: return location.presentation(for: .noticeActions) == .inline
        case .ask: return location.presentation(for: .dismissAsk) == .inline
        }
    }

    @concurrent nonisolated static func canRunAction(
        messageId: AgentMessageId, source: PaneId, detail: PaneContextDetail?, location: PaneContextPopoverLocation
    ) async -> Bool {
        guard let message = message(messageId, source: source, detail: detail),
            PaneContextPresentationRules.rowActionAvailability(message) == .noticeActions
        else { return false }
        return location.presentation(for: .noticeActions) == .inline
    }

}
