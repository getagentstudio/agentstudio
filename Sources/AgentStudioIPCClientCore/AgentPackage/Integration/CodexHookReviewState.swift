import Foundation

package struct CodexHookReviewState: Equatable, Sendable {
    package var trustedHash: String?
    package var enabled: Bool?

    package func problems(currentHash: String, event: String, key: String) -> [ProviderIntegrationProblem] {
        var result: [ProviderIntegrationProblem] = []
        if enabled == false { result.append(.codexDisabled(event: event, key: key)) }
        if let trustedHash {
            if trustedHash != currentHash { result.append(.codexModified(event: event, key: key)) }
        } else {
            result.append(.codexNeedsReview(event: event, key: key))
        }
        return result
    }
}

package struct CodexHookReviewDocument: Equatable, Sendable {
    package let hooksEnabled: Bool
    package let states: [String: CodexHookReviewState]
}

/// Read-only projection of Codex's own positional review records. Unsupported
/// trust-state syntax is unknown, never an inferred approval.
package enum CodexHookReviewStateReader {
    package static func key(path: String, event: String, group: Int, handler: Int) -> String {
        "\(path):\(CodexHookTrustHash.eventKey(event)):\(group):\(handler)"
    }

    package static func read(_ text: String) throws -> CodexHookReviewDocument {
        let scanner = try CodexTOMLLineScanner(text)
        var table: [String]? = []
        var tables: Set<[String]> = []
        var fields: Set<[String]> = []
        var enabled = false
        var states: [String: CodexHookReviewState] = [:]
        for line in scanner.lines where line.isStatement {
            let visible = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if visible.hasPrefix("[") {
                guard visible.hasSuffix("]"), !visible.hasPrefix("[[") else {
                    if visible.hasPrefix("[[") {
                        table = nil
                        continue
                    }
                    throw CodexTOMLLineScanner.Failure.ambiguous
                }
                let components = try CodexTOMLLineScanner.keyComponents(String(visible.dropFirst().dropLast()))
                if components == ["features"] || components.starts(with: ["hooks", "state"]) {
                    guard tables.insert(components).inserted else { throw CodexTOMLLineScanner.Failure.ambiguous }
                }
                table = components
                continue
            }
            guard let table, let assignment = try scanner.assignment(in: line) else { continue }
            let key = table + assignment.key
            if key == ["features"] || key == ["hooks"] { throw CodexTOMLLineScanner.Failure.ambiguous }
            guard key == ["features", "hooks"] || key.starts(with: ["hooks", "state"]) else { continue }
            guard fields.insert(key).inserted else { throw CodexTOMLLineScanner.Failure.ambiguous }
            if key == ["features", "hooks"] {
                enabled = try boolean(scanner: scanner, line: line, start: assignment.valueStart)
            } else if key.starts(with: ["hooks", "state"]) {
                if key.count == 3 {
                    states[key[2]] = try inlineState(scanner: scanner, line: line, start: assignment.valueStart)
                } else if key.count == 4 {
                    var state = states[key[2]] ?? .init()
                    try assign(&state, field: key[3], scanner: scanner, line: line, start: assignment.valueStart)
                    states[key[2]] = state
                } else {
                    throw CodexTOMLLineScanner.Failure.ambiguous
                }
            }
        }
        return .init(hooksEnabled: enabled, states: states)
    }

    private static func assign(
        _ state: inout CodexHookReviewState, field: String, scanner: CodexTOMLLineScanner,
        line: CodexTOMLLineScanner.Line, start: Int
    ) throws {
        switch field {
        case "enabled": state.enabled = try boolean(scanner: scanner, line: line, start: start)
        case "trusted_hash":
            let first = scanner.bytes[start..<line.range.upperBound].firstIndex { ![UInt8(32), 9].contains($0) }
            guard let first, let quoted = scanner.quotedValues.first(where: { $0.range.lowerBound == first }),
                let value = quoted.value,
                CodexTOMLLineScanner.text(scanner.mask[quoted.range.upperBound..<line.range.upperBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw CodexTOMLLineScanner.Failure.ambiguous }
            state.trustedHash = value
        default: break
        }
    }

    private static func boolean(scanner: CodexTOMLLineScanner, line: CodexTOMLLineScanner.Line, start: Int) throws
        -> Bool
    {
        let raw = CodexTOMLLineScanner.text(scanner.mask[start..<line.range.upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw {
        case "true": return true
        case "false": return false
        default: throw CodexTOMLLineScanner.Failure.ambiguous
        }
    }

    private static func inlineState(
        scanner: CodexTOMLLineScanner, line: CodexTOMLLineScanner.Line, start: Int
    ) throws -> CodexHookReviewState {
        let offset = start - line.range.lowerBound
        let unmasked = CodexTOMLLineScanner.text(Array(line.text.utf8).dropFirst(offset))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard unmasked.first == "{", unmasked.last == "}" else { throw CodexTOMLLineScanner.Failure.ambiguous }
        let inner = String(unmasked.dropFirst().dropLast())
        let innerScanner = try CodexTOMLLineScanner(inner)
        let commas = innerScanner.mask.indices.filter { innerScanner.mask[$0] == 44 }.map { ($0..<($0 + 1), "\n") }
        let parsed = try CodexTOMLLineScanner(CodexTOMLLineScanner.replacing(inner, edits: commas))
        var state = CodexHookReviewState()
        var fields: Set<String> = []
        for entry in parsed.lines where entry.isStatement {
            guard let assignment = try parsed.assignment(in: entry), assignment.key.count == 1,
                let field = assignment.key.first, fields.insert(field).inserted
            else { throw CodexTOMLLineScanner.Failure.ambiguous }
            try assign(&state, field: field, scanner: parsed, line: entry, start: assignment.valueStart)
        }
        return state
    }
}
