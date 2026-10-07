import AgentStudioProgrammaticControl
import Foundation

/// App interprets raw scalar strings against the selected command's own spec.
package enum AppCommandRawArgumentParser {
    package static func parse(
        arguments: [String: String], allowedVariants: [IPCCommandArgumentVariant]
    ) throws(IPCSchemaValidationError) -> IPCCommandArguments {
        let variants = Array(Set(allowedVariants)).sorted { $0.rawValue < $1.rawValue }
        let admitted: [IPCCommandArgumentVariant]
        if let kind = arguments["kind"] {
            guard let variant = IPCCommandArgumentVariant(rawValue: kind), variants.contains(variant) else {
                throw kindCorrection(variants)
            }
            admitted = [variant]
        } else {
            admitted = variants
        }
        guard !admitted.isEmpty else { throw kindCorrection(variants) }
        var matches: [IPCCommandArguments] = []
        var corrections: [IPCSchemaValidationError] = []
        for variant in admitted {
            do {
                let schema = try variant.schema
                if case .object(let schemaFields) = schema {
                    let declaredFieldNames = Set(schemaFields.map(\.name))
                    let unknownFieldNames = arguments.keys.filter { !declaredFieldNames.contains($0) }.sorted()
                    if let unknownFieldName = unknownFieldNames.first {
                        throw IPCSchemaValidationError(
                            fieldPath: "$.\(unknownFieldName)", reason: .unknownField,
                            expected: "only declared fields")
                    }
                }
                var fields = arguments
                fields["kind"] = variant.rawValue
                let encoded = try JSONEncoder().encode(fields)
                matches.append(try schema.decode(IPCCommandArguments.self, from: encoded))
            } catch let correction as IPCSchemaValidationError {
                let path =
                    correction.fieldPath == "$"
                    ? "$.arguments" : "$.arguments" + String(correction.fieldPath.dropFirst())
                corrections.append(.init(fieldPath: path, reason: correction.reason, expected: correction.expected))
            } catch {
                corrections.append(
                    .init(
                        fieldPath: "$.arguments", reason: .invalidValue,
                        expected: "raw scalar arguments matching the selected command"))
            }
        }
        if matches.count == 1, let match = matches.first { return match }
        if admitted.count == 1, let correction = corrections.first { throw correction }
        throw kindCorrection(variants)
    }

    private static func kindCorrection(_ variants: [IPCCommandArgumentVariant]) -> IPCSchemaValidationError {
        .init(
            fieldPath: "$.arguments.kind", reason: .invalidValue,
            expected: "one admitted argument kind: " + variants.map(\.rawValue).joined(separator: ", "))
    }
}
