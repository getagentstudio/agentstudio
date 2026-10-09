import Foundation
import Testing

/// `test:swift:webkit` runs exactly the selectors `webkit_suite_filters` prints,
/// and every other lane skips `WebKitSerializedTests` as a whole. A suite nested
/// under `WebKitSerializedTests` that the list omits therefore runs in no lane at
/// all; four #463 suites sat unrun that way (TQ50).
///
/// The source scan here is independent of the helper script. A gate that read the
/// script to find WebKit suites could not see the suite the script forgot.
@Suite("Swift lane WebKit suite list gate")
struct SwiftLaneWebKitSuiteListGateTests {
    @Test("webkit_suite_filters selects every suite declared under WebKitSerializedTests and nothing else")
    func webKitSuiteFiltersMatchTheDeclaredWebKitSuites() async throws {
        // Arrange
        let declaredSelectors = try webKitLaneSelectorsDeclaredUnderTests()

        // Act
        let listingResult = try await runLaneScriptBash(
            "source scripts/swift-test-helpers.sh\nwebkit_suite_filters"
        )
        let listing = webKitLaneListing(fromHelperOutput: listingResult.output)

        // Assert
        #expect(listingResult.exitCode == 0, Comment(rawValue: listingResult.output))
        #expect(
            listing.malformedLines.isEmpty,
            """
            webkit_suite_filters printed lines that are not WebKitSerializedTests/<Suite> selectors:
            \(listing.malformedLines.joined(separator: "\n"))
            """
        )
        let unlistedSuites = declaredSelectors.keys.filter { !listing.selectors.contains($0) }.sorted()
            .map { selector in
                "\(selector) (\(declaredSelectors[selector, default: []].sorted().joined(separator: ", ")))"
            }
        #expect(
            unlistedSuites.isEmpty,
            """
            These suites are declared under WebKitSerializedTests but missing from webkit_suite_filters in \
            scripts/swift-test-helpers.sh, so no lane runs them:
            \(unlistedSuites.joined(separator: "\n"))
            """
        )
        let staleSelectors = listing.selectors.filter { declaredSelectors[$0] == nil }.sorted()
        #expect(
            staleSelectors.isEmpty,
            """
            These webkit_suite_filters entries name no suite or test declared under WebKitSerializedTests in Tests/:
            \(staleSelectors.joined(separator: "\n"))
            """
        )
    }

    @Test("discovery sees annotated, unannotated and extended suites, but not helpers or string fixtures")
    func discoveryReadsEveryWebKitSuiteDeclarationForm() {
        // Arrange
        let source = [
            "extension WebKitSerializedTests {",
            "    @MainActor",
            "    @Suite(",
            "        \"Multi-line attribute\",",
            "        .serialized",
            "    )",
            "    struct MultiLineAttributeTests {",
            "        struct NestedHelper {}",
            "        @Test func runs() {}",
            "    }",
            "    @Suite(.serialized) struct SingleLineAttributeTests {}",
            "    struct UnannotatedTests {",
            "        let unbalancedBrace = \"{\"",
            "        @Test",
            "        func runs() {}",
            "    }",
            "    struct ExtendedOnlyTests {}",
            "    final class SupportOnly {",
            "        class func make() -> SupportOnly { SupportOnly() }",
            "    }",
            "}",
            "extension WebKitSerializedTests.ExtendedOnlyTests {",
            "    @Test func extendedRuns() {}",
            "}",
            "@Suite struct UnrelatedTests {",
            "    @Test func outside() {}",
            "}",
            "let fixture = \"\"\"",
            "    extension WebKitSerializedTests {",
            "        @Suite struct InsideStringLiteralTests {}",
            "    }",
            "    \"\"\"",
        ].joined(separator: "\n")

        // Act
        let selectors = webKitLaneSelectors(declaredIn: source)

        // Assert
        #expect(
            selectors == [
                "WebKitSerializedTests/MultiLineAttributeTests",
                "WebKitSerializedTests/SingleLineAttributeTests",
                "WebKitSerializedTests/UnannotatedTests",
                "WebKitSerializedTests/ExtendedOnlyTests",
            ]
        )
    }
}

private let webKitLaneRootSuite = "WebKitSerializedTests"

// MARK: - Lane listing

private struct WebKitLaneListing {
    let selectors: Set<String>
    let malformedLines: [String]
}

/// Each `webkit_suite_filters` line as the suite selector it runs. A per-test
/// entry (`WebKitSerializedTests/Suite/test`) names its suite.
private func webKitLaneListing(fromHelperOutput output: String) -> WebKitLaneListing {
    var selectors: Set<String> = []
    var malformedLines: [String] = []
    for line in output.split(whereSeparator: \.isNewline).map(String.init) {
        let segments = line.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2, segments[0] == webKitLaneRootSuite, !segments[1].isEmpty else {
            malformedLines.append(line)
            continue
        }
        selectors.insert(segments.prefix(2).joined(separator: "/"))
    }
    return WebKitLaneListing(selectors: selectors, malformedLines: malformedLines)
}

// MARK: - Source discovery

