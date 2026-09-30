import Foundation

extension IPCJSONSchema {
    func validateTypedEncoding(normalized: Data, encoded: Data) throws {
        _ = try validateTypedEncodingAndCompare(normalized: normalized, encoded: encoded)
    }

    func validateTypedEncodingAndCompare(
        normalized: IPCNormalizedJSON,
        encoded: Data
    ) throws -> Bool {
        try validateTypedEncodingAndCompare(
            normalized: normalized.data(validatedFor: self),
            encoded: encoded
        )
    }

    private func validateTypedEncodingAndCompare(
        normalized: Data,
        encoded: Data
    ) throws -> Bool {
        let input = try JSONDecoder().decode(IPCSchemaValue.self, from: normalized)
        let output = try JSONDecoder().decode(IPCSchemaValue.self, from: encoded)
        try validateTypedEncoding(input: input, output: output, path: "$")
        return input == output
    }

    private func validateTypedEncoding(
        input: IPCSchemaValue,
        output: IPCSchemaValue,
        path: String
    ) throws {
        switch self {
        case .object(let fields):
            guard case .object(let inputFields) = input, case .object(let outputFields) = output else {
                throw encodingMismatch(path)
            }
            guard Set(outputFields.keys).isSubset(of: Set(fields.map(\.name))) else {
                throw encodingMismatch(path)
            }
            for field in fields {
                guard let inputValue = inputFields[field.name] else { continue }
                guard let outputValue = outputFields[field.name] else {
                    // Synthesized optional Codable properties omit nil on encode.
                    if inputValue == .null { continue }
                    throw encodingMismatch("\(path).\(field.name)")
                }
                try field.schema.validateTypedEncoding(
                    input: inputValue, output: outputValue, path: "\(path).\(field.name)"
                )
            }
        case .dictionary(let schema):
            guard case .object(let inputValues) = input, case .object(let outputValues) = output,
                Set(inputValues.keys) == Set(outputValues.keys)
            else { throw encodingMismatch(path) }
            for (key, value) in inputValues {
                guard let outputValue = outputValues[key] else { throw encodingMismatch(path) }
                try schema.validateTypedEncoding(input: value, output: outputValue, path: "\(path).*")
            }
        case .array(let schema, _, _):
            guard case .array(let inputValues) = input, case .array(let outputValues) = output,
                inputValues.count == outputValues.count
            else { throw encodingMismatch(path) }
            for (index, values) in zip(inputValues, outputValues).enumerated() {
                try schema.validateTypedEncoding(input: values.0, output: values.1, path: "\(path)[\(index)]")
            }
        case .oneOf(let alternatives):
            guard let matching = alternatives.first(where: { (try? $0.normalize(input, path: path)) != nil }) else {
                throw encodingMismatch(path)
            }
            try matching.validateTypedEncoding(input: input, output: output, path: path)
        case .schemaDocument:
            let inputSchema = try JSONDecoder().decode(IPCJSONSchema.self, from: input.encoded())
            let outputSchema = try JSONDecoder().decode(IPCJSONSchema.self, from: output.encoded())
            guard inputSchema == outputSchema else { throw encodingMismatch(path) }
        case .string, .integer, .number, .boolean, .booleanConstant, .literalValue, .null:
            // Codable may canonicalize values such as UUID spelling. Schema
            // validation still enforces type/bounds; field presence is the invariant.
            _ = try normalize(output, path: path)
        }
    }

    private func encodingMismatch(_ path: String) -> IPCSchemaValidationError {
        .init(fieldPath: path, reason: .decodingMismatch, expected: "a field represented by the typed contract")
    }
}
