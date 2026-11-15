import Foundation

/// Locates structural TOML lines without mistaking string contents for keys or tables.
struct CodexTOMLLineScanner {
    enum Failure: Error { case ambiguous }
    struct Line {
        let range: Range<Int>
        let text: String
        let isStatement: Bool
    }
    struct QuotedValue {
        let range: Range<Int>
        let value: String?
    }
    struct Table {
        let header: Line
        let body: [Line]
    }
    let bytes: [UInt8]
    let mask: [UInt8]
    let lines: [Line]
    let quotedValues: [QuotedValue]

    init(_ contents: String) throws {
        let source = Array(contents.utf8)
        var code = source
        var visible = source
        var quoted: [QuotedValue] = []
        var statements: [Bool] = [true]
        var state = StringState.unquoted
        var stringStart = 0
        var depth = 0
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == 10 {
                if state == .comment { state = .unquoted }
                guard state != .basic && state != .literal else { throw Failure.ambiguous }
                statements.append(state == .unquoted && depth == 0)
                index += 1
                continue
            }
            switch state {
            case .comment:
                code[index] = 32
                visible[index] = 32
            case .basic, .literal:
                code[index] = 32
                if byte == 92 && state == .basic {
                    guard index + 1 < source.count else { throw Failure.ambiguous }
                    code[index + 1] = 32
                    index += 2
                    continue
                }
                if byte == (state == .basic ? 34 : 39) {
                    let range = stringStart..<(index + 1)
                    quoted.append(
                        .init(
                            range: range, value: try Self.decodeQuoted(Self.text(source[range]))))
                    state = .unquoted
                }
            case .multilineBasic, .multilineLiteral:
                code[index] = 32
                visible[index] = 32
                if byte == 92 && state == .multilineBasic, index + 1 < source.count {
                    code[index + 1] = 32
                    visible[index + 1] = 32
                    if source[index + 1] != 10 {
                        index += 2
                        continue
                    }
                }
                let delimiter: UInt8 = state == .multilineBasic ? 34 : 39
                let count = byte == delimiter ? Self.quoteCount(source, at: index, delimiter: delimiter) : 0
                if count >= 3 {
                    for offset in index..<(index + count) {
                        code[offset] = 32
                        visible[offset] = 32
                    }
                    quoted.append(.init(range: stringStart..<(index + count), value: nil))
                    state = .unquoted
                    index += count
                    continue
                }
            case .unquoted:
                if byte == 35 {
                    state = .comment
                    code[index] = 32
                    visible[index] = 32
                } else if byte == 34 || byte == 39 {
                    stringStart = index
                    let count = Self.quoteCount(source, at: index, delimiter: byte)
                    if count >= 3 {
                        state = byte == 34 ? .multilineBasic : .multilineLiteral
                        for offset in index..<(index + 3) {
                            code[offset] = 32
                            visible[offset] = 32
                        }
                        index += 3
                        continue
                    }
                    state = byte == 34 ? .basic : .literal
                    code[index] = 32
                } else if byte == 91 {
                    depth += 1
                } else if byte == 93 {
                    depth -= 1
                    guard depth >= 0 else { throw Failure.ambiguous }
                }
            }
            index += 1
        }
        guard state == .unquoted || state == .comment, depth == 0 else { throw Failure.ambiguous }
        let parsedLines = Self.makeLines(source: source, visible: visible, statements: statements)
        bytes = source
        mask = code
        lines = parsedLines
        quotedValues = quoted
    }

    func table(named name: String) throws -> Table? {
        var current: [String] = []
        var headerIndex: Int?
        var endIndex = lines.count
        for (index, line) in lines.enumerated() where line.isStatement {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[") {
                guard text.hasSuffix("]") else { throw Failure.ambiguous }
                let arrayTable = text.hasPrefix("[[")
                let body = String(text.dropFirst(arrayTable ? 2 : 1).dropLast(arrayTable ? 2 : 1))
                current = try Self.keyComponents(body)
                if headerIndex != nil && endIndex == lines.count { endIndex = index }
                if current == [name] {
                    guard headerIndex == nil, !arrayTable else { throw Failure.ambiguous }
                    headerIndex = index
                }
            } else if current.isEmpty, let assignment = try assignment(in: line), assignment.key.first == name {
                throw Failure.ambiguous
            }
        }
        guard let headerIndex else { return nil }
        return Table(header: lines[headerIndex], body: Array(lines[(headerIndex + 1)..<endIndex]))
    }

    func assignment(in line: Line) throws -> (key: [String], valueStart: Int)? {
        guard line.isStatement, let separator = mask[line.range].firstIndex(of: 61) else { return nil }
        return (
            try Self.keyComponents(Self.text(bytes[line.range.lowerBound..<separator])),
            separator + 1
        )
    }

    static func replacing(_ contents: String, edits: [(Range<Int>, String)]) -> String {
        var bytes = Array(contents.utf8)
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: replacement.utf8)
        }
        return Self.text(bytes)
    }

    private static func makeLines(source: [UInt8], visible: [UInt8], statements: [Bool]) -> [Line] {
        var parsedLines: [Line] = []
        var start = 0
        for end in source.indices where source[end] == 10 {
            parsedLines.append(
                .init(
                    range: start..<(end + 1), text: Self.text(visible[start..<end]),
                    isStatement: statements[parsedLines.count]))
            start = end + 1
        }
        if start < source.count {
            parsedLines.append(
                .init(
                    range: start..<source.count, text: Self.text(visible[start...]),
                    isStatement: statements[parsedLines.count]))
        }
        return parsedLines
    }

    static func text<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            preconditionFailure("TOML byte spans and ASCII masks must preserve UTF-8")
        }
        return text
    }

    private enum StringState { case unquoted, comment, basic, literal, multilineBasic, multilineLiteral }

    private static func quoteCount(_ bytes: [UInt8], at index: Int, delimiter: UInt8) -> Int {
        var end = index
        while end < bytes.count && bytes[end] == delimiter { end += 1 }
        return end - index
    }

    private static func decodeQuoted(_ text: String) throws -> String {
        if text.first == "'" { return String(text.dropFirst().dropLast()) }
        let characters = Array(text.dropFirst().dropLast())
        var decoded = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            guard character == "\\" else {
                decoded.append(character)
                continue
            }
            guard index < characters.count else { throw Failure.ambiguous }
            let escape = characters[index]
            index += 1
            switch escape {
            case "\"", "\\": decoded.append(escape)
            case "b": decoded.append("\u{8}")
            case "t": decoded.append("\t")
            case "n": decoded.append("\n")
            case "f": decoded.append("\u{c}")
            case "r": decoded.append("\r")
            case "u", "U":
                let count = escape == "u" ? 4 : 8
                guard index + count <= characters.count,
                    let value = UInt32(String(characters[index..<(index + count)]), radix: 16),
                    let scalar = Unicode.Scalar(value)
                else { throw Failure.ambiguous }
                decoded.unicodeScalars.append(scalar)
                index += count
            default: throw Failure.ambiguous
            }
        }
        return decoded
    }

    static func keyComponents(_ text: String) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var delimiter: Character?
        var escaped = false
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let quote = delimiter {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" && quote == "\"" {
                    escaped = true
                } else if character == quote {
                    delimiter = nil
                }
            } else if character == "\"" || character == "'" {
                delimiter = character
                current.append(character)
            } else if character == "." {
                parts.append(try keyPart(current))
                current = ""
            } else {
                current.append(character)
            }
        }
        guard delimiter == nil else { throw Failure.ambiguous }
        parts.append(try keyPart(current))
        return parts
    }

    private static func keyPart(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Failure.ambiguous }
        if trimmed.first == "\"" || trimmed.first == "'" { return try decodeQuoted(trimmed) }
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw Failure.ambiguous }
        return trimmed
    }
}
