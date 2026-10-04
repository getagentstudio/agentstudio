import Foundation
import GRDB

enum PaneContextStoredFormKind: String {
    case choice
    case freeText
    case elicitation
}

extension PaneContextStorage {
    static func formFields(_ form: AskForm) -> [String: DatabaseValue] {
        switch form {
        case .choice(_, let multiple):
            ["form_kind": sqlValue("choice"), "allows_multiple": sqlValue(multiple ? 1 : 0)]
        case .freeText(let placeholder):
            ["form_kind": sqlValue("freeText"), "placeholder": sqlValue(placeholder)]
        case .elicitation:
            ["form_kind": sqlValue("elicitation")]
        }
    }

    static func saveForm(_ form: AskForm, database: Database, requestId: UUID) throws {
        switch form {
        case .freeText: break
        case .choice(let options, _):
            for (ordinal, choice) in options.enumerated() {
                try insert(
                    database, table: "pane_request_choice",
                    fields: [
                        "request_id": sqlValue(requestId.uuidString), "ordinal": sqlValue(ordinal),
                        "choice_id": sqlValue(choice.id.value), "label": sqlValue(choice.label),
                    ])
            }
        case .elicitation(let schema):
            for (ordinal, property) in schema.properties.enumerated() {
                var fields: [String: DatabaseValue] = [
                    "request_id": sqlValue(requestId.uuidString), "ordinal": sqlValue(ordinal),
                    "name": sqlValue(property.name), "title": sqlValue(property.title),
                    "description": sqlValue(property.description),
                ]
                switch property.type {
                case .boolean: fields["property_kind"] = sqlValue("boolean")
                case .number(let constraints), .integer(let constraints):
                    if case .number = property.type {
                        fields["property_kind"] = sqlValue("number")
                    } else {
                        fields["property_kind"] = sqlValue("integer")
                    }
                    fields["minimum"] = sqlValue(constraints.minimum.map { String($0) })
                    fields["maximum"] = sqlValue(constraints.maximum.map { String($0) })
                case .string(let constraints):
                    fields["property_kind"] = sqlValue("string")
                    fields["min_length"] = sqlValue(constraints.minLength)
                    fields["max_length"] = sqlValue(constraints.maxLength)
                    fields["format"] = sqlValue(constraints.format.map(formatName))
                    fields["enum_present"] = sqlValue(constraints.choices == nil ? 0 : 1)
                }
                try insert(database, table: "pane_request_property", fields: fields)
                if case .string(let constraints) = property.type, let choices = constraints.choices {
                    for (choiceOrdinal, choice) in choices.enumerated() {
                        try insert(
                            database, table: "pane_request_property_choice",
                            fields: [
                                "request_id": sqlValue(requestId.uuidString), "property_ordinal": sqlValue(ordinal),
                                "ordinal": sqlValue(choiceOrdinal), "value": sqlValue(choice),
                            ])
                    }
                }
            }
            for (ordinal, name) in schema.required.enumerated() {
                try insert(
                    database, table: "pane_request_required",
                    fields: [
                        "request_id": sqlValue(requestId.uuidString), "ordinal": sqlValue(ordinal),
                        "name": sqlValue(name),
                    ])
            }
        }
    }

    static func form(_ row: PaneContextReadRow, children: PaneContextMessageChildren) throws -> AskForm {
        let requestId = try uuid(row, .id)
        let kind = try formKind(row)
        switch kind {
        case .freeText: return .freeText(placeholder: try optional(row, .placeholder))
        case .choice:
            let options = try (children.choices[requestId] ?? []).map { choice in
                do {
                    return AskChoice(
                        id: try AskChoiceId(required(choice, .choiceId)), label: try required(choice, .label))
                } catch { throw PaneContextStorageFailure.decode("choice") }
            }
            return .choice(options: options, allowsMultiple: try flag(row, .allowsMultiple))
        case .elicitation:
            let rows = children.properties[requestId] ?? []
            let properties = try rows.map { try property($0, children: children, requestId: requestId) }
            let requiredNames: [String] = try (children.requiredNames[requestId] ?? []).map { try required($0, .name) }
            return .elicitation(ElicitationSchema(properties: properties, required: requiredNames))
        }
    }

    static func formKind(_ row: PaneContextReadRow) throws -> PaneContextStoredFormKind {
        guard let kind = PaneContextStoredFormKind(rawValue: try required(row, .formKind)) else {
            throw PaneContextStorageFailure.decode("form_kind")
        }
        return kind
    }

    private static func property(_ row: PaneContextReadRow, children: PaneContextMessageChildren, requestId: UUID)
        throws
        -> ElicitationProperty
    {
        let kind: String = try required(row, .propertyKind)
        let type: ElicitationPropertyType
        switch kind {
        case "boolean": type = .boolean
        case "number", "integer":
            let constraints = ElicitationNumberConstraints(
                minimum: try decimal(row, .minimum), maximum: try decimal(row, .maximum))
            type = kind == "number" ? .number(constraints) : .integer(constraints)
        case "string":
            let ordinal: Int = try required(row, .ordinal)
            let choices: [String] = try (children.propertyChoices[requestId] ?? []).filter { choice in
                let storedOrdinal: DatabaseValue = try choice.value(.propertyOrdinal)
                return storedOrdinal == ordinal.databaseValue
            }.map { try required($0, .value) }
            let format: String? = try optional(row, .format)
            type = .string(
                ElicitationStringConstraints(
                    choices: try flag(row, .enumPresent) ? choices : nil, minLength: try optional(row, .minLength),
                    maxLength: try optional(row, .maxLength), format: try format.map(parseFormat)))
        default: throw PaneContextStorageFailure.decode("property_kind")
        }
        return ElicitationProperty(
            name: try required(row, .name), title: try optional(row, .title),
            description: try optional(row, .description), type: type)
    }

    private static func decimal(_ row: PaneContextReadRow, _ field: PaneContextReadColumn) throws -> Double? {
        let text: String? = try optional(row, field)
        guard let text else { return nil }
        guard let value = Double(text), value.isFinite else { throw PaneContextStorageFailure.decode(field.sqlName) }
        return value
    }

    private static func formatName(_ format: ElicitationStringFormat) -> String {
        switch format {
        case .email: "email"
        case .uri: "uri"
        case .date: "date"
        }
    }

    private static func parseFormat(_ name: String) throws -> ElicitationStringFormat {
        switch name {
        case "email": return .email
        case "uri": return .uri
        case "date": return .date
        default: throw PaneContextStorageFailure.decode("format")
        }
    }
}
