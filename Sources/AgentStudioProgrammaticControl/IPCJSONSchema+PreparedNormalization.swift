import Foundation

/// JSON that has passed one complete walk through its owning schema.
/// Construction stays inside schema normalization so raw bytes cannot enter
/// APIs that intentionally skip that walk.
package struct IPCNormalizedJSON: Equatable, Sendable {
    package let data: Data
    fileprivate let schema: IPCJSONSchema

    package func data(validatedFor schema: IPCJSONSchema) throws -> Data {
        guard self.schema == schema else {
            throw IPCSchemaValidationError(
                fieldPath: "$",
                reason: .invalidDefinition,
                expected: "JSON normalized for the matching schema"
            )
        }
        return data
    }
}

extension IPCJSONSchema {
    package func normalizeJSON(_ data: Data) throws -> IPCNormalizedJSON {
        try validateDefinition()
        let value: IPCSchemaValue
        do {
            value = try JSONDecoder().decode(IPCSchemaValue.self, from: data)
        } catch {
            throw failure(.invalidJSON, path: "$", expected: "valid JSON")
        }
        return IPCNormalizedJSON(data: try normalize(value, path: "$").encoded(), schema: self)
    }
}

indirect enum IPCJSONSchemaPreparedRepresentation: Sendable {
    case object([IPCJSONSchemaPreparedField])
    case dictionary(Self)
    case array(Self)
    case string(NSRegularExpression?)
    case oneOf(IPCJSONSchemaPreparedOneOf)
    case leaf

    var objectFields: [IPCJSONSchemaPreparedField]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    var dictionaryValue: Self? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    var arrayItem: Self? {
        guard case .array(let item) = self else { return nil }
        return item
    }

    var compiledPattern: NSRegularExpression? {
        guard case .string(let pattern) = self else { return nil }
        return pattern
    }

    var oneOf: IPCJSONSchemaPreparedOneOf? {
        guard case .oneOf(let preparedOneOf) = self else { return nil }
        return preparedOneOf
    }
}

struct IPCJSONSchemaPreparedField: Sendable {
    let schema: IPCJSONSchemaPreparedRepresentation
    let defaultValue: IPCSchemaValue?
}

struct IPCJSONSchemaPreparedOneOf: Sendable {
    let alternatives: [IPCJSONSchemaPreparedRepresentation]
    let discriminator: IPCJSONSchemaPreparedDiscriminator?
}

enum IPCJSONSchemaDiscriminatorKey: Hashable, Sendable {
    enum Kind: Equatable, Sendable {
        case encodedScalar
        case canonicalString
    }

    case encodedScalar(Data)
    case canonicalString(String)

    var kind: Kind {
        switch self {
        case .encodedScalar:
            .encodedScalar
        case .canonicalString:
            .canonicalString
        }
    }
}

struct IPCJSONSchemaPreparedDiscriminator: Sendable {
    let fieldName: String
    let keyKind: IPCJSONSchemaDiscriminatorKey.Kind
    let alternativeIndexesByValue: [IPCJSONSchemaDiscriminatorKey: Int]

    func alternativeIndex(for value: IPCSchemaValue) -> Int? {
        guard case .object(let fields) = value,
            let discriminatorValue = fields[fieldName]
        else {
            return nil
        }
        switch keyKind {
        case .encodedScalar:
            guard let encodedValue = discriminatorValue.scalarEncoding else { return nil }
            return alternativeIndexesByValue[.encodedScalar(encodedValue)]
        case .canonicalString:
            guard case .string(let stringValue) = discriminatorValue else { return nil }
            return alternativeIndexesByValue[.canonicalString(stringValue)]
        }
    }
}

extension IPCSchemaValue {
    fileprivate var scalarEncoding: Data? {
        switch self {
        case .null, .boolean, .number, .string:
            try? encoded()
        case .array, .object:
            nil
        }
    }
}

extension IPCJSONSchema {
    fileprivate var scalarDiscriminatorKey: IPCJSONSchemaDiscriminatorKey? {
        switch self {
        case .literalValue(let literal):
            guard let value = try? literal.value(), let encoding = value.scalarEncoding else { return nil }
            return .encodedScalar(encoding)
        case .booleanConstant(let value):
            guard let encoding = IPCSchemaValue.boolean(value).scalarEncoding else { return nil }
            return .encodedScalar(encoding)
        case .string(let constraints):
            guard let allowedValues = constraints.allowedValues, allowedValues.count == 1,
                let onlyValue = allowedValues.first
            else {
                return nil
            }
            return .canonicalString(onlyValue)
        case .object, .dictionary, .array, .integer, .number, .boolean, .null, .oneOf, .schemaDocument:
            return nil
        }
    }
}

