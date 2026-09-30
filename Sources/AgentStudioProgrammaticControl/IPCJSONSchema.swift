import Foundation

package struct IPCSchemaValidationError: Error, Codable, Equatable, Sendable {
    package enum Reason: String, Codable, Sendable {
        case invalidJSON
        case invalidDefinition
        case wrongType
        case missingField
        case unknownField
        case outOfBounds
        case invalidValue
        case noMatchingAlternative
        case ambiguousAlternative
        case decodingMismatch
    }

    package let fieldPath: String
    package let reason: Reason
    package let expected: String

    package init(fieldPath: String, reason: Reason, expected: String) {
        self.fieldPath = fieldPath
        self.reason = reason
        self.expected = expected
    }
}

package enum IPCFieldPresence: Equatable, Sendable {
    case required
    case optional
    case defaultValue(Data)

    /// The stored bytes are compared verbatim and travel through a wire round
    /// trip, which returns them re-encoded by `IPCSchemaValue.encoded()`. They
    /// must therefore be written in that same canonical form here; a plain
    /// `JSONEncoder` escapes forward slashes, so a default such as
    /// `https://github.com` came back twenty bytes on one side and twenty-two
    /// on the other and compared unequal.
    package static func defaulted<Value: Encodable>(_ value: Value) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .defaultValue(try encoder.encode(value))
    }
}

package struct IPCObjectField: Equatable, Sendable {
    package let name: String
    package let description: String
    package let schema: IPCJSONSchema
    package let presence: IPCFieldPresence

    package init(
        name: String,
        description: String,
        schema: IPCJSONSchema,
        presence: IPCFieldPresence = .required
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.presence = presence
    }
}

