import AgentStudioTestSupport
import Foundation
import Testing

/// `test:swift:webkit` runs exactly the selectors `webkit_suite_filters` prints,
/// and every other lane skips `WebKitSerializedTests` as a whole. A suite nested
/// under `WebKitSerializedTests` that the list omits therefore runs in no lane at
/// all; four #463 suites sat unrun that way (TQ50). A suite listed one test per
/// line, for process isolation, runs only the tests it names.
///
/// The source scan here is independent of the helper script. A gate that read the
/// script to find WebKit suites could not see the suite the script forgot.
@Suite("Swift lane WebKit suite list gate")
struct SwiftLaneWebKitSuiteListGateTests {
    @Test("webkit_suite_filters selects every suite and test declared under WebKitSerializedTests and nothing else")
    func webKitSuiteFiltersMatchTheDeclaredWebKitSuites() async throws {
        // Arrange
        let declared = try await withoutBlockingCooperativePool {
            try webKitLaneUnitsDeclaredUnderTests()
        }

        // Act
        let listingResult = try await runLaneScriptBash(
            "source scripts/swift-test-helpers.sh\nwebkit_suite_filters"
        )
        let listing = webKitLaneListing(fromHelperOutput: listingResult.output)
        let verdict = webKitLaneListVerdict(declared: declared, listedEntries: listing.entries)

        // Assert
        #expect(listingResult.exitCode == 0, Comment(rawValue: listingResult.output))
        #expect(
            listing.malformedLines.isEmpty,
            """
            webkit_suite_filters printed lines that are not WebKitSerializedTests/<Suite>[/<test>] selectors:
            \(listing.malformedLines.joined(separator: "\n"))
            """
        )
        let unlistedDescriptions = verdict.unlisted.map { unlistedPath in
            let sourcePaths = declared.suiteSources[unlistedPath] ?? declared.testSources[unlistedPath] ?? []
            return "\(unlistedPath) (\(sourcePaths.sorted().joined(separator: ", ")))"
        }
        #expect(
            verdict.unlisted.isEmpty,
            """
            These suites or tests are declared under WebKitSerializedTests but no webkit_suite_filters entry in \
            scripts/swift-test-helpers.sh selects them, so no lane runs them:
            \(unlistedDescriptions.joined(separator: "\n"))
            """
        )
        #expect(
            verdict.stale.isEmpty,
            """
            These webkit_suite_filters entries name no suite or test declared under WebKitSerializedTests in Tests/:
            \(verdict.stale.joined(separator: "\n"))
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
        let declared = webKitLaneUnits(declaredIn: source, sourcePath: "Fixture.swift")

        // Assert
        #expect(
            Set(declared.suiteSources.keys) == [
                "WebKitSerializedTests/MultiLineAttributeTests",
                "WebKitSerializedTests/SingleLineAttributeTests",
                "WebKitSerializedTests/UnannotatedTests",
                "WebKitSerializedTests/ExtendedOnlyTests",
            ]
        )
        #expect(
            Set(declared.testSources.keys) == [
                "WebKitSerializedTests/MultiLineAttributeTests/runs",
                "WebKitSerializedTests/UnannotatedTests/runs",
                "WebKitSerializedTests/ExtendedOnlyTests/extendedRuns",
            ]
        )
    }

    @Test("block comments neither close the enclosing scope nor declare suites")
    func blockCommentsAreSkippedAcrossLines() {
        // Arrange
        let source = [
            "extension WebKitSerializedTests {",
            "    /* } */",
            "    /* outer /* nested } */ still commented }",
            "    */",
            "    @Suite(.serialized) struct AfterBlockCommentTests {}",
            "    /*",
            "    @Suite(.serialized) struct CommentedOutTests {",
            "        @Test func runs() {}",
            "    }",
            "    */",
            "}",
        ].joined(separator: "\n")

        // Act
        let declared = webKitLaneUnits(declaredIn: source, sourcePath: "Fixture.swift")

        // Assert
        #expect(Set(declared.suiteSources.keys) == ["WebKitSerializedTests/AfterBlockCommentTests"])
        #expect(declared.testSources.isEmpty)
    }

    @Test("a suite declared with its tests on one line keeps its tests")
    func inlineSuiteBodyDeclarationsAreSeen() {
        // Arrange
        let source = [
            "extension WebKitSerializedTests {",
            "    struct AddedTests { @Test func runs() {} }",
            "    @Suite struct AfterInlineTests {}",
            "}",
        ].joined(separator: "\n")

        // Act
        let declared = webKitLaneUnits(declaredIn: source, sourcePath: "Fixture.swift")

        // Assert
        #expect(
            Set(declared.suiteSources.keys) == [
                "WebKitSerializedTests/AddedTests",
                "WebKitSerializedTests/AfterInlineTests",
            ]
        )
        #expect(Set(declared.testSources.keys) == ["WebKitSerializedTests/AddedTests/runs"])
    }

    @Test("a suite listed per test must list exactly its declared tests")
    func perTestListingMustNameEveryDeclaredTest() {
        // Arrange
        let declared = webKitLaneUnits(
            declaredIn: [
                "extension WebKitSerializedTests {",
                "    @Suite(.serialized)",
                "    struct PerTestListedTests {",
                "        @Test func first() {}",
                "        @Test func second() {}",
                "        @Test func added() {}",
                "    }",
                "    @Suite(.serialized)",
                "    struct WholeSuiteListedTests {",
                "        @Test func covered() {}",
                "    }",
                "}",
            ].joined(separator: "\n"),
            sourcePath: "Fixture.swift"
        )

        // Act
        let omittedAndAddedTests = webKitLaneListVerdict(
            declared: declared,
            listedEntries: [
                "WebKitSerializedTests/PerTestListedTests/first",
                "WebKitSerializedTests/WholeSuiteListedTests",
            ]
        )
        let removedTestStillListed = webKitLaneListVerdict(
            declared: declared,
            listedEntries: [
                "WebKitSerializedTests/PerTestListedTests/first",
                "WebKitSerializedTests/PerTestListedTests/second",
                "WebKitSerializedTests/PerTestListedTests/added",
                "WebKitSerializedTests/PerTestListedTests/removed",
                "WebKitSerializedTests/WholeSuiteListedTests",
            ]
        )

        // Assert
        #expect(
            omittedAndAddedTests
                == WebKitLaneListVerdict(
                    unlisted: [
                        "WebKitSerializedTests/PerTestListedTests/added",
                        "WebKitSerializedTests/PerTestListedTests/second",
                    ],
                    stale: []
                )
        )
        #expect(
            removedTestStillListed
                == WebKitLaneListVerdict(unlisted: [], stale: ["WebKitSerializedTests/PerTestListedTests/removed"])
        )
    }
}

private let webKitLaneRootSuite = "WebKitSerializedTests"

// MARK: - Lane listing

private struct WebKitLaneListing {
    let entries: Set<String>
    let malformedLines: [String]
}

/// Each `webkit_suite_filters` line as a selector path: a whole suite
/// (`WebKitSerializedTests/Suite`) or one test (`WebKitSerializedTests/Suite/test`).
private func webKitLaneListing(fromHelperOutput output: String) -> WebKitLaneListing {
    var entries: Set<String> = []
    var malformedLines: [String] = []
    for line in output.split(whereSeparator: \.isNewline).map(String.init) {
        let segments = line.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments[0] == webKitLaneRootSuite, !segments.contains(where: \.isEmpty) else {
            malformedLines.append(line)
            continue
        }
        entries.insert(line)
    }
    return WebKitLaneListing(entries: entries, malformedLines: malformedLines)
}

// MARK: - List verdict

private struct WebKitLaneListVerdict: Equatable {
    let unlisted: [String]
    let stale: [String]
}

/// An entry selects itself and everything beneath it, so a whole-suite entry
/// runs every test in the suite and a per-test entry runs one. Every declared
/// suite needs an entry, every declared test needs an entry that selects it,
/// and an entry that selects no declared suite or test is stale. A suite with no
/// entry at all is reported once, by its selector.
private func webKitLaneListVerdict(
    declared: DeclaredWebKitLaneUnits, listedEntries: Set<String>
) -> WebKitLaneListVerdict {
    var unlisted: Set<String> = []
    for suiteSelector in declared.suiteSources.keys
    where !listedEntries.contains(where: { selectorPath($0, isEqualToOrBeneath: suiteSelector) }) {
        unlisted.insert(suiteSelector)
    }
    for testPath in declared.testSources.keys
    where !listedEntries.contains(where: { selectorPath(testPath, isEqualToOrBeneath: $0) }) {
        let suiteSelector = testPath.split(separator: "/").prefix(2).joined(separator: "/")
        unlisted.insert(unlisted.contains(suiteSelector) ? suiteSelector : testPath)
    }
    let declaredPaths = Array(declared.suiteSources.keys) + Array(declared.testSources.keys)
    let stale = listedEntries.filter { entry in
        !declaredPaths.contains { selectorPath($0, isEqualToOrBeneath: entry) }
    }
    return WebKitLaneListVerdict(unlisted: unlisted.sorted(), stale: stale.sorted())
}

/// Whether `path` is `ancestor` or nested under it, by whole `/` components.
private func selectorPath(_ path: String, isEqualToOrBeneath ancestor: String) -> Bool {
    path == ancestor || path.hasPrefix(ancestor + "/")
}

// MARK: - Source discovery

/// What the WebKit lane must run, with the files that declare each one.
private struct DeclaredWebKitLaneUnits: Sendable {
    /// `WebKitSerializedTests/<Type>` for every suite under the root: a type
    /// annotated `@Suite`, or one enclosing a `@Test` at any depth beneath it.
    var suiteSources: [String: Set<String>] = [:]
    /// `WebKitSerializedTests/<Type>/.../<function>` for every `@Test` under the root.
    var testSources: [String: Set<String>] = [:]

    mutating func merge(_ other: Self) {
        suiteSources.merge(other.suiteSources) { $0.union($1) }
        testSources.merge(other.testSources) { $0.union($1) }
    }
}

/// Every WebKit lane unit declared under `Tests/`. This is synchronous file I/O;
/// run it through `withoutBlockingCooperativePool`.
private func webKitLaneUnitsDeclaredUnderTests() throws -> DeclaredWebKitLaneUnits {
    var declared = DeclaredWebKitLaneUnits()
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
        declared.merge(webKitLaneUnits(declaredIn: source, sourcePath: relativePath))
    }
    return declared
}

/// The WebKit lane units `source` declares. Each suite is named by the root and
/// its first nested type, the way the lane selects a whole suite; a type with
/// `@Test` members is a suite even without `@Suite`.
private func webKitLaneUnits(declaredIn source: String, sourcePath: String) -> DeclaredWebKitLaneUnits {
    var scanner = SwiftTestDeclarationScanner()
    for line in source.components(separatedBy: "\n") {
        scanner.scan(line: line)
    }
    var declared = DeclaredWebKitLaneUnits()
    let testEnclosingTypePaths = scanner.testFunctionPaths.map { Array($0.dropLast()) }
    for typePath in scanner.suiteTypePaths + testEnclosingTypePaths
    where typePath.count >= 2 && typePath.first == webKitLaneRootSuite {
        declared.suiteSources[typePath.prefix(2).joined(separator: "/"), default: []].insert(sourcePath)
    }
    for testPath in scanner.testFunctionPaths where testPath.first == webKitLaneRootSuite {
        declared.testSources[testPath.joined(separator: "/"), default: []].insert(sourcePath)
    }
    return declared
}
