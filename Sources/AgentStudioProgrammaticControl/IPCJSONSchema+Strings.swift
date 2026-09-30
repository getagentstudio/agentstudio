import Foundation

package struct IPCStringSchema: Equatable, Sendable {
    package let allowedValues: [String]?
    package let minimumLength: Int
    package let maximumLength: Int?
    package let pattern: String?
    package let maximumUTF16Length: Int?
}

extension IPCJSONSchema {
    package static func string(
        allowedValues: [String]? = nil,
        minimumLength: Int = 0,
        maximumLength: Int? = nil,
        pattern: String? = nil,
        maximumUTF16Length: Int? = nil
    ) -> Self {
        .string(
            IPCStringSchema(
                allowedValues: allowedValues, minimumLength: minimumLength,
                maximumLength: maximumLength, pattern: pattern, maximumUTF16Length: maximumUTF16Length
            )
        )
    }

    func normalizeString(
        _ value: IPCSchemaValue,
        constraints: IPCStringSchema,
        path: String,
        compiledPattern: NSRegularExpression? = nil
    ) throws -> IPCSchemaValue {
        guard case .string(let text) = value else {
            throw failure(.wrongType, path: path, expected: "string")
        }
        let length = text.unicodeScalars.count
        guard length >= constraints.minimumLength, constraints.maximumLength.map({ length <= $0 }) ?? true else {
            throw failure(.outOfBounds, path: path, expected: "the declared string length bounds")
        }
        guard constraints.maximumUTF16Length.map({ text.utf16.count <= $0 }) ?? true else {
            throw failure(.outOfBounds, path: path, expected: "the declared UTF-16 code-unit limit")
        }
        guard constraints.allowedValues.map({ $0.contains(text) }) ?? true else {
            throw failure(.invalidValue, path: path, expected: "a declared enum value")
        }
        if constraints.pattern != nil {
            let matches: Bool
            if let compiledPattern {
                matches =
                    compiledPattern.firstMatch(
                        in: text,
                        range: NSRange(text.startIndex..<text.endIndex, in: text)
                    ) != nil
            } else if let pattern = constraints.pattern {
                matches = try matchesPattern(text, pattern: pattern)
            } else {
                matches = true
            }
            guard matches else {
                throw failure(.invalidValue, path: path, expected: "the declared string pattern")
            }
        }
        return value
    }

    func validateStringDefinition(_ constraints: IPCStringSchema) throws {
        let invalid = failure(.invalidDefinition, path: "$", expected: "a consistent string schema")
        guard constraints.minimumLength >= 0,
            constraints.maximumLength.map({ $0 >= constraints.minimumLength }) ?? true,
            constraints.maximumUTF16Length.map({ $0 >= constraints.minimumLength }) ?? true
        else { throw invalid }
        if let pattern = constraints.pattern {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw invalid }
        }
        if let values = constraints.allowedValues {
            guard !values.isEmpty, Set(values).count == values.count else { throw invalid }
            for value in values {
                do {
                    _ = try normalizeString(.string(value), constraints: constraints, path: "$")
                } catch {
                    throw invalid
                }
            }
        }
    }

    private func matchesPattern(_ text: String, pattern: String) throws -> Bool {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }
}
