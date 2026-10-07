import Foundation

package enum IPCPaneElicitationStringFormat: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case email
    case uri
    case date
}

package enum IPCPaneElicitationPropertyType: Codable, Equatable, Sendable, IPCSchemaProviding {
    case string(choices: [String]?, minLength: Int?, maxLength: Int?, format: IPCPaneElicitationStringFormat?)
    case number(minimum: Double?, maximum: Double?)
    case integer(minimum: Double?, maximum: Double?)
    case boolean

    private enum CodingKeys: String, CodingKey {
        case kind
        case choices
        case minLength
        case maxLength
        case format
        case minimum
        case maximum
    }
    private enum Kind: String, Codable {
        case string
        case number
        case integer
        case boolean
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string:
            self = .string(
                choices: try container.decodeIfPresent([String].self, forKey: .choices),
                minLength: try container.decodeIfPresent(Int.self, forKey: .minLength),
                maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength),
                format: try container.decodeIfPresent(IPCPaneElicitationStringFormat.self, forKey: .format))
        case .number:
            self = .number(
                minimum: try container.decodeIfPresent(Double.self, forKey: .minimum),
                maximum: try container.decodeIfPresent(Double.self, forKey: .maximum))
        case .integer:
            self = .integer(
                minimum: try container.decodeIfPresent(Double.self, forKey: .minimum),
                maximum: try container.decodeIfPresent(Double.self, forKey: .maximum))
        case .boolean: self = .boolean
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let choices, let minLength, let maxLength, let format):
            try container.encode(Kind.string, forKey: .kind)
            try container.encodeIfPresent(choices, forKey: .choices)
            try container.encodeIfPresent(minLength, forKey: .minLength)
            try container.encodeIfPresent(maxLength, forKey: .maxLength)
            try container.encodeIfPresent(format, forKey: .format)
        case .number(let minimum, let maximum):
            try container.encode(Kind.number, forKey: .kind)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(maximum, forKey: .maximum)
        case .integer(let minimum, let maximum):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(maximum, forKey: .maximum)
        case .boolean:
            try container.encode(Kind.boolean, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "string", schema: .string(allowedValues: ["string"])),
                .optional("choices", description: "choices", schema: .array(items: .string())),
                .optional("minLength", description: "minLength", schema: IPCSchemaScalars.signedInteger),
                .optional("maxLength", description: "maxLength", schema: IPCSchemaScalars.signedInteger),
                .optional("format", description: "format", schema: try IPCPaneElicitationStringFormat.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "number", schema: .string(allowedValues: ["number"])),
                .optional("minimum", description: "minimum", schema: .number()),
                .optional("maximum", description: "maximum", schema: .number()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "integer", schema: .string(allowedValues: ["integer"])),
                .optional("minimum", description: "minimum", schema: .number()),
                .optional("maximum", description: "maximum", schema: .number()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "boolean", schema: .string(allowedValues: ["boolean"]))
            ]),
        ])
    }
}
package struct IPCPaneElicitationProperty: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let name: String
    package let title: String?
    package let description: String?
    package let type: IPCPaneElicitationPropertyType

    package init(name: String, title: String? = nil, description: String? = nil, type: IPCPaneElicitationPropertyType) {
        self.name = name
        self.title = title
        self.description = description
        self.type = type
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "name", description: "name", schema: .string()),
            .optional("title", description: "title", schema: .string()),
            .optional("description", description: "description", schema: .string()),
            .init(name: "type", description: "type", schema: try IPCPaneElicitationPropertyType.ipcSchema()),
        ])
    }
}
package struct IPCPaneElicitationSchema: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let properties: [IPCPaneElicitationProperty]
    package let required: [String]

    package init(properties: [IPCPaneElicitationProperty], required: [String]) {
        self.properties = properties
        self.required = required
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "properties", description: "properties",
                schema: .array(items: try IPCPaneElicitationProperty.ipcSchema())),
            .init(name: "required", description: "required", schema: .array(items: .string())),
        ])
    }
}
package enum IPCPaneElicitationValue: Codable, Equatable, Sendable, IPCSchemaProviding {
    case string(value: String)
    case number(value: Double)
    case integer(value: Int)
    case boolean(value: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }
    private enum Kind: String, Codable {
        case string
        case number
        case integer
        case boolean
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(value: try container.decode(String.self, forKey: .value))
        case .number: self = .number(value: try container.decode(Double.self, forKey: .value))
        case .integer: self = .integer(value: try container.decode(Int.self, forKey: .value))
        case .boolean: self = .boolean(value: try container.decode(Bool.self, forKey: .value))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "string", schema: .string(allowedValues: ["string"])),
                .init(name: "value", description: "value", schema: .string()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "number", schema: .string(allowedValues: ["number"])),
                .init(name: "value", description: "value", schema: .number()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "integer", schema: .string(allowedValues: ["integer"])),
                .init(name: "value", description: "value", schema: IPCSchemaScalars.signedInteger),
            ]),
            .object(fields: [
                .init(name: "kind", description: "boolean", schema: .string(allowedValues: ["boolean"])),
                .init(name: "value", description: "value", schema: .boolean),
            ]),
        ])
    }
}
package struct IPCPaneElicitationValues: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let properties: [String: IPCPaneElicitationValue]

    package init(properties: [String: IPCPaneElicitationValue]) {
        self.properties = properties
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "properties", description: "properties",
                schema: .dictionary(values: try IPCPaneElicitationValue.ipcSchema()))
        ])
    }
}
package enum IPCPaneAskForm: Codable, Equatable, Sendable, IPCSchemaProviding {
    case choice(options: [IPCPaneAskChoice], allowsMultiple: Bool)
    case freeText(placeholder: String?)
    case elicitation(schema: IPCPaneElicitationSchema)

    private enum CodingKeys: String, CodingKey {
        case kind
        case options
        case allowsMultiple
        case placeholder
        case schema
    }
    private enum Kind: String, Codable {
        case choice
        case freeText
        case elicitation
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .choice:
            self = .choice(
                options: try container.decode([IPCPaneAskChoice].self, forKey: .options),
                allowsMultiple: try container.decode(Bool.self, forKey: .allowsMultiple))
        case .freeText: self = .freeText(placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder))
        case .elicitation:
            self = .elicitation(schema: try container.decode(IPCPaneElicitationSchema.self, forKey: .schema))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let options, let allowsMultiple):
            try container.encode(Kind.choice, forKey: .kind)
            try container.encode(options, forKey: .options)
            try container.encode(allowsMultiple, forKey: .allowsMultiple)
        case .freeText(let placeholder):
            try container.encode(Kind.freeText, forKey: .kind)
            try container.encodeIfPresent(placeholder, forKey: .placeholder)
        case .elicitation(let schema):
            try container.encode(Kind.elicitation, forKey: .kind)
            try container.encode(schema, forKey: .schema)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "choice", schema: .string(allowedValues: ["choice"])),
                .init(name: "options", description: "options", schema: .array(items: try IPCPaneAskChoice.ipcSchema())),
                .init(name: "allowsMultiple", description: "allowsMultiple", schema: .boolean),
            ]),
            .object(fields: [
                .init(name: "kind", description: "freeText", schema: .string(allowedValues: ["freeText"])),
                .optional("placeholder", description: "placeholder", schema: .string()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "elicitation", schema: .string(allowedValues: ["elicitation"])),
                .init(name: "schema", description: "schema", schema: try IPCPaneElicitationSchema.ipcSchema()),
            ]),
        ])
    }
}
package enum IPCPaneAskAnswerValue: Codable, Equatable, Sendable, IPCSchemaProviding {
    case choices(ids: [String])
    case text(value: String)
    case form(values: IPCPaneElicitationValues)

    private enum CodingKeys: String, CodingKey {
        case kind
        case ids
        case value
        case values
    }
    private enum Kind: String, Codable {
        case choices
        case text
        case form
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .choices: self = .choices(ids: try container.decode([String].self, forKey: .ids))
        case .text: self = .text(value: try container.decode(String.self, forKey: .value))
        case .form: self = .form(values: try container.decode(IPCPaneElicitationValues.self, forKey: .values))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choices(let ids):
            try container.encode(Kind.choices, forKey: .kind)
            try container.encode(ids, forKey: .ids)
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .form(let values):
            try container.encode(Kind.form, forKey: .kind)
            try container.encode(values, forKey: .values)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "choices", schema: .string(allowedValues: ["choices"])),
                .init(name: "ids", description: "ids", schema: .array(items: .string())),
            ]),
            .object(fields: [
                .init(name: "kind", description: "text", schema: .string(allowedValues: ["text"])),
                .init(name: "value", description: "value", schema: .string()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "form", schema: .string(allowedValues: ["form"])),
                .init(name: "values", description: "values", schema: try IPCPaneElicitationValues.ipcSchema()),
            ]),
        ])
    }
}