/// A validated schema paired with reusable normalization state. Instances are
/// scoped to one catalog decode or method contract; prepared values do not
/// escape into a process-wide cache.
struct IPCValidatedJSONSchema: Sendable {
    let schema: IPCJSONSchema
    let documentValue: IPCSchemaValue
    private let prepared: IPCJSONSchemaPreparedRepresentation

    init(schema: IPCJSONSchema) throws {
        try schema.validateDefinition()
        self.schema = schema
        prepared = try Self.prepare(schema)
        documentValue = try schema.documentValue()
    }

    func normalize(
        _ data: Data,
        schemaDocumentValuesByPath: [String: IPCSchemaValue] = [:]
    ) throws -> Data {
        try normalizeJSON(data, schemaDocumentValuesByPath: schemaDocumentValuesByPath).data
    }

    func normalizeJSON(
        _ data: Data,
        schemaDocumentValuesByPath: [String: IPCSchemaValue] = [:]
    ) throws -> IPCNormalizedJSON {
        let value: IPCSchemaValue
        do {
            value = try JSONDecoder().decode(IPCSchemaValue.self, from: data)
        } catch {
            throw schema.failure(.invalidJSON, path: "$", expected: "valid JSON")
        }
        return IPCNormalizedJSON(
            data: try schema.normalize(
                value,
                path: "$",
                prepared: prepared,
                schemaDocumentValuesByPath: schemaDocumentValuesByPath
            ).encoded(),
            schema: schema
        )
    }

    private static func prepare(_ schema: IPCJSONSchema) throws -> IPCJSONSchemaPreparedRepresentation {
        switch schema {
        case .object(let fields):
            return .object(
                try fields.map { field in
                    let preparedSchema = try prepare(field.schema)
                    let defaultValue: IPCSchemaValue?
                    if case .defaultValue(let data) = field.presence {
                        defaultValue = try JSONDecoder().decode(IPCSchemaValue.self, from: data)
                    } else {
                        defaultValue = nil
                    }
                    return IPCJSONSchemaPreparedField(schema: preparedSchema, defaultValue: defaultValue)
                }
            )
        case .dictionary(let values):
            return .dictionary(try prepare(values))
        case .array(let item, _, _):
            return .array(try prepare(item))
        case .string(let constraints):
            return .string(try constraints.pattern.map { try NSRegularExpression(pattern: $0) })
        case .oneOf(let alternatives):
            return .oneOf(
                IPCJSONSchemaPreparedOneOf(
                    alternatives: try alternatives.map(prepare),
                    discriminator: Self.discriminator(for: alternatives)
                )
            )
        case .integer, .number, .boolean, .booleanConstant, .literalValue, .null, .schemaDocument:
            return .leaf
        }
    }

    private static func discriminator(
        for alternatives: [IPCJSONSchema]
    ) -> IPCJSONSchemaPreparedDiscriminator? {
        guard let firstAlternative = alternatives.first,
            case .object(let firstFields) = firstAlternative
        else {
            return nil
        }
        let alternativeFields = alternatives.compactMap { alternative -> [IPCObjectField]? in
            guard case .object(let fields) = alternative else { return nil }
            return fields
        }
        guard alternativeFields.count == alternatives.count else { return nil }

        for candidate in firstFields where candidate.presence == .required {
            var indexesByValue: [IPCJSONSchemaDiscriminatorKey: Int] = [:]
            var keyKind: IPCJSONSchemaDiscriminatorKey.Kind?
            var isDisjoint = true
            for (index, fields) in alternativeFields.enumerated() {
                guard let field = fields.first(where: { $0.name == candidate.name }),
                    field.presence == .required,
                    let discriminatorKey = field.schema.scalarDiscriminatorKey
                else {
                    isDisjoint = false
                    break
                }
                if let keyKind, keyKind != discriminatorKey.kind {
                    return nil
                }
                keyKind = discriminatorKey.kind
                guard indexesByValue.updateValue(index, forKey: discriminatorKey) == nil else {
                    isDisjoint = false
                    break
                }
            }
            if isDisjoint, let keyKind {
                return IPCJSONSchemaPreparedDiscriminator(
                    fieldName: candidate.name,
                    keyKind: keyKind,
                    alternativeIndexesByValue: indexesByValue
                )
            }
        }
        return nil
    }
}
