import AgentStudioCore
import AgentStudioSharedComponents
import Foundation

extension PaneContextPopoverShaping {
    nonisolated static func sender(_ sender: AgentMessageSender) -> MessageSenderModel {
        switch sender {
        case .pane(let id): .pane(id.uuid)
        case .session(let provider, let sessionRef, let generation):
            .session(provider: provider.value, sessionRef: sessionRef.value, bindingGeneration: generation)
        }
    }

    nonisolated static func reason(_ reason: AskReason) -> AskReasonModel {
        switch reason {
        case .approval: .approval
        case .question: .question
        case .blocked: .blocked
        }
    }

    nonisolated static func action(_ action: MessageAction) -> MessageActionModel {
        switch action {
        case .openFile(let path, let line): .openFile(path: path, line: line)
        case .goToPane(let id): .goToPane(id.uuid)
        case .openPullRequest(let identity):
            .openPullRequest(
                PullRequestIdentityModel(
                    host: identity.host, owner: identity.owner, repository: identity.repository, number: identity.number
                ))
        }
    }

    nonisolated static func askState(_ state: AskState) -> AskStateModel {
        switch state {
        case .open: .open
        case .answered(_, let value, let receipt):
            .answered(by: .localUser, value: answer(value), receipt: self.receipt(receipt))
        case .handedBack: .handedBack
        case .dismissed: .dismissed
        case .expired: .expired
        case .withdrawn: .withdrawn
        case .stale: .stale
        }
    }

    nonisolated static func answer(_ value: AskAnswerValue) -> AskAnswerModel {
        switch value {
        case .choices(let ids): .choices(ids.map(\.value))
        case .text(let text): .text(text)
        case .form(let form):
            .form(
                form.properties.mapValues {
                    switch $0 {
                    case .string(let value): .string(value)
                    case .number(let value): .number(value)
                    case .integer(let value): .integer(value)
                    case .boolean(let value): .boolean(value)
                    }
                })
        }
    }

    nonisolated static func receipt(_ receipt: AnswerReceipt) -> AnswerReceiptModel {
        switch receipt {
        case .notYetConfirmed: .notYetConfirmed
        case .confirmed(let at): .confirmed(at: at)
        case .unconfirmed: .unconfirmed
        }
    }

    nonisolated static func form(_ form: AskForm) -> AskFormModel {
        switch form {
        case .choice(let options, let allowsMultiple):
            .choice(
                options: options.map {
                    AskChoiceModel(
                        id: $0.id.value, label: $0.label,
                        control: PaneContextPopoverControlProjection.control(
                            .selectPaneMessageChoice($0), identifier: "pane-context.choice.\($0.id.value)"))
                },
                allowsMultiple: allowsMultiple)
        case .freeText(let placeholder): .freeText(placeholder: placeholder)
        case .elicitation(let schema):
            .elicitation(
                schema.properties.map { property in
                    let kind: ElicitationPropertyKindModel
                    switch property.type {
                    case .string(let constraints):
                        let format: ElicitationStringFormatModel?
                        switch constraints.format {
                        case nil: format = nil
                        case .email: format = .email
                        case .uri: format = .uri
                        case .date: format = .date
                        }
                        kind = .string(
                            choices: constraints.choices, minLength: constraints.minLength,
                            maxLength: constraints.maxLength, format: format)
                    case .number(let constraints):
                        kind = .number(minimum: constraints.minimum, maximum: constraints.maximum)
                    case .integer(let constraints):
                        kind = .integer(minimum: constraints.minimum, maximum: constraints.maximum)
                    case .boolean: kind = .boolean
                    }
                    return ElicitationPropertyModel(
                        name: property.name, title: property.title, description: property.description,
                        required: schema.required.contains(property.name), kind: kind)
                })
        }
    }
}
