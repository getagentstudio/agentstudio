import Foundation

/// Method-contract JSON that passed schema normalization and typed-encoding
/// equality. It can cross an internal boundary without repeating either walk.
package struct IPCValidatedJSON: Equatable, Sendable {
    package let normalizedJSON: IPCNormalizedJSON
    package var data: Data { normalizedJSON.data }

    fileprivate init(normalizedJSON: IPCNormalizedJSON) {
        self.normalizedJSON = normalizedJSON
    }

    package func data(validatedFor schema: IPCJSONSchema) throws -> Data {
        try normalizedJSON.data(validatedFor: schema)
    }
}

package struct IPCValidatedTypedValue<Value: Sendable>: Sendable {
    package let value: Value
    package let json: IPCValidatedJSON
}

/// The method registry attaches its handler to this typed request/result pair.
/// Validation and discovery consume the same schemas; Codable cannot silently
/// discard a schema-declared non-null field before the handler sees it.
package struct IPCMethodContract<Parameters: Codable & Sendable, Result: Codable & Sendable>: Sendable {
    package let parameterSchema: IPCJSONSchema
    package let resultSchema: IPCJSONSchema
    private let validatedParameterSchema: IPCValidatedJSONSchema
    private let validatedResultSchema: IPCValidatedJSONSchema

    package init(parameterSchema: IPCJSONSchema, resultSchema: IPCJSONSchema) throws {
        let validatedParameterSchema = try IPCValidatedJSONSchema(schema: parameterSchema)
        let validatedResultSchema = try IPCValidatedJSONSchema(schema: resultSchema)
        self.parameterSchema = parameterSchema
        self.resultSchema = resultSchema
        self.validatedParameterSchema = validatedParameterSchema
        self.validatedResultSchema = validatedResultSchema
    }

    package func decodeParameters(from data: Data) throws -> Parameters {
        try decodeParameters(from: validatedParameterSchema.normalizeJSON(data))
    }

    package func decodeParameters(from normalized: IPCNormalizedJSON) throws -> Parameters {
        let parameters = try parameterSchema.decode(Parameters.self, from: normalized)
        _ = try parameterSchema.validateTypedEncodingAndCompare(
            normalized: normalized,
            encoded: encodedValue(parameters)
        )
        return parameters
    }

    package func decodeParameters(from validated: IPCValidatedJSON) throws -> Parameters {
        try parameterSchema.decode(Parameters.self, from: validated.normalizedJSON)
    }

    package func validatedParameters(from data: Data) throws -> IPCValidatedTypedValue<Parameters> {
        try validatedParameters(from: validatedParameterSchema.normalizeJSON(data))
    }

    package func normalizedParameters(from data: Data) throws -> IPCValidatedJSON {
        try validatedParameters(from: data).json
    }

    package func validatedParameters(
        from normalized: IPCNormalizedJSON
    ) throws -> IPCValidatedTypedValue<Parameters> {
        let parameters = try parameterSchema.decode(Parameters.self, from: normalized)
        let encoded = try encodedValue(parameters)
        let sameRepresentation = try parameterSchema.validateTypedEncodingAndCompare(
            normalized: normalized,
            encoded: encoded
        )
        let wireJSON = try normalizedTypedEncoding(
            encoded,
            matching: normalized,
            sameRepresentation: sameRepresentation,
            validatedSchema: validatedParameterSchema
        )
        return IPCValidatedTypedValue(
            value: parameters,
            json: IPCValidatedJSON(normalizedJSON: wireJSON)
        )
    }

    package func decodeResult(from data: Data) throws -> Result {
        try decodeResult(from: validatedResultSchema.normalizeJSON(data))
    }

    package func decodeResult(from normalized: IPCNormalizedJSON) throws -> Result {
        let result = try resultSchema.decode(Result.self, from: normalized)
        _ = try resultSchema.validateTypedEncodingAndCompare(
            normalized: normalized,
            encoded: encodedValue(result)
        )
        return result
    }

    package func decodeResult(from validated: IPCValidatedJSON) throws -> Result {
        try resultSchema.decode(Result.self, from: validated.normalizedJSON)
    }

    package func validatedResult(from data: Data) throws -> IPCValidatedTypedValue<Result> {
        try validatedResult(from: validatedResultSchema.normalizeJSON(data))
    }

    package func normalizedResult(from data: Data) throws -> IPCValidatedJSON {
        try validatedResult(from: data).json
    }

    package func validatedResult(
        from normalized: IPCNormalizedJSON
    ) throws -> IPCValidatedTypedValue<Result> {
        let result = try resultSchema.decode(Result.self, from: normalized)
        let encoded = try encodedValue(result)
        let sameRepresentation = try resultSchema.validateTypedEncodingAndCompare(
            normalized: normalized,
            encoded: encoded
        )
        let wireJSON = try normalizedTypedEncoding(
            encoded,
            matching: normalized,
            sameRepresentation: sameRepresentation,
            validatedSchema: validatedResultSchema
        )
        return IPCValidatedTypedValue(
            value: result,
            json: IPCValidatedJSON(normalizedJSON: wireJSON)
        )
    }

    package func encodeResult(_ result: Result) throws -> Data {
        let encoded = try encodedValue(result)
        let normalized = try validatedResultSchema.normalizeJSON(encoded)
        _ = try resultSchema.validateTypedEncodingAndCompare(normalized: normalized, encoded: encoded)
        return normalized.data
    }

    package func validateExample(parameters: Parameters, result: Result) throws {
        _ = try decodeParameters(from: encodedValue(parameters))
        _ = try encodeResult(result)
    }

    private func encodedValue<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw IPCSchemaValidationError(
                fieldPath: "$", reason: .decodingMismatch, expected: "an encodable typed contract value"
            )
        }
    }

    private func normalizedTypedEncoding(
        _ encoded: Data,
        matching normalized: IPCNormalizedJSON,
        sameRepresentation: Bool,
        validatedSchema: IPCValidatedJSONSchema
    ) throws -> IPCNormalizedJSON {
        // The normal case returns the already-normalized message. If Codable
        // canonicalized a value, normalize that changed representation to keep
        // the previous wire output and exactly-one checks.
        guard !sameRepresentation else { return normalized }
        let typedJSON = try validatedSchema.normalizeJSON(encoded)
        _ = try validatedSchema.schema.validateTypedEncodingAndCompare(normalized: typedJSON, encoded: encoded)
        return typedJSON
    }
}
