import AgentStudioInfrastructure
import Foundation

enum PaneContextAdmission {
    static func refusal(_ request: PaneMessageSendRequest) -> PaneContextWriteRefusal? {
        let limits = AppPolicies.PaneContext.self
        if request.body.utf8.count > limits.maximumBodyBytes { return .tooLarge(.body) }
        if (request.why?.utf8.count ?? 0) > limits.maximumWhyBytes { return .tooLarge(.why) }
        if request.actions.count > limits.maximumActions { return .tooLarge(.actions) }
        if request.actions.contains(where: { actionBytes($0) > limits.maximumActionBytes }) {
            return .tooLarge(.actions)
        }
        guard case .ask(_, let form, _) = request.shape else { return nil }
        switch form {
        case .choice(let options, _):
            if options.count > limits.maximumChoices { return .tooLarge(.choices) }
            if options.contains(where: { $0.label.utf8.count > limits.maximumChoiceLabelBytes }) {
                return .tooLarge(.choiceLabel)
            }
            if options.isEmpty || Set(options.map(\.id)).count != options.count { return .invalidField(.form) }
        case .freeText: break
        case .elicitation(let schema):
            if schema.properties.count > limits.maximumFormProperties { return .tooLarge(.form) }
            let names = Set(schema.properties.map(\.name))
            if names.count != schema.properties.count || !Set(schema.required).isSubset(of: names) {
                return .invalidField(.form)
            }
            if schema.properties.contains(where: { !validProperty($0) }) { return .invalidField(.form) }
        }
        if formBytes(form) > limits.maximumFormBytes { return .tooLarge(.form) }
        return nil
    }

    static func lineRefusal(_ line: AgentLineInput?) -> PaneContextWriteRefusal? {
        guard let line else { return nil }
        let limits = AppPolicies.PaneContext.self
        if line.summary.utf8.count > limits.maximumLineSummaryBytes
            || (line.detail?.utf8.count ?? 0) > limits.maximumLineDetailBytes
            || line.refs.count > limits.maximumLineRefs
            || line.refs.contains(where: { actionBytes($0) > limits.maximumLineRefBytes })
        {
            return .tooLarge(.agentLine)
        }
        switch line.work {
        case .monitoring(let text), .blockedOnYou(let text), .failed(let text):
            if text.utf8.count > limits.maximumLineWorkBytes { return .tooLarge(.agentLine) }
        case .working(.step(let current, let total)):
            if current > limits.maximumLineStep || total > limits.maximumLineStep { return .tooLarge(.agentLine) }
            if current < 0 || total <= 0 || current > total { return .invalidField(.agentLine) }
        case .working(.indeterminate), .done: break
        }
        return nil
    }