/// One algebra drives input validation, default application and discovery.
/// Unknown object fields are rejected instead of silently changing meaning.
package indirect enum IPCJSONSchema: Equatable, Sendable, Codable {
    case object(fields: [IPCObjectField])
    case dictionary(values: Self)
    case array(items: Self, minimumCount: Int = 0, maximumCount: Int? = nil)
    case string(IPCStringSchema)
    case integer(minimum: Int64? = nil, maximum: Int64? = nil)
    case number(minimum: Double? = nil, maximum: Double? = nil)
    case boolean
    case booleanConstant(Bool)
    case literalValue(IPCJSONLiteral)
    case null
    case oneOf([Self])
    /// A supported catalog schema document. Its discovery form references the
    /// standard meta-schema; validation uses this algebra, never a URL resolver.
    case schemaDocument

    static let metaSchemaURI = "https://json-schema.org/draft/2020-12/schema"

    package func normalize(_ data: Data) throws -> Data {
        try normalizeJSON(data).data
    }

    package func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decode(type, from: normalizeJSON(data))
    }

    package func decode<Value: Decodable>(_ type: Value.Type, from normalized: IPCNormalizedJSON) throws -> Value {
        let normalizedData = try normalized.data(validatedFor: self)
        do {
            return try JSONDecoder().decode(type, from: normalizedData)
        } catch {
            // Decoder diagnostics may contain private values; only catalog-owned
            // correction information crosses the protocol boundary.
            throw failure(.decodingMismatch, path: "$", expected: "the declared parameter type")
        }
    }

    package func jsonSchemaData() throws -> Data {
        try validateDefinition()
        return try documentValue().encoded()
    }

    package func encode(to encoder: any Encoder) throws {
        try validateDefinition()
        try documentValue().encode(to: encoder)
    }

    func failure(
        _ reason: IPCSchemaValidationError.Reason,
        path: String,
        expected: String
    ) -> IPCSchemaValidationError {
        .init(fieldPath: path, reason: reason, expected: expected)
    }

    func normalize(_ value: IPCSchemaValue, path: String) throws -> IPCSchemaValue {
        try normalize(value, path: path, prepared: nil, schemaDocumentValuesByPath: [:])
    }

    func normalize(
        _ value: IPCSchemaValue,
        path: String,
        prepared: IPCJSONSchemaPreparedRepresentation?,
        schemaDocumentValuesByPath: [String: IPCSchemaValue]
    ) throws -> IPCSchemaValue {
        switch self {
        case .object(let fields):
            return try normalizeObject(
                value,
                fields: fields,
                path: path,
                preparedFields: prepared?.objectFields,
                schemaDocumentValuesByPath: schemaDocumentValuesByPath
            )
        case .dictionary(let schema):
            return try normalizeDictionary(
                value,
                schema: schema,
                path: path,
                preparedValueSchema: prepared?.dictionaryValue,
                schemaDocumentValuesByPath: schemaDocumentValuesByPath
            )
        case .array(let itemSchema, let minimumCount, let maximumCount):
            guard case .array(let values) = value else {
                throw failure(.wrongType, path: path, expected: "array")
            }
            guard values.count >= minimumCount, maximumCount.map({ values.count <= $0 }) ?? true else {
                throw failure(.outOfBounds, path: path, expected: "the declared array length bounds")
            }
            return .array(
                try values.enumerated().map { index, item in
                    try itemSchema.normalize(
                        item,
                        path: "\(path)[\(index)]",
                        prepared: prepared?.arrayItem,
                        schemaDocumentValuesByPath: schemaDocumentValuesByPath
                    )
                }
            )
        case .string(let constraints):
            return try normalizeString(
                value,
                constraints: constraints,
                path: path,
                compiledPattern: prepared?.compiledPattern
            )
        case .integer(let minimum, let maximum):
            return try normalizeInteger(value, minimum: minimum, maximum: maximum, path: path)
        case .number(let minimum, let maximum):
            guard case .number(let number) = value else {
                throw failure(.wrongType, path: path, expected: "number")
            }
            guard minimum.map({ number >= Decimal($0) }) ?? true,
                maximum.map({ number <= Decimal($0) }) ?? true
            else {
                throw failure(.outOfBounds, path: path, expected: "the declared number bounds")
            }
            return value
        case .boolean:
            guard case .boolean = value else {
                throw failure(.wrongType, path: path, expected: "boolean")
            }
            return value
        case .booleanConstant(let expected):
            guard case .boolean(let supplied) = value else {
                throw failure(.wrongType, path: path, expected: "boolean")
            }
            guard supplied == expected else {
                throw failure(.invalidValue, path: path, expected: expected ? "true" : "false")
            }
            return value
        case .literalValue(let literal):
            guard try value.encoded() == literal.encodedValue else {
                throw failure(.invalidValue, path: path, expected: "the documented constant value")
            }
            return value
        case .null:
            guard case .null = value else {
                throw failure(.wrongType, path: path, expected: "null")
            }
            return value
        case .oneOf(let alternatives):
            return try normalizeOneOf(
                value,
                alternatives: alternatives,
                path: path,
                preparedOneOf: prepared?.oneOf,
                schemaDocumentValuesByPath: schemaDocumentValuesByPath
            )
        case .schemaDocument:
            if let document = schemaDocumentValuesByPath[path] {
                return document
            }
            do {
                let schema = try JSONDecoder().decode(Self.self, from: value.encoded())
                return try schema.documentValue()
            } catch {
                throw failure(.invalidDefinition, path: path, expected: "a supported typed catalog schema document")
            }
        }
    }

    private func normalizeOneOf(
        _ value: IPCSchemaValue,
        alternatives: [Self],
        path: String,
        preparedOneOf: IPCJSONSchemaPreparedOneOf?,
        schemaDocumentValuesByPath: [String: IPCSchemaValue]
    ) throws -> IPCSchemaValue {
        if let discriminator = preparedOneOf?.discriminator {
            guard let index = discriminator.alternativeIndex(for: value),
                let preparedAlternative = preparedOneOf?.alternatives[index]
            else {
                throw failure(.noMatchingAlternative, path: path, expected: "exactly one declared alternative")
            }
            do {
                return try alternatives[index].normalize(
                    value,
                    path: path,
                    prepared: preparedAlternative,
                    schemaDocumentValuesByPath: schemaDocumentValuesByPath
                )
            } catch {
                // Try-all turns every failed alternative into a no-match at the
                // oneOf path. Keep that observable error while skipping the
                // alternatives the literal discriminator has ruled out.
                throw failure(.noMatchingAlternative, path: path, expected: "exactly one declared alternative")
            }
        }

        let preparedAlternatives = preparedOneOf?.alternatives
        let matches = alternatives.enumerated().compactMap { index, alternative in
            try? alternative.normalize(
                value,
                path: path,
                prepared: preparedAlternatives?[index],
                schemaDocumentValuesByPath: schemaDocumentValuesByPath
            )
        }
        guard matches.count == 1, let match = matches.first else {
            throw failure(
                matches.isEmpty ? .noMatchingAlternative : .ambiguousAlternative,
                path: path,
                expected: "exactly one declared alternative"
            )
        }
        return match
    }

    private func normalizeDictionary(
        _ value: IPCSchemaValue,
        schema: Self,
        path: String,
        preparedValueSchema: IPCJSONSchemaPreparedRepresentation?,
        schemaDocumentValuesByPath: [String: IPCSchemaValue]
    ) throws -> IPCSchemaValue {
        guard case .object(let values) = value else {
            throw failure(.wrongType, path: path, expected: "object with declared value types")
        }
        return .object(
            try values.mapValues {
                try schema.normalize(
                    $0,
                    path: "\(path).*",
                    prepared: preparedValueSchema,
                    schemaDocumentValuesByPath: schemaDocumentValuesByPath
                )
            }
        )
    }

    private func normalizeInteger(
        _ value: IPCSchemaValue, minimum: Int64?, maximum: Int64?, path: String
    ) throws -> IPCSchemaValue {
        guard case .number(let number) = value else {
            throw failure(.wrongType, path: path, expected: "integer")
        }
        var original = number
        var rounded = Decimal()
        NSDecimalRound(&rounded, &original, 0, .plain)
        guard number == rounded else {
            throw failure(.wrongType, path: path, expected: "integer")
        }
        guard minimum.map({ number >= Decimal($0) }) ?? true,
            maximum.map({ number <= Decimal($0) }) ?? true
        else {
            throw failure(.outOfBounds, path: path, expected: "the declared integer bounds")
        }
        return value
    }

    private func normalizeObject(
        _ value: IPCSchemaValue,
        fields: [IPCObjectField],
        path: String,
        preparedFields: [IPCJSONSchemaPreparedField]?,
        schemaDocumentValuesByPath: [String: IPCSchemaValue]
    ) throws -> IPCSchemaValue {
        guard case .object(let values) = value else {
            throw failure(.wrongType, path: path, expected: "object")
        }
        let declaredNames = Set(fields.map(\.name))
        guard Set(values.keys).isSubset(of: declaredNames) else {
            // An unknown key can itself be private input. Do not echo it.
            throw failure(.unknownField, path: path, expected: "only declared fields")
        }
        var normalized: [String: IPCSchemaValue] = [:]
        for (index, field) in fields.enumerated() {
            let preparedField = preparedFields?[index]
            let fieldPath = "\(path).\(field.name)"
            if let suppliedValue = values[field.name] {
                normalized[field.name] = try field.schema.normalize(
                    suppliedValue,
                    path: fieldPath,
                    prepared: preparedField?.schema,
                    schemaDocumentValuesByPath: schemaDocumentValuesByPath
                )
            } else {
                switch field.presence {
                case .required:
                    throw failure(.missingField, path: fieldPath, expected: field.description)
                case .optional:
                    break
                case .defaultValue(let data):
                    let defaultValue: IPCSchemaValue
                    if let cachedDefault = preparedField?.defaultValue {
                        defaultValue = cachedDefault
                    } else {
                        defaultValue = try JSONDecoder().decode(IPCSchemaValue.self, from: data)
                    }
                    normalized[field.name] = try field.schema.normalize(
                        defaultValue,
                        path: fieldPath,
                        prepared: preparedField?.schema,
                        schemaDocumentValuesByPath: schemaDocumentValuesByPath
                    )
                }
            }
        }
        return .object(normalized)
    }

    func validateDefinition() throws {
        let invalid = failure(.invalidDefinition, path: "$", expected: "a complete consistent schema")
        switch self {
        case .object(let fields):
            guard Set(fields.map(\.name)).count == fields.count else { throw invalid }
            for field in fields {
                guard !field.name.isEmpty, !field.description.isEmpty else { throw invalid }
                try field.schema.validateDefinition()
                if case .defaultValue(let data) = field.presence {
                    do {
                        let value = try JSONDecoder().decode(IPCSchemaValue.self, from: data)
                        _ = try field.schema.normalize(value, path: "$.")
                    } catch {
                        throw invalid
                    }
                }
            }
        case .array(let item, let minimum, let maximum):
            guard minimum >= 0, maximum.map({ $0 >= minimum }) ?? true else { throw invalid }
            try item.validateDefinition()
        case .dictionary(let value):
            try value.validateDefinition()
        case .string(let constraints):
            try validateStringDefinition(constraints)
        case .integer(let minimum, let maximum):
            if let minimum, let maximum, minimum > maximum { throw invalid }
        case .number(let minimum, let maximum):
            guard minimum.map(\.isFinite) ?? true, maximum.map(\.isFinite) ?? true else { throw invalid }
            if let minimum, let maximum, minimum > maximum { throw invalid }
        case .oneOf(let alternatives):
            guard alternatives.count > 1 else { throw invalid }
            for alternative in alternatives { try alternative.validateDefinition() }
        case .boolean, .booleanConstant, .literalValue, .null, .schemaDocument:
            break
        }
    }

}
