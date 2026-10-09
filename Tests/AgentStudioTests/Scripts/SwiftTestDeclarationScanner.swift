import Foundation

/// A scanner for the declarations Swift Testing runs, not a Swift parser. It
/// splits each line's code at `{`, `}` and `;`, so declarations sharing a line
/// are each seen, and brace depth tracks the enclosing `extension`/type path
/// (dotted extensions included). String contents and comments, including nested
/// block comments across lines, never reach it.
struct SwiftTestDeclarationScanner {
    private struct EnclosingScope {
        let pathSegments: [String]
        let braceDepthBeforeDeclaration: Int
        var hasOpenedBody: Bool
    }

    private(set) var suiteTypePaths: [[String]] = []
    /// The enclosing type path plus the function name of every `@Test`.
    private(set) var testFunctionPaths: [[String]] = []
    private var lexicalContext = SwiftLexicalContext.code
    private var pendingAttributes = ""
    private var openAttributeParenthesisDepth = 0
    private var enclosingScopes: [EnclosingScope] = []
    private var braceDepth = 0

    private var enclosingTypePath: [String] {
        enclosingScopes.flatMap(\.pathSegments)
    }

    mutating func scan(line rawLine: String) {
        let lexed = swiftCodeOutsideLiteralsAndComments(
            Substring(rawLine.trimmingCharacters(in: .whitespacesAndNewlines)),
            startingIn: lexicalContext
        )
        lexicalContext = lexed.nextContext
        var statement = ""
        for character in lexed.code {
            guard character == "{" || character == "}" || character == ";" else {
                statement.append(character)
                continue
            }
            recordDeclarations(in: Substring(statement.trimmingCharacters(in: .whitespaces)))
            statement = ""
            applyStatementBoundary(character)
        }
        recordDeclarations(in: Substring(statement.trimmingCharacters(in: .whitespaces)))
    }

    private mutating func applyStatementBoundary(_ boundary: Character) {
        switch boundary {
        case "{":
            if let innermostScope = enclosingScopes.last, !innermostScope.hasOpenedBody {
                enclosingScopes[enclosingScopes.count - 1].hasOpenedBody = true
            }
            braceDepth += 1
        case "}":
            braceDepth -= 1
            while let innermostScope = enclosingScopes.last,
                innermostScope.hasOpenedBody,
                braceDepth <= innermostScope.braceDepthBeforeDeclaration
            {
                enclosingScopes.removeLast()
            }
        default:
            return
        }
    }

    private mutating func recordDeclarations(in code: Substring) {
        var remainder = code
        if openAttributeParenthesisDepth > 0 {
            let arguments = parenthesizedArgumentsEnd(in: remainder, openDepth: openAttributeParenthesisDepth)
            pendingAttributes += "\n" + String(remainder[..<arguments.end])
            openAttributeParenthesisDepth = arguments.unclosedDepth
            guard arguments.unclosedDepth == 0 else { return }
            remainder = remainder[arguments.end...].drop(while: \.isWhitespace)
        }
        while remainder.hasPrefix("@") {
            let attribute = leadingAttributeEnd(in: remainder)
            pendingAttributes += "\n" + String(remainder[..<attribute.end])
            openAttributeParenthesisDepth = attribute.unclosedDepth
            guard attribute.unclosedDepth == 0 else { return }
            remainder = remainder[attribute.end...].drop(while: \.isWhitespace)
        }
        guard !remainder.isEmpty else { return }

        let attributes = pendingAttributes
        pendingAttributes = ""
        guard let declaration = leadingDeclaration(in: remainder) else { return }
        switch declaration.keyword {
        case "struct", "class", "actor", "enum":
            let typeName = String(declaration.name)
            guard !typeName.isEmpty, !typeName.contains("."), !nonTypeNamesAfterClassKeyword.contains(typeName)
            else { return }
            if hasAttribute(named: "Suite", in: attributes) {
                suiteTypePaths.append(enclosingTypePath + [typeName])
            }
            enclosingScopes.append(
                EnclosingScope(
                    pathSegments: [typeName], braceDepthBeforeDeclaration: braceDepth, hasOpenedBody: false
                )
            )
        case "extension" where !declaration.name.isEmpty:
            enclosingScopes.append(
                EnclosingScope(
                    pathSegments: declaration.name.split(separator: ".").map(String.init),
                    braceDepthBeforeDeclaration: braceDepth,
                    hasOpenedBody: false
                )
            )
        case "func" where hasAttribute(named: "Test", in: attributes):
            testFunctionPaths.append(enclosingTypePath + [String(declaration.name)])
        default:
            return
        }
    }
}

private let declarationModifiers: Set<Substring> = [
    "public", "package", "internal", "private", "fileprivate", "open", "final", "indirect", "nonisolated",
    "static", "mutating", "override",
]

/// `class func`, `class var` and the like declare members, not a class.
private let nonTypeNamesAfterClassKeyword: Set<String> = ["func", "var", "let", "subscript", "init", "deinit"]

