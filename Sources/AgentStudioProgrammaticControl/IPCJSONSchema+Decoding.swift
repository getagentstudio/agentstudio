import Foundation

extension IPCJSONSchema {
    package init(from decoder: any Decoder) throws {
        let schemaContext =
            decoder.userInfo[IPCMethodCatalogSchemaContext.userInfoKey]
            as? IPCMethodCatalogSchemaContext
        if let cachedSchema = schemaContext?.cachedSchema(for: decoder.codingPath) {
            self = cachedSchema
            return
        }
        let document = try IPCSchemaValue(from: decoder)
        let decodedSchema = try Self.decodeDocument(document)
        self = decodedSchema
        if let schemaContext {
            let validatedSchema = try IPCValidatedJSONSchema(schema: decodedSchema)
            schemaContext.capture(validatedSchema, codingPath: decoder.codingPath)
        } else {
            // Reuse constructor validation, including defaults and contradictory bounds.
            _ = try jsonSchemaData()
        }
    }

    private static func decodeDocument(_ value: IPCSchemaValue) throws -> Self {
        guard case .object(let document) = value else { throw invalidDocument() }
        if let constant = document["const"], document["type"] == nil {
            try validateKeywords(document, supported: ["const"])
            return .literalValue(try IPCJSONLiteral(value: constant))
        }
        if let reference = document["$ref"] {
            try validateKeywords(document, supported: ["$ref"])
            guard reference == .string(metaSchemaURI) else { throw invalidDocument() }
            return .schemaDocument
        }
        if case .array(let alternatives)? = document["oneOf"] {
            try validateKeywords(document, supported: ["oneOf"])
            return .oneOf(try alternatives.map(decodeDocument))
        }
        guard case .string(let type)? = document["type"] else { throw invalidDocument() }
        switch type {
        case "object":
            try validateKeywords(document, supported: ["type", "properties", "required", "additionalProperties"])
            return try decodeObject(document)
        case "array":
            try validateKeywords(document, supported: ["type", "items", "minItems", "maxItems"])
            guard let items = document["items"] else { throw invalidDocument() }
            return try .array(
                items: decodeDocument(items),
                minimumCount: countBound(document["minItems"]) ?? 0,
                maximumCount: countBound(document["maxItems"])
            )
        case "string":
            try validateKeywords(
                document, supported: ["type", "enum", "minLength", "maxLength", "pattern", "x-maxUTF16Length"]
            )
            let allowedValues: [String]?
            if let enumeration = document["enum"] {
                guard case .array(let values) = enumeration else { throw invalidDocument() }
                allowedValues = try values.map { value in
                    guard case .string(let text) = value else { throw invalidDocument() }
                    return text
                }
            } else {
                allowedValues = nil
            }
            return try .string(
                allowedValues: allowedValues,
                minimumLength: countBound(document["minLength"]) ?? 0,
                maximumLength: countBound(document["maxLength"]),
                pattern: stringProperty(document["pattern"]),
                maximumUTF16Length: countBound(document["x-maxUTF16Length"])
            )
        case "integer":
            try validateKeywords(document, supported: ["type", "minimum", "maximum"])
            return try .integer(
                minimum: integerBound(document["minimum"]), maximum: integerBound(document["maximum"])
            )
        case "number":
            try validateKeywords(document, supported: ["type", "minimum", "maximum"])
            return try .number(
                minimum: numberBound(document["minimum"]), maximum: numberBound(document["maximum"])
            )
        case "boolean":
            try validateKeywords(document, supported: ["type", "const"])
            if let constant = document["const"] {
                guard case .boolean(let value) = constant else { throw invalidDocument() }
                return .booleanConstant(value)
            }
            return .boolean
        case "null":
            try validateKeywords(document, supported: ["type"])
            return .null
        default: throw invalidDocument()
        }
    }

    private static func validateKeywords(_ document: [String: IPCSchemaValue], supported: Set<String>) throws {
        // This decoder reads our typed catalog dialect, not arbitrary schemas.
        // Refuse unsupported semantics instead of silently weakening admission.
        let annotations: Set<String> = ["description", "default", "$schema"]
        guard Set(document.keys).isSubset(of: supported.union(annotations)) else { throw invalidDocument() }
        if let dialect = document["$schema"], dialect != .string(metaSchemaURI) { throw invalidDocument() }
        if let description = document["description"], case .string = description {
            return
        } else if document["description"] != nil {
            throw invalidDocument()
        }
    }

    private static func decodeObject(_ document: [String: IPCSchemaValue]) throws -> Self {
        if let additional = document["additionalProperties"], case .object = additional {
            guard document["properties"] == nil else { throw invalidDocument() }
            return .dictionary(values: try decodeDocument(additional))
        }
        guard document["additionalProperties"] == .boolean(false),
            case .object(let properties)? = document["properties"],
            case .array(let requiredValues)? = document["required"]
        else { throw invalidDocument() }
        let requiredNames = try requiredValues.map { value in
            guard case .string(let name) = value else { throw invalidDocument() }
            return name
        }
        guard Set(requiredNames).count == requiredNames.count,
            Set(requiredNames).isSubset(of: Set(properties.keys))
        else { throw invalidDocument() }

        let fields = try properties.keys.sorted().map { name -> IPCObjectField in
            guard let property = properties[name], case .object(let fieldDocument) = property,
                case .string(let description)? = fieldDocument["description"]
            else { throw invalidDocument() }
            let presence: IPCFieldPresence
            if requiredNames.contains(name) {
                guard fieldDocument["default"] == nil else { throw invalidDocument() }
                presence = .required
            } else if let defaultValue = fieldDocument["default"] {
                presence = .defaultValue(try defaultValue.encoded())
            } else {
                presence = .optional
            }
            return IPCObjectField(
                name: name, description: description, schema: try decodeDocument(property), presence: presence
            )
        }
        return .object(fields: fields)
    }

    private static func countBound(_ value: IPCSchemaValue?) throws -> Int? {
        guard let bound = try integerBound(value) else { return nil }
        guard let count = Int(exactly: bound) else { throw invalidDocument() }
        return count
    }

    private static func stringProperty(_ value: IPCSchemaValue?) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { throw invalidDocument() }
        return string
    }

    private static func integerBound(_ value: IPCSchemaValue?) throws -> Int64? {
        guard let value else { return nil }
        guard case .number(let number) = value else { throw invalidDocument() }
        let integer = NSDecimalNumber(decimal: number).int64Value
        guard Decimal(integer) == number else { throw invalidDocument() }
        return integer
    }

    private static func numberBound(_ value: IPCSchemaValue?) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let number) = value else { throw invalidDocument() }
        let double = NSDecimalNumber(decimal: number).doubleValue
        guard double.isFinite else { throw invalidDocument() }
        return double
    }

    private static func invalidDocument() -> IPCSchemaValidationError {
        .init(fieldPath: "$", reason: .invalidDefinition, expected: "a supported typed schema document")
    }
}
