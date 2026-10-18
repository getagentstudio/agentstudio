import Foundation

/// Edits only the selected store-directory element of Codex's writable roots.
package enum CodexWritableRootsEditor {
    package static func updating(
        _ contents: String, directory: String, removing: Bool = false, configurationPath: String
    ) throws -> (contents: String, changed: Bool) {
        do { return try edit(contents, directory: directory, removing: removing) } catch {
            throw AgentPackageInstallationError.writableRootsNotLocatable(configurationPath)
        }
    }

    private static func edit(
        _ contents: String, directory: String, removing: Bool
    ) throws -> (contents: String, changed: Bool) {
        let scanner = try CodexTOMLLineScanner(contents)
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = CodexTOMLLineScanner.text(try encoder.encode(directory))
        let assignmentText = "writable_roots = [\(quoted)]\(newline)"
        guard let table = try scanner.table(named: "sandbox_workspace_write") else {
            if removing { return (contents, false) }
            let separator = contents.isEmpty ? "" : (contents.hasSuffix("\n") ? newline : newline + newline)
            return (contents + separator + "[sandbox_workspace_write]\(newline)" + assignmentText, true)
        }
        let assignments = try table.body.compactMap { line -> (CodexTOMLLineScanner.Line, Int)? in
            guard let assignment = try scanner.assignment(in: line), assignment.key.first == "writable_roots" else {
                return nil
            }
            guard assignment.key == ["writable_roots"] else { throw CodexTOMLLineScanner.Failure.ambiguous }
            return (line, assignment.valueStart)
        }
        guard assignments.count <= 1 else { throw CodexTOMLLineScanner.Failure.ambiguous }
        guard let (line, valueStart) = assignments.first else {
            if removing { return (contents, false) }
            let position = table.header.range.upperBound
            let prefix = position > 0 && scanner.bytes[position - 1] != 10 ? newline : ""
            return (
                CodexTOMLLineScanner.replacing(
                    contents, edits: [(position..<position, prefix + assignmentText)]), true
            )
        }
        let value = CodexTOMLLineScanner.text(scanner.bytes[valueStart..<line.range.upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("["),
            let opening = scanner.mask[valueStart..<line.range.upperBound].firstIndex(of: 91),
            let closing = scanner.mask[(opening + 1)...].firstIndex(of: 93),
            !scanner.mask[(opening + 1)..<closing].contains(91)
        else { throw CodexTOMLLineScanner.Failure.ambiguous }
        let elements = scanner.quotedValues.filter { $0.range.lowerBound > opening && $0.range.upperBound <= closing }
        guard elements.allSatisfy({ $0.value != nil }),
            scanner.mask[(opening + 1)..<closing].allSatisfy({ [9, 10, 13, 32, 44].contains($0) })
        else { throw CodexTOMLLineScanner.Failure.ambiguous }
        try validateSeparators(scanner: scanner, elements: elements, opening: opening, closing: closing)
        let matching = elements.filter { $0.value == directory }
        if removing {
            guard !matching.isEmpty else { return (contents, false) }
            return (
                try removingElements(matching, from: contents, scanner: scanner, opening: opening, closing: closing),
                true
            )
        }
        guard matching.isEmpty else { return (contents, false) }
        return (
            addingElement(
                quoted, to: contents, scanner: scanner, elements: elements, bounds: opening..<closing,
                newline: newline), true
        )
    }

    private static func removingElements(
        _ elements: [CodexTOMLLineScanner.QuotedValue], from contents: String,
        scanner: CodexTOMLLineScanner, opening: Int, closing: Int
    ) throws -> String {
        // Re-scan after each removal so adjacent matching elements never claim the same comma.
        guard let element = elements.last else { return contents }
        var edits: [(Range<Int>, String)] = [(element.range, "")]
        let next = scanner.mask[element.range.upperBound..<closing].firstIndex { ![9, 10, 13, 32].contains($0) }
        if let next, scanner.mask[next] == 44 {
            edits.append((next..<(next + 1), ""))
        } else if let previous = scanner.mask[(opening + 1)..<element.range.lowerBound].lastIndex(of: 44) {
            edits.append((previous..<(previous + 1), ""))
        }
        let updated = CodexTOMLLineScanner.replacing(contents, edits: edits)
        guard elements.count > 1, let directory = element.value else { return updated }
        return try edit(updated, directory: directory, removing: true).contents
    }

    private static func validateSeparators(
        scanner: CodexTOMLLineScanner, elements: [CodexTOMLLineScanner.QuotedValue], opening: Int, closing: Int
    ) throws {
        var previous = opening + 1
        for (index, element) in elements.enumerated() {
            let separators = scanner.mask[previous..<element.range.lowerBound].filter { ![9, 10, 13, 32].contains($0) }
            guard separators == (index == 0 ? [] : [44]) else { throw CodexTOMLLineScanner.Failure.ambiguous }
            previous = element.range.upperBound
        }
        let tail = scanner.mask[previous..<closing].filter { ![9, 10, 13, 32].contains($0) }
        guard tail.isEmpty || (!elements.isEmpty && tail == [44]) else {
            throw CodexTOMLLineScanner.Failure.ambiguous
        }
        let lineEnd = scanner.mask[closing...].firstIndex(of: 10) ?? scanner.mask.count
        guard scanner.mask[(closing + 1)..<lineEnd].allSatisfy({ [9, 13, 32].contains($0) }) else {
            throw CodexTOMLLineScanner.Failure.ambiguous
        }
    }

    private static func addingElement(
        _ quoted: String, to contents: String, scanner: CodexTOMLLineScanner,
        elements: [CodexTOMLLineScanner.QuotedValue], bounds: Range<Int>, newline: String
    ) -> String {
        let opening = bounds.lowerBound
        let closing = bounds.upperBound
        let multiline = scanner.bytes[opening..<closing].contains(10)
        let trailingComma = elements.last.map { scanner.mask[$0.range.upperBound..<closing].contains(44) } ?? false
        if !multiline {
            let prefix = elements.isEmpty ? "" : (trailingComma ? " " : ", ")
            let suffix = trailingComma ? "," : ""
            return CodexTOMLLineScanner.replacing(contents, edits: [(closing..<closing, prefix + quoted + suffix)])
        }
        let closingLineStart = (scanner.bytes[..<closing].lastIndex(of: 10).map { $0 + 1 }) ?? 0
        let closingPrefix = scanner.bytes[closingLineStart..<closing]
        let closingAlone = closingPrefix.allSatisfy { $0 == 32 || $0 == 9 }
        let closingIndent = closingAlone ? CodexTOMLLineScanner.text(closingPrefix) : ""
        let elementIndent: String
        if let first = elements.first {
            let start = scanner.bytes[..<first.range.lowerBound].lastIndex(of: 10).map { $0 + 1 } ?? 0
            elementIndent = CodexTOMLLineScanner.text(
                scanner.bytes[start..<first.range.lowerBound].prefix { $0 == 32 || $0 == 9 })
        } else {
            elementIndent = closingIndent + "    "
        }
        var edits: [(Range<Int>, String)] = []
        if closingAlone {
            if let last = elements.last, !trailingComma {
                edits.append((last.range.upperBound..<last.range.upperBound, ","))
            }
            edits.append((closingLineStart..<closingLineStart, elementIndent + quoted + "," + newline))
        } else {
            let separator = !elements.isEmpty && !trailingComma ? "," : ""
            edits.append(
                (closing..<closing, separator + newline + elementIndent + quoted + "," + newline + closingIndent))
        }
        return CodexTOMLLineScanner.replacing(contents, edits: edits)
    }
}
