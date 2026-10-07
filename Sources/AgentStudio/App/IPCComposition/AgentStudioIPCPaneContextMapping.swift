import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

/// Explicit wire/domain translations. Persistence and semantic validation stay
/// with PaneContextService; the adapter owns encoded wire-size admission.
enum PaneContextIPCMapping {
    static func importance(_ value: IPCPaneMessageImportance) -> MessageImportance {
        switch value {
        case .info: .info
        case .attention: .attention
        case .done: .done
        case .failure: .failure
        }
    }

    static func reason(_ value: IPCPaneAskReason) -> AskReason {
        switch value {
        case .approval: .approval
        case .question: .question
        case .blocked: .blocked
        }
    }

    static func reason(_ value: AskReason) -> IPCPaneAskReason {
        switch value {
        case .approval: .approval
        case .question: .question
        case .blocked: .blocked
        }
    }

    static func action(_ value: IPCPaneMessageAction) throws -> MessageAction {
        switch value {
        case .openFile(let path, let line): return .openFile(path: path, line: line)
        case .goToPane(let paneId): return .goToPane(PaneId(existingUUID: paneId))
        case .openPullRequest(let identity):
            do {
                return .openPullRequest(
                    try ForgePullRequestIdentity(
                        host: identity.host, owner: identity.owner, repository: identity.repository,
                        number: identity.number))
            } catch { throw AppIPCPaneContextError(reason: .invalidField, field: "actions") }
        }
    }

    static func form(_ value: IPCPaneAskForm) throws -> AskForm {
        guard try JSONEncoder().encode(value).count <= AppPolicies.PaneContext.maximumFormBytes else {
            throw AppIPCPaneContextError(reason: .tooLarge, field: "form")
        }
        switch value {
        case .choice(let options, let allowsMultiple):
            do {
                return .choice(
                    options: try options.map { AskChoice(id: try AskChoiceId($0.id), label: $0.label) },
                    allowsMultiple: allowsMultiple)
            } catch { throw AppIPCPaneContextError(reason: .invalidField, field: "choices") }
        case .freeText(let placeholder): return .freeText(placeholder: placeholder)
        case .elicitation(let schema):
            return .elicitation(
                ElicitationSchema(
                    properties: schema.properties.map { property in
                        ElicitationProperty(
                            name: property.name, title: property.title, description: property.description,
                            type: propertyType(property.type))
                    }, required: schema.required))
        }
    }

    static func propertyType(_ value: IPCPaneElicitationPropertyType) -> ElicitationPropertyType {
        switch value {
        case .string(let choices, let minLength, let maxLength, let format):
            return .string(
                ElicitationStringConstraints(
                    choices: choices, minLength: minLength, maxLength: maxLength, format: format.map(stringFormat)))
        case .number(let minimum, let maximum):
            return .number(ElicitationNumberConstraints(minimum: minimum, maximum: maximum))
        case .integer(let minimum, let maximum):
            return .integer(ElicitationNumberConstraints(minimum: minimum, maximum: maximum))
        case .boolean: return .boolean
        }
    }

    static func stringFormat(_ value: IPCPaneElicitationStringFormat) -> ElicitationStringFormat {
        switch value {
        case .email: .email
        case .uri: .uri
        case .date: .date
        }
    }

    static func work(_ value: IPCPaneAgentLineWork) -> AgentLineWork {
        switch value {
        case .working(let progress):
            switch progress {
            case .indeterminate: return .working(.indeterminate)
            case .step(let current, let total): return .working(.step(current: current, total: total))
            }
        case .monitoring(let target): return .monitoring(target)
        case .blockedOnYou(let action): return .blockedOnYou(action: action)
        case .done: return .done
        case .failed(let summary): return .failed(summary: summary)
        }
    }

    static func lifetime(_ value: IPCPaneAgentLineLifetime) -> AgentLineLifetime {
        switch value {
        case .untilReplaced: .untilReplaced
        case .expires(let at): .expires(at: at)
        }
    }

    static func line(_ value: IPCPaneAgentLineInput) throws -> AgentLineInput {
        for reference in value.refs {
            guard try JSONEncoder().encode(reference).count <= AppPolicies.PaneContext.maximumLineRefBytes else {
                throw AppIPCPaneContextError(reason: .tooLarge, field: "agentLine")
            }
        }
        return AgentLineInput(
            summary: value.summary, work: work(value.work), detail: value.detail,
            refs: try value.refs.map(action), lifetime: lifetime(value.lifetime))
    }

    static func validateActions(_ values: [IPCPaneMessageAction]) throws {
        for value in values {
            guard try JSONEncoder().encode(value).count <= AppPolicies.PaneContext.maximumActionBytes else {
                throw AppIPCPaneContextError(reason: .tooLarge, field: "actions")
            }
        }
    }

    static func refusal(_ value: PaneContextWriteRefusal) -> AppIPCPaneContextError {
        switch value {
        case .conflict: .init(reason: .conflict)
        case .bindingRequired: .init(reason: .bindingRequired)
        case .writerReplaced: .init(reason: .stale, staleness: .writerReplaced)
        case .paneGone: .init(reason: .paneGone)
        case .notSender: .init(reason: .notSender)
        case .noticeAlreadyRead: .init(reason: .noticeAlreadyRead)
        case .tooLarge(let field): .init(reason: .tooLarge, field: limitField(field))
        case .invalidField(let field): .init(reason: .invalidField, field: limitField(field))
        }
    }

    static func limitField(_ value: PaneContextLimitField) -> String {
        switch value {
        case .body: "body"
        case .why: "why"
        case .choices: "choices"
        case .choiceLabel: "choiceLabel"
        case .form: "form"
        case .answer: "answer"
        case .actions: "actions"
        case .agentLine: "agentLine"
        case .title: "title"
        case .openAsks: "openAsks"
        case .unreadNotices: "unreadNotices"
        }
    }

    static func outcome(_ value: AskOutcome) -> IPCPaneAskOutcome {
        switch value {
        case .answered(let value): .answered(value: answer(value))
        case .handedBack: .handedBack
        case .expired: .expired
        case .withdrawn: .withdrawn
        case .stale: .stale
        }
    }

    static func answer(_ value: AskAnswerValue) -> IPCPaneAskAnswerValue {
        switch value {
        case .choices(let ids): return .choices(ids: ids.map(\.value))
        case .text(let text): return .text(value: text)
        case .form(let values):
            return .form(
                values: IPCPaneElicitationValues(
                    properties: values.properties.mapValues { value in
                        switch value {
                        case .string(let text): .string(value: text)
                        case .number(let number): .number(value: number)
                        case .integer(let number): .integer(value: Int(number))
                        case .boolean(let flag): .boolean(value: flag)
                        }
                    }))
        }
    }

    static func orderedResult(_ value: PaneOrderedWriteResult) throws -> IPCPaneOrderedWriteResult {
        switch value {
        case .applied: return .applied
        case .stale(let reason):
            switch reason {
            case .lastAccepted(let number):
                try IPCPaneNumericCoding.requireSafe(number.epoch)
                try IPCPaneNumericCoding.requireSafe(number.counter)
                return .stale(reason: .lastAccepted(writeNumber: .init(epoch: number.epoch, counter: number.counter)))
            case .epochSuperseded: return .stale(reason: .epochSuperseded)
            case .writerReplaced: return .stale(reason: .writerReplaced)
            }
        case .refused(let value): throw refusal(value)
        case .unavailable: throw AppIPCPaneContextError(reason: .unavailable)
        }
    }
}