/// The declaration keyword and the (possibly dotted) name after it, once
/// leading modifiers are dropped: `final class Foo: Bar` is `class`, `Foo`.
private func leadingDeclaration(in text: Substring) -> (keyword: Substring, name: Substring)? {
    var remainder = text
    while true {
        let word = remainder.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !word.isEmpty else { return nil }
        remainder = remainder[word.endIndex...].drop(while: \.isWhitespace)
        guard declarationModifiers.contains(word) else {
            let name = remainder.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            guard name.first.map({ $0.isLetter || $0 == "_" }) ?? true else { return nil }
            return (word, name)
        }
    }
}

/// Whether `@name` appears as a whole attribute, never as a prefix such as `@TestSupport`.
private func hasAttribute(named attributeName: String, in attributes: String) -> Bool {
    var searchRange = attributes.startIndex..<attributes.endIndex
    while let attributeRange = attributes.range(of: "@\(attributeName)", range: searchRange) {
        searchRange = attributeRange.upperBound..<attributes.endIndex
        guard attributeRange.upperBound < attributes.endIndex else { return true }
        let nextCharacter = attributes[attributeRange.upperBound]
        if !nextCharacter.isLetter, !nextCharacter.isNumber, nextCharacter != "_" {
            return true
        }
    }
    return false
}

/// The end of the attribute that starts `text`: `@Name` plus any argument list,
/// or the statement's end and the depth still open when the arguments continue.
private func leadingAttributeEnd(in text: Substring) -> (end: Substring.Index, unclosedDepth: Int) {
    let nameEnd =
        text.dropFirst().firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? text.endIndex
    guard nameEnd < text.endIndex, text[nameEnd] == "(" else { return (nameEnd, 0) }
    return parenthesizedArgumentsEnd(in: text[nameEnd...], openDepth: 0)
}

/// Where an argument list already `openDepth` deep closes within `text`.
private func parenthesizedArgumentsEnd(
    in text: Substring, openDepth: Int
) -> (end: Substring.Index, unclosedDepth: Int) {
    var depth = openDepth
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "(" {
            depth += 1
        } else if text[index] == ")" {
            depth -= 1
            if depth == 0 {
                return (text.index(after: index), 0)
            }
        }
        index = text.index(after: index)
    }
    return (text.endIndex, max(0, depth))
}

// MARK: - Lexing

/// Where a line starts: in code, inside a block comment `depth` deep, or inside
/// a multi-line string that `closer` ends.
private enum SwiftLexicalContext: Equatable {
    case code
    case blockComment(depth: Int)
    case multilineString(closer: String)
}

/// A line's code with string-literal contents and comments removed, and the
/// context the next line starts in. Block comments nest; raw strings
/// (`#"..."#`, `#"""`) close only on their own hash count.
private func swiftCodeOutsideLiteralsAndComments(
    _ line: Substring, startingIn startContext: SwiftLexicalContext
) -> (code: String, nextContext: SwiftLexicalContext) {
    var code = ""
    var context = startContext
    var index = line.startIndex
    while index < line.endIndex {
        let rest = line[index...]
        switch context {
        case .multilineString(let closer):
            guard let closerRange = rest.range(of: closer) else { return (code, context) }
            context = .code
            index = closerRange.upperBound
        case .blockComment(let depth):
            if rest.hasPrefix("/*") {
                context = .blockComment(depth: depth + 1)
                index = line.index(index, offsetBy: 2)
            } else if rest.hasPrefix("*/") {
                context = depth == 1 ? .code : .blockComment(depth: depth - 1)
                index = line.index(index, offsetBy: 2)
            } else {
                index = line.index(after: index)
            }
        case .code:
            if rest.hasPrefix("//") {
                return (code, context)
            }
            if rest.hasPrefix("/*") {
                // A comment separates tokens the way whitespace does.
                code.append(" ")
                context = .blockComment(depth: 1)
                index = line.index(index, offsetBy: 2)
                continue
            }
            let hashCount = rest.prefix { $0 == "#" }.count
            let afterHashes = rest.dropFirst(hashCount)
            let rawDelimiter = String(repeating: "#", count: hashCount)
            if afterHashes.hasPrefix("\"\"\"") {
                context = .multilineString(closer: "\"\"\"" + rawDelimiter)
                index = line.index(afterHashes.startIndex, offsetBy: 3)
            } else if afterHashes.hasPrefix("\"") {
                index = singleLineStringEnd(
                    in: line,
                    contentStart: afterHashes.index(after: afterHashes.startIndex),
                    closer: "\"" + rawDelimiter,
                    isRaw: hashCount > 0
                )
            } else {
                code.append(line[index])
                index = line.index(after: index)
            }
        }
    }
    return (code, context)
}

private func singleLineStringEnd(
    in line: Substring, contentStart: Substring.Index, closer: String, isRaw: Bool
) -> Substring.Index {
    var index = contentStart
    while index < line.endIndex {
        if !isRaw, line[index] == "\\" {
            index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
            continue
        }
        if line[index...].hasPrefix(closer) {
            return line.index(index, offsetBy: closer.count)
        }
        index = line.index(after: index)
    }
    return line.endIndex
}
