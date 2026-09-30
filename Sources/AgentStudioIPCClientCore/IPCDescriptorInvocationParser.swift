import AgentStudioProgrammaticControl
import Foundation

package enum IPCDescriptorInvocationParser {
    package static func parse(
        _ arguments: [String],
        descriptors: [IPCAnyMethodDescriptor],
        correlationIDGenerator: @Sendable () -> UUID,
        standardInput: Data? = nil
    ) throws -> IPCDescriptorInvocation {
        guard let invocationName = arguments.first else {
            throw failure(
                .unknownMethod,
                fieldPath: "$",
                expected: "a declared method or model invocation"
            )
        }

        if let descriptor = descriptors.first(where: { $0.metadata.name == invocationName }) {
            return try parseToolingInvocation(
                descriptor: descriptor,
                arguments: Array(arguments.dropFirst()),
                correlationIDGenerator: correlationIDGenerator,
                standardInput: standardInput
            )
        }

        return try parseModelInvocation(
            arguments: arguments,
            descriptors: descriptors,
            correlationIDGenerator: correlationIDGenerator
        )
    }

    private static func parseToolingInvocation(
        descriptor: IPCAnyMethodDescriptor,
        arguments: [String],
        correlationIDGenerator: @Sendable () -> UUID,
        standardInput: Data?
    ) throws -> IPCDescriptorInvocation {
        let parameterData: Data
        if arguments.first == "--json" || arguments.first == "--stdin" {
            parameterData = try toolingPayload(arguments: arguments, standardInput: standardInput)
        } else {
            parameterData = try scalarToolingPayload(
                arguments: arguments,
                schema: descriptor.metadata.parameterSchema
            )
        }
        let normalizedParameters = try normalize(
            parameterData,
            descriptor: descriptor,
            correlationIDGenerator: correlationIDGenerator
        )
        return IPCDescriptorInvocation(
            descriptor: descriptor,
            normalizedParameters: normalizedParameters,
            presentation: .tooling
        )
    }

    private static func toolingPayload(
        arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.first == "--json" || arguments.first == "--stdin" else {
            throw failure(
                .conflictingInputMode,
                fieldPath: "$",
                expected: "one tooling input mode"
            )
        }
        switch arguments.first {
        case "--json":
            // `--json` reads as an output flag to almost everyone who types it,
            // so a bare one means "no parameters" rather than a usage error.
            // A method that does need parameters still refuses, naming the
            // field it wanted, because the empty object is normalized against
            // its schema like any other payload.
            if arguments.count == 1 { return Data("{}".utf8) }
            guard arguments.count == 2 else {
                throw failure(
                    .conflictingInputMode,
                    fieldPath: "$",
                    expected: "--json followed by at most one JSON payload"
                )
            }
            return Data(arguments[1].utf8)
        case "--stdin":
            guard arguments.count == 1 else {
                throw failure(
                    .conflictingInputMode,
                    fieldPath: "$",
                    expected: "--stdin without method options"
                )
            }
            guard let standardInput else {
                throw failure(
                    .unavailableStandardInput,
                    fieldPath: "$",
                    expected: "supplied standard input data"
                )
            }
            return standardInput
        default:
            throw failure(
                .conflictingInputMode,
                fieldPath: "$",
                expected: "one tooling input mode"
            )
        }
    }

    private static func scalarToolingPayload(
        arguments: [String],
        schema: IPCJSONSchema
    ) throws -> Data {
        let fields = try rootFields(in: schema)
        var fieldsByOption: [String: IPCObjectField] = [:]
        for field in fields {
            let option = "--\(kebabCase(field.name))"
            if let existingField = fieldsByOption[option], existingField.name != field.name {
                throw failure(
                    .ambiguousInvocation,
                    fieldPath: "$",
                    expected: "unambiguous descriptor field names"
                )
            }
            fieldsByOption[option] = field
        }

        var values: [String: Any] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard let field = fieldsByOption[option] else {
                throw failure(
                    .unknownField,
                    fieldPath: "$",
                    expected: "a declared method option"
                )
            }
            guard values[field.name] == nil else {
                throw failure(
                    .invalidValue,
                    fieldPath: "$.\(field.name)",
                    expected: "one value for the declared field"
                )
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw failure(
                    .missingValue,
                    fieldPath: "$.\(field.name)",
                    expected: "a value for the declared field"
                )
            }
            values[field.name] = try scalarValue(
                arguments[valueIndex],
                field: field
            )
            index += 2
        }
        return try encodedJSONObject(values)
    }

    private static func scalarValue(
        _ rawValue: String,
        field: IPCObjectField
    ) throws -> Any {
        let fieldPath = "$.\(field.name)"
        guard let scalarKind = scalarKind(for: field.schema) else {
            throw failure(
                .unsupportedScalarField,
                fieldPath: fieldPath,
                expected: "JSON or standard input for object and array fields"
            )
        }
        switch scalarKind {
        case .string:
            return rawValue
        case .integer:
            guard let value = Int64(rawValue) else {
                throw failure(.invalidValue, fieldPath: fieldPath, expected: "integer")
            }
            return value
        case .number:
            guard let value = Double(rawValue), value.isFinite else {
                throw failure(.invalidValue, fieldPath: fieldPath, expected: "number")
            }
            return value
        case .boolean:
            switch rawValue {
            case "true": return true
            case "false": return false
            default:
                throw failure(.invalidValue, fieldPath: fieldPath, expected: "boolean")
            }
        }
    }

    private static func parseModelInvocation(
        arguments: [String],
        descriptors: [IPCAnyMethodDescriptor],
        correlationIDGenerator: @Sendable () -> UUID
    ) throws -> IPCDescriptorInvocation {
        let candidates: [ModelCandidate] = descriptors.flatMap { descriptor in
            descriptor.metadata.modelCalls.compactMap { modelCall -> ModelCandidate? in
                let prefix = modelCall.variant.rawValue.split(separator: " ").map(String.init)
                guard arguments.starts(with: prefix) else { return nil }
                return ModelCandidate(
                    descriptor: descriptor,
                    modelCall: modelCall,
                    prefixCount: prefix.count
                )
            }
        }
        guard let longestPrefix = candidates.map(\.prefixCount).max() else {
            throw failure(
                .unknownMethod,
                fieldPath: "$",
                expected: "a declared method or model invocation"
            )
        }
        let longestMatches = candidates.filter { $0.prefixCount == longestPrefix }
        guard longestMatches.count == 1, let candidate = longestMatches.first else {
            throw failure(
                .ambiguousInvocation,
                fieldPath: "$",
                expected: "one descriptor model projection"
            )
        }

        let modelArguments = Array(arguments.dropFirst(candidate.prefixCount))
        let parsedArguments = try parseModelArguments(
            modelArguments,
            projection: candidate.modelCall
        )
        var parameters: [String: Any] = Dictionary(
            uniqueKeysWithValues: candidate.modelCall.selectors.map {
                ($0.parameterField, $0.equals as Any)
            }
        )
        for (field, value) in parsedArguments.values {
            guard parameters[field] == nil else {
                throw failure(
                    .ambiguousInvocation,
                    fieldPath: "$.\(field)",
                    expected: "distinct selector and scalar fields"
                )
            }
            parameters[field] = value
        }

        let normalizedParameters = try normalize(
            encodedJSONObject(parameters),
            descriptor: candidate.descriptor,
            correlationIDGenerator: correlationIDGenerator
        )
        let presentation = IPCModelInvocationPresentation(
            variant: candidate.modelCall.variant,
            successReply: candidate.modelCall.successReply,
            queuedReply: candidate.modelCall.queuedReply,
            isOfflineEligible: candidate.descriptor.metadata.offlineEligibility
                .includes(candidate.modelCall.variant),
            showsDetail: parsedArguments.showsDetail
        )
        return IPCDescriptorInvocation(
            descriptor: candidate.descriptor,
            normalizedParameters: normalizedParameters,
            presentation: .model(presentation)
        )
    }

    private static func parseModelArguments(
        _ arguments: [String],
        projection: IPCModelCallProjection
    ) throws -> ParsedModelArguments {
        var positionalArguments: [String] = []
        var showsDetail = false
        var optionsEnded = false
        for argument in arguments {
            if !optionsEnded, argument == "--" {
                optionsEnded = true
            } else if !optionsEnded, argument == "--detail" {
                guard !showsDetail else {
                    throw failure(
                        .invalidValue,
                        fieldPath: "$",
                        expected: "--detail at most once"
                    )
                }
                showsDetail = true
            } else if !optionsEnded, argument.hasPrefix("--") {
                throw failure(
                    .unknownField,
                    fieldPath: "$",
                    expected: "--detail or -- before flag-shaped text"
                )
            } else {
                positionalArguments.append(argument)
            }
        }

        guard positionalArguments.count <= projection.scalarArguments.count else {
            throw failure(
                .invalidValue,
                fieldPath: "$",
                expected: "the descriptor-declared scalar argument count"
            )
        }
        var values: [(String, Any)] = []
        for (index, scalarArgument) in projection.scalarArguments.enumerated() {
            if index < positionalArguments.count {
                values.append((scalarArgument.parameterField, positionalArguments[index]))
            } else if scalarArgument.isRequired {
                throw failure(
                    .missingValue,
                    fieldPath: "$.\(scalarArgument.parameterField)",
                    expected: scalarArgument.description
                )
            }
        }
        return ParsedModelArguments(values: values, showsDetail: showsDetail)
    }

    private static func normalize(
        _ data: Data,
        descriptor: IPCAnyMethodDescriptor,
        correlationIDGenerator: @Sendable () -> UUID
    ) throws -> IPCValidatedJSON {
        let candidateData: Data
        if descriptor.metadata.correlationPolicy == .required {
            let decodedObject: Any
            do {
                decodedObject = try JSONSerialization.jsonObject(with: data)
            } catch {
                return try normalizeThroughDescriptor(data, descriptor: descriptor)
            }
            guard var object = decodedObject as? [String: Any] else {
                return try normalizeThroughDescriptor(data, descriptor: descriptor)
            }
            if object["correlationId"] == nil {
                object["correlationId"] = correlationIDGenerator().uuidString
                candidateData = try encodedJSONObject(object)
            } else {
                candidateData = data
            }
        } else {
            candidateData = data
        }
        return try normalizeThroughDescriptor(candidateData, descriptor: descriptor)
    }

    private static func normalizeThroughDescriptor(
        _ data: Data,
        descriptor: IPCAnyMethodDescriptor
    ) throws -> IPCValidatedJSON {
        do {
            return try descriptor.normalizeParameters(data)
        } catch let validationError as IPCSchemaValidationError {
            throw failure(
                invocationReason(for: validationError.reason),
                fieldPath: validationError.fieldPath,
                expected: validationError.expected
            )
        } catch {
            throw failure(
                .invalidValue,
                fieldPath: "$",
                expected: "the declared parameter type"
            )
        }
    }

    private static func rootFields(in schema: IPCJSONSchema) throws -> [IPCObjectField] {
        switch schema {
        case .object(let fields):
            return fields
        case .oneOf(let alternatives):
            return try alternatives.flatMap { try rootFields(in: $0) }
        case .dictionary, .array, .string, .integer, .number, .boolean, .booleanConstant,
            .literalValue, .null, .schemaDocument:
            throw failure(
                .unsupportedScalarField,
                fieldPath: "$",
                expected: "JSON or standard input for a non-object parameter schema"
            )
        }
    }

    private static func scalarKind(for schema: IPCJSONSchema) -> ScalarKind? {
        switch schema {
        case .string: return .string
        case .integer: return .integer
        case .number: return .number
        case .boolean: return .boolean
        case .oneOf(let alternatives):
            let kinds = Set(
                alternatives.compactMap { alternative -> ScalarKind? in
                    if case .null = alternative { return nil }
                    return scalarKind(for: alternative)
                })
            return kinds.count == 1 ? kinds.first : nil
        case .object, .dictionary, .array, .booleanConstant, .literalValue, .null,
            .schemaDocument:
            return nil
        }
    }

    private static func encodedJSONObject(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw failure(
                .invalidValue,
                fieldPath: "$",
                expected: "a JSON object containing declared fields"
            )
        }
    }

    private static func kebabCase(_ camelCase: String) -> String {
        camelCase.reduce(into: "") { result, character in
            if character.isUppercase {
                if !result.isEmpty { result.append("-") }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
    }

    private static func invocationReason(
        for reason: IPCSchemaValidationError.Reason
    ) -> IPCDescriptorInvocationError.Reason {
        switch reason {
        case .unknownField: .unknownField
        case .missingField: .missingValue
        case .invalidJSON, .invalidDefinition, .wrongType, .outOfBounds, .invalidValue,
            .noMatchingAlternative, .ambiguousAlternative, .decodingMismatch:
            .invalidValue
        }
    }

    private static func failure(
        _ reason: IPCDescriptorInvocationError.Reason,
        fieldPath: String,
        expected: String
    ) -> IPCDescriptorInvocationError {
        IPCDescriptorInvocationError(
            reason: reason,
            fieldPath: fieldPath,
            expected: expected
        )
    }
}

private struct ModelCandidate {
    let descriptor: IPCAnyMethodDescriptor
    let modelCall: IPCModelCallProjection
    let prefixCount: Int
}

private struct ParsedModelArguments {
    let values: [(String, Any)]
    let showsDetail: Bool
}

private enum ScalarKind: Hashable {
    case string
    case integer
    case number
    case boolean
}

extension IPCMethodOfflineEligibility {
    fileprivate func includes(_ variant: IPCModelCallVariant) -> Bool {
        guard case .modelCallVariants(let variants) = self else { return false }
        return variants.contains(variant)
    }
}