    static func answerInvalidity(_ answer: AskAnswerValue, form: AskForm) -> AnswerInvalidity? {
        if answerBytes(answer) > AppPolicies.PaneContext.maximumAnswerBytes { return .textTooLarge }
        switch (form, answer) {
        case (.freeText, .text): return nil
        case (.choice(let options, let multiple), .choices(let choices)):
            let allowed = Set(options.map(\.id))
            if let unknown = choices.first(where: { !allowed.contains($0) }) { return .unknownChoice(unknown) }
            if (!multiple && choices.count != 1) || Set(choices).count != choices.count { return .choiceCount }
            return nil
        case (.elicitation(let schema), .form(let values)):
            for name in schema.required where values.properties[name] == nil { return .invalidField(name) }
            let properties = Dictionary(
                schema.properties.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for (name, value) in values.properties {
                guard let property = properties[name], validValue(value, for: property.type) else {
                    return .invalidField(name)
                }
            }
            return nil
        default: return .formMismatch
        }
    }

    static func actionBytes(_ action: MessageAction) -> Int {
        let fields: [String: Any]
        switch action {
        case .openFile(let path, let line):
            var value: [String: Any] = ["kind": "openFile", "path": path]
            if let line { value["line"] = line }
            fields = value
        case .openPullRequest(let identity):
            fields = [
                "kind": "openPullRequest",
                "identity": [
                    "host": identity.host, "owner": identity.owner, "repository": identity.repository,
                    "number": identity.number,
                ],
            ]
        case .goToPane(let pane): fields = ["kind": "goToPane", "paneId": pane.uuidString]
        }
        return encodedBytes(fields)
    }

    static func formBytes(_ form: AskForm) -> Int {
        switch form {
        case .freeText(let placeholder):
            var fields: [String: Any] = ["kind": "freeText"]
            if let placeholder { fields["placeholder"] = placeholder }
            return encodedBytes(fields)
        case .choice(let options, let multiple):
            return encodedBytes([
                "kind": "choice", "allowsMultiple": multiple,
                "options": options.map { ["id": $0.id.value, "label": $0.label] },
            ])
        case .elicitation(let schema):
            return encodedBytes([
                "kind": "elicitation",
                "schema": ["properties": schema.properties.map(propertyFields), "required": schema.required],
            ])
        }
    }

    static func answerBytes(_ answer: AskAnswerValue) -> Int {
        switch answer {
        case .text(let text): text.utf8.count
        case .choices(let ids): ids.reduce(0) { $0 + $1.value.utf8.count }
        case .form(let values):
            values.properties.reduce(0) { total, pair in
                let count: Int
                switch pair.value {
                case .string(let text): count = text.utf8.count
                case .number(let number): count = String(number).utf8.count
                case .integer(let number): count = String(number).utf8.count
                case .boolean(let value): count = value.description.utf8.count
                }
                return total + pair.key.utf8.count + count
            }
        }
    }

    private static func encodedBytes(_ fields: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: fields).count) ?? Int.max
    }

    private static func propertyFields(_ property: ElicitationProperty) -> [String: Any] {
        var fields: [String: Any] = ["name": property.name]
        if let title = property.title { fields["title"] = title }
        if let description = property.description { fields["description"] = description }
        var type: [String: Any] = [:]
        switch property.type {
        case .boolean: type["kind"] = "boolean"
        case .number(let constraints), .integer(let constraints):
            if case .number = property.type { type["kind"] = "number" } else { type["kind"] = "integer" }
            if let minimum = constraints.minimum { type["minimum"] = minimum }
            if let maximum = constraints.maximum { type["maximum"] = maximum }
        case .string(let constraints):
            type["kind"] = "string"
            if let choices = constraints.choices { type["choices"] = choices }
            if let minimum = constraints.minLength { type["minLength"] = minimum }
            if let maximum = constraints.maxLength { type["maxLength"] = maximum }
            switch constraints.format {
            case nil: break
            case .email: type["format"] = "email"
            case .uri: type["format"] = "uri"
            case .date: type["format"] = "date"
            }
        }
        fields["type"] = type
        return fields
    }

    private static func validProperty(_ property: ElicitationProperty) -> Bool {
        guard !property.name.isEmpty else { return false }
        switch property.type {
        case .boolean: return true
        case .string(let constraints):
            return (constraints.minLength ?? 0) >= 0
                && (constraints.maxLength ?? Int.max) >= (constraints.minLength ?? 0)
                && constraints.choices?.isEmpty != true
        case .number(let constraints), .integer(let constraints):
            return (constraints.minimum?.isFinite ?? true) && (constraints.maximum?.isFinite ?? true)
                && (constraints.minimum ?? -Double.greatestFiniteMagnitude)
                    <= (constraints.maximum ?? Double.greatestFiniteMagnitude)
        }
    }

    private static func validValue(_ value: ElicitationValue, for type: ElicitationPropertyType) -> Bool {
        switch (value, type) {
        case (.boolean, .boolean): return true
        case (.number(let number), .number(let constraints)):
            return number.isFinite && inRange(number, constraints: constraints)
        case (.integer(let integer), .integer(let constraints)), (.integer(let integer), .number(let constraints)):
            return inRange(Double(integer), constraints: constraints)
        case (.string(let text), .string(let constraints)):
            guard text.count >= (constraints.minLength ?? 0), text.count <= (constraints.maxLength ?? Int.max),
                constraints.choices.map({ $0.contains(text) }) ?? true
            else { return false }
            switch constraints.format {
            case nil: return true
            case .email:
                let parts = text.split(separator: "@", omittingEmptySubsequences: false)
                return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !text.contains(where: \.isWhitespace)
            case .uri: return URLComponents(string: text)?.scheme != nil
            case .date:
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                return formatter.date(from: text) != nil
            }
        default: return false
        }
    }

    private static func inRange(_ value: Double, constraints: ElicitationNumberConstraints) -> Bool {
        value >= (constraints.minimum ?? -Double.greatestFiniteMagnitude)
            && value <= (constraints.maximum ?? Double.greatestFiniteMagnitude)
    }
}