/// Every WebKit lane selector some file under `Tests/` needs, with the files
/// that need it.
private func webKitLaneSelectorsDeclaredUnderTests() throws -> [String: Set<String>] {
    var selectorSources: [String: Set<String>] = [:]
    let testsRoot = URL(fileURLWithPath: "Tests", isDirectory: true)
    let repositoryRootPrefix = FileManager.default.currentDirectoryPath + "/"
    let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
    while let fileURL = enumerator?.nextObject() as? URL {
        guard fileURL.pathExtension == "swift" else { continue }
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        // A declaration nested under the root names the root in its own file.
        guard source.contains(webKitLaneRootSuite) else { continue }
        let relativePath =
            fileURL.path.hasPrefix(repositoryRootPrefix)
            ? String(fileURL.path.dropFirst(repositoryRootPrefix.count)) : fileURL.path
        for selector in webKitLaneSelectors(declaredIn: source) {
            selectorSources[selector, default: []].insert(relativePath)
        }
    }
    return selectorSources
}

/// The selectors `webkit_suite_filters` must list for `source` to run: the root
/// and first nested type of every `@Suite` type and of the type enclosing every
/// `@Test` under `WebKitSerializedTests`. A type with `@Test` members is a suite
/// even without `@Suite`, and the lane filter on a first nested type selects
/// everything beneath it.
private func webKitLaneSelectors(declaredIn source: String) -> Set<String> {
    var scanner = SwiftTestDeclarationScanner()
    for line in source.components(separatedBy: "\n") {
        scanner.scan(line: line)
    }
    let nestedSuitePaths = scanner.suiteTypePaths.filter { $0.count >= 2 }
    return Set(
        (nestedSuitePaths + scanner.testEnclosingTypePaths).compactMap { typePath in
            typePath.first == webKitLaneRootSuite ? typePath.prefix(2).joined(separator: "/") : nil
        }
    )
}

/// A line scanner for the declarations Swift Testing runs, not a Swift parser.
/// Brace depth tracks the enclosing `extension`/type path (dotted extensions
/// included); string-literal contents and comments are skipped so fixture text
/// and unbalanced braces inside strings do not move it.
private struct SwiftTestDeclarationScanner {
    private struct EnclosingScope {
        let pathSegments: [String]
        let braceDepthBeforeDeclaration: Int
        var hasOpenedBody: Bool
    }

    private(set) var suiteTypePaths: [[String]] = []
    private(set) var testEnclosingTypePaths: [[String]] = []
    private var pendingAttributes = ""
    private var openAttributeParenthesisDepth = 0
    private var multilineStringCloser: String?
    private var enclosingScopes: [EnclosingScope] = []
    private var braceDepth = 0

    private var enclosingTypePath: [String] {
        enclosingScopes.flatMap(\.pathSegments)
    }

    mutating func scan(line rawLine: String) {
        var line = Substring(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        if let closer = multilineStringCloser {
            guard let closerRange = line.range(of: closer) else { return }
            multilineStringCloser = nil
            line = line[closerRange.upperBound...]
        }
        let lineCode = swiftCodeOutsideLiterals(line)
        let code = lineCode.code.trimmingCharacters(in: .whitespaces)
        recordDeclarations(in: Substring(code))

        if let innermostScope = enclosingScopes.last, !innermostScope.hasOpenedBody, code.contains("{") {
            enclosingScopes[enclosingScopes.count - 1].hasOpenedBody = true
        }
        braceDepth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
        while let innermostScope = enclosingScopes.last,
            innermostScope.hasOpenedBody,
            braceDepth <= innermostScope.braceDepthBeforeDeclaration
        {
            enclosingScopes.removeLast()
        }
        multilineStringCloser = lineCode.multilineStringCloser
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
            testEnclosingTypePaths.append(enclosingTypePath)
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
/// leading modifiers are dropped: `final class Foo: Bar {` is `class`, `Foo`.
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
/// or the line's end and the depth still open when the arguments continue.
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

/// A line's code with string-literal contents and any trailing `//` comment
/// removed, plus the delimiter that closes a multi-line string the line opens.
/// Raw strings (`#"..."#`, `#"""`) close only on their own hash count.
private func swiftCodeOutsideLiterals(_ line: Substring) -> (code: String, multilineStringCloser: String?) {
    var code = ""
    var index = line.startIndex
    while index < line.endIndex {
        let rest = line[index...]
        if rest.hasPrefix("//") { break }
        let hashCount = rest.prefix { $0 == "#" }.count
        let afterHashes = rest.dropFirst(hashCount)
        let rawDelimiter = String(repeating: "#", count: hashCount)
        if afterHashes.hasPrefix("\"\"\"") {
            return (code, "\"\"\"" + rawDelimiter)
        }
        if afterHashes.hasPrefix("\"") {
            index = singleLineStringEnd(
                in: line,
                contentStart: afterHashes.index(after: afterHashes.startIndex),
                closer: "\"" + rawDelimiter,
                isRaw: hashCount > 0
            )
            continue
        }
        code.append(line[index])
        index = line.index(after: index)
    }
    return (code, nil)
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
