import AgentStudioTestSupport
import Foundation
import Testing

/// The exact lane inventory owns non-fast suite placement and execution mode.
/// MainActor serialized suites are discovered independently and must map to a
/// non-concurrent mode; cross-package aggregate entries remain explicitly kept.
///
/// This suite pins the old hand-kept selections across the inventory migration
/// and catches serialized suites that would run alongside unrelated tests.
@Suite("Swift lane isolation list gate")
struct SwiftLaneIsolationListGateTests {
    @Test("every former hand-kept suite remains in an isolated selector")
    func everyFormerHandKeptSuiteRemainsInAnIsolatedSelector() async throws {
        let helperScript = try String(contentsOfFile: "scripts/swift-test-helpers.sh", encoding: .utf8)
        let aggregateFunction = try shellFunctionBody(
            named: "aggregate_serial_non_webkit_suite_filters",
            in: helperScript
        )
        let largeFunction = try shellFunctionBody(
            named: "large_process_global_suite_filters",
            in: helperScript
        )
        let aggregateEntries = explicitSuitePathPairs(in: aggregateFunction)
        let aggregateSuiteNames = Set(aggregateEntries.map(\.suiteName))
        let formerAggregateSuiteNames: Set<String> = [
            "TerminalActivityProjectorTests",
            "GitWorkingDirectoryProjectorTests",
            "BridgeDevelopmentSeededWorktreeObservationTests",
            "AgentStudioAppIPCServiceTests",
            "AgentStudioAppIPCServiceAuthModeTests",
            "AgentStudioAppIPCServiceCommandTests",
            "AgentStudioAppIPCServiceContributionTests",
            "AgentStudioIPCBridgeServiceTests",
            "AgentStudioIPCBridgeRenderDiagnosticsTests",
            "AgentStudioIPCBridgeSearchModeTests",
            "AgentStudioIPCBridgeNonBridgeTargetTests",
            "AgentStudioIPCBridgeDiagnosticTargetTests",
            "AgentStudioIPCBridgePaneAgentTests",
            "AgentStudioIPCBridgeRejectedControlTests",
            "AgentStudioAppIPCCommandExecuteContractTests",
            "AppIPCDynamicCommandClientTests",
            "AppIPCErrorCorrectionTests",
            "AgentStudioAppIPCConnectionHandlerLifecycleTests",
        ]
        #expect(aggregateSuiteNames == formerAggregateSuiteNames)
        #expect(explicitSuitePathPairs(in: largeFunction).isEmpty)

        for entry in aggregateEntries {
            #expect(
                FileManager.default.fileExists(atPath: entry.sourcePath),
                "Stale isolation entry: \(entry.sourcePath):\(entry.suiteName) names a file that no longer exists"
            )
            guard let source = try? String(contentsOfFile: entry.sourcePath, encoding: .utf8) else {
                continue
            }
            #expect(
                declaresType(named: entry.suiteName, in: source),
                "Stale isolation entry: \(entry.sourcePath) no longer declares \(entry.suiteName)"
            )
        }

        let aggregateIsolatedSuiteNames = try await shellHelperLines("aggregate_serial_non_webkit_suite_filters")
        #expect(formerAggregateSuiteNames.isSubset(of: aggregateIsolatedSuiteNames))

        // These nine explicit large process-global suites moved from the old
        // hand-kept path list into the exact lane inventory in batch 2.
        let formerLargeProcessGlobalSuiteNames: Set<String> = [
            "AgentStudioOTLPBootstrapSmokeTests",
            "DarwinSharedExactItemRealStreamIntegrationTests",
            "DarwinCompositeFSEventContinuityTests",
            "DarwinFSEventStreamClientTests",
            "DarwinSharedLocalFSEventObserverFailureTests",
            "DarwinSharedLocalFSEventObserverTests",
            "DarwinSharedExactItemObserverTests",
            "FilesystemActorActivityTests",
            "WorkspaceStrictStartupSubprocessTests",
        ]
        let inventoryRows = try await laneInventoryRows()
        for suiteName in formerLargeProcessGlobalSuiteNames {
            let row = try #require(inventoryRows.first { $0.suiteTypePath == suiteName })
            #expect(
                row.mode == "process-global",
                "Former hand-kept suite \(suiteName) must remain in a process-isolated lane"
            )
        }
    }

    @Test("every serialized MainActor suite runs in an isolated lane")
    func everySerializedMainActorSuiteRunsInAnIsolatedLane() async throws {
        let inventoryRows = try await laneInventoryRows()
        let aggregateIsolatedSuiteNames = try await shellHelperLines("aggregate_serial_non_webkit_suite_filters")

        for suite in try discoveredSerializedMainActorSuites() {
            let suiteTypePath = suite.suiteTypePath
            guard let row = inventoryRows.first(where: { $0.suiteTypePath == suiteTypePath }) else {
                #expect(
                    suite.isRoutedOnDedicatedLane
                        || (suite.enclosingTypeNames.isEmpty && aggregateIsolatedSuiteNames.contains(suite.name)),
                    "Serialized MainActor suite \(suiteTypePath) has no inventory row or aggregate isolated selector"
                )
                continue
            }
            #expect(
                row.mode != "concurrent",
                """
                \(suiteTypePath) (\(suite.sourcePath)) is marked @MainActor + @Suite(.serialized) but is routed to \
                the concurrent \(row.lane) lane; keep it in a serial or process-global execution mode.
                """
            )
        }
    }

    @Test("E2E and zmx name substrings do not skip isolation without a dedicated-lane parent")
    func e2eAndZmxNameSubstringsDoNotSkipIsolationWithoutDedicatedLaneParent() {
        let nested = serializedMainActorSuites(
            in: [
                "extension E2ESerializedTests {",
                "@MainActor",
                "@Suite(.serialized)",
                "struct FilesystemSourceE2ETests {}",
                "}",
            ].joined(separator: "\n")
        )
        #expect(nested.map(\.name) == ["FilesystemSourceE2ETests"])
        #expect(nested.first?.enclosingTypeNames == ["E2ESerializedTests"])
        #expect(nested.first?.isRoutedOnDedicatedLane == true)

        let zmxChild = serializedMainActorSuites(
            in: [
                "extension E2ESerializedTests {",
                "@Suite(.serialized)",
                "@MainActor",
                "struct ZmxBackendIntegrationTests {}",
                "}",
            ].joined(separator: "\n")
        )
        #expect(zmxChild.first?.isRoutedOnDedicatedLane == true)

        let webkitChild = serializedMainActorSuites(
            in: [
                "extension WebKitSerializedTests {",
                "@MainActor",
                "@Suite(.serialized)",
                "struct BridgePaneControllerIPCProjectionTests {}",
                "}",
            ].joined(separator: "\n")
        )
        #expect(webkitChild.first?.suiteTypePath == "WebKitSerializedTests/BridgePaneControllerIPCProjectionTests")
        #expect(webkitChild.first?.isRoutedOnDedicatedLane == true)

        let standalone = serializedMainActorSuites(
            in: [
                "@MainActor",
                "@Suite(.serialized)",
                "struct NewE2ETests {}",
            ].joined(separator: "\n")
        )
        #expect(standalone.map(\.name) == ["NewE2ETests"])
        #expect(standalone.first?.enclosingTypeNames.isEmpty == true)
        #expect(standalone.first?.isRoutedOnDedicatedLane == false)

        let zmxSubstring = serializedMainActorSuites(
            in: [
                "@MainActor",
                "@Suite(\"Workspace SQLite zmx session ID storage\", .serialized)",
                "struct WorkspaceSQLiteZmxSessionIDStorageTests {}",
            ].joined(separator: "\n")
        )
        #expect(zmxSubstring.first?.isRoutedOnDedicatedLane == false)
    }

    // MARK: - Lane inventories

    private func laneInventoryRows() async throws -> [LaneInventoryRow] {
        try await shellHelperLines("swift_test_suite_lane_inventory").map { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else {
                throw SwiftLaneIsolationListGateError.malformedInventoryRow(line)
            }
            return LaneInventoryRow(lane: fields[0], suiteTypePath: fields[1], mode: fields[2])
        }
    }

    // MARK: - Independent discovery

    private struct DiscoveredSuite {
        let name: String
        let sourcePath: String
        let enclosingTypeNames: [String]

        var suiteTypePath: String {
            (enclosingTypeNames + [name]).joined(separator: "/")
        }

        /// Nested children inherit their exact dedicated lane parent. A substring
        /// such as `NewE2ETests` is not a dedicated lane.
        var isRoutedOnDedicatedLane: Bool {
            Self.isRoutedOnDedicatedLane(name: name, enclosingTypeNames: enclosingTypeNames)
        }

        static func isRoutedOnDedicatedLane(name: String, enclosingTypeNames: [String]) -> Bool {
            let dedicatedLaneSuites: Set<String> = ["E2ESerializedTests", "ZmxE2ETests", "WebKitSerializedTests"]
            if dedicatedLaneSuites.contains(name) {
                return true
            }
            if enclosingTypeNames.contains(where: dedicatedLaneSuites.contains) {
                return true
            }
            return [
                "GlobalPreferencesBootstrapBenchmarkTests",
                "RepoExplorerNativeTablePilotBenchmarkTests",
            ].contains(name)
        }
    }

    /// Scans `Tests/` for types carrying both `@MainActor` and a `@Suite(...)`
    /// with the `.serialized` trait, in either attribute order and across
    /// formatted multi-line arguments.
    ///
    /// Deliberately independent of the helper script's perl patterns: a gate that
    /// reused them could not catch a suite those patterns fail to see.
    private func discoveredSerializedMainActorSuites() throws -> [DiscoveredSuite] {
        var discovered: [DiscoveredSuite] = []
        let testsRoot = URL(fileURLWithPath: "Tests", isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: testsRoot,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let relativePath =
                fileURL.path.hasPrefix(FileManager.default.currentDirectoryPath + "/")
                ? String(fileURL.path.dropFirst(FileManager.default.currentDirectoryPath.count + 1))
                : fileURL.path
            for suite in serializedMainActorSuites(in: source) {
                discovered.append(
                    DiscoveredSuite(
                        name: suite.name,
                        sourcePath: relativePath,
                        enclosingTypeNames: suite.enclosingTypeNames
                    )
                )
            }
        }
        return discovered
    }

    private struct SerializedMainActorSuite {
        let name: String
        let enclosingTypeNames: [String]

        var suiteTypePath: String {
            (enclosingTypeNames + [name]).joined(separator: "/")
        }

        var isRoutedOnDedicatedLane: Bool {
            DiscoveredSuite.isRoutedOnDedicatedLane(name: name, enclosingTypeNames: enclosingTypeNames)
        }
    }

    /// Attribute lines accumulate until a declaration consumes them; anything
    /// else clears them, so a nested type inside a serialized suite is not
    /// mistaken for the suite. Brace depth tracks `extension` / type parents so
    /// dedicated-lane membership is the enclosing type, not a name substring.
    private func serializedMainActorSuites(in source: String) -> [SerializedMainActorSuite] {
        var suiteNames: [SerializedMainActorSuite] = []
        var pendingAttributes = ""
        var openParenthesisDepth = 0
        var enclosingTypes: [(name: String, braceDepth: Int)] = []
        var braceDepth = 0

        for line in source.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if openParenthesisDepth > 0 {
                pendingAttributes += "\n" + trimmedLine
                openParenthesisDepth += parenthesisDelta(in: trimmedLine)
                braceDepth += braceDelta(in: trimmedLine)
                popClosedEnclosingTypes(
                    enclosingTypes: &enclosingTypes,
                    braceDepth: braceDepth
                )
                continue
            }
            if trimmedLine.hasPrefix("@") {
                pendingAttributes += "\n" + trimmedLine
                openParenthesisDepth = max(0, parenthesisDelta(in: trimmedLine))
                continue
            }
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("//") {
                braceDepth += braceDelta(in: trimmedLine)
                popClosedEnclosingTypes(
                    enclosingTypes: &enclosingTypes,
                    braceDepth: braceDepth
                )
                continue
            }
            let attributes = pendingAttributes
            pendingAttributes = ""
            if let declaredTypeName = declaredTypeName(in: trimmedLine) {
                if attributes.contains("@MainActor"), declaresSerializedSuite(in: attributes) {
                    suiteNames.append(
                        SerializedMainActorSuite(
                            name: declaredTypeName,
                            enclosingTypeNames: enclosingTypes.map(\.name)
                        )
                    )
                }
                enclosingTypes.append((declaredTypeName, braceDepth))
            } else if let extensionName = declaredExtensionName(in: trimmedLine) {
                enclosingTypes.append((extensionName, braceDepth))
            }
            braceDepth += braceDelta(in: trimmedLine)
            popClosedEnclosingTypes(
                enclosingTypes: &enclosingTypes,
                braceDepth: braceDepth
            )
        }
        return suiteNames
    }

    private func popClosedEnclosingTypes(
        enclosingTypes: inout [(name: String, braceDepth: Int)],
        braceDepth: Int
    ) {
        while let last = enclosingTypes.last, braceDepth <= last.braceDepth {
            enclosingTypes.removeLast()
        }
    }

    private func braceDelta(in line: String) -> Int {
        line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }

    private func declaredExtensionName(in line: String) -> String? {
        guard let keywordRange = line.range(of: "extension ") else {
            return nil
        }
        let identifier = line[keywordRange.upperBound...]
            .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return identifier.isEmpty ? nil : String(identifier)
    }

    private func parenthesisDelta(in line: String) -> Int {
        line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
    }

    /// `.serialized` as a whole trait, never the `.serializedIfSupported` prefix.
    private func declaresSerializedSuite(in attributes: String) -> Bool {
        guard attributes.contains("@Suite") else { return false }
        var searchRange = attributes.startIndex..<attributes.endIndex
        while let traitRange = attributes.range(of: ".serialized", range: searchRange) {
            searchRange = traitRange.upperBound..<attributes.endIndex
            guard traitRange.upperBound < attributes.endIndex else { return true }
            let nextCharacter = attributes[traitRange.upperBound]
            if !nextCharacter.isLetter, !nextCharacter.isNumber, nextCharacter != "_" {
                return true
            }
        }
        return false
    }

    private func declaredTypeName(in line: String) -> String? {
        for keyword in ["struct ", "final class ", "class ", "actor ", "enum "] {
            guard let keywordRange = line.range(of: keyword) else { continue }
            let prefix = line[line.startIndex..<keywordRange.lowerBound]
            guard prefix.allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "(" || $0 == ")" }) else {
                continue
            }
            let identifier = line[keywordRange.upperBound...]
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return identifier.isEmpty ? nil : String(identifier)
        }
        return nil
    }

    private func declaresType(named typeName: String, in source: String) -> Bool {
        for keyword in ["struct", "class", "actor", "enum"] {
            var searchRange = source.startIndex..<source.endIndex
            while let range = source.range(of: "\(keyword) \(typeName)", range: searchRange) {
                searchRange = range.upperBound..<source.endIndex
                guard range.upperBound < source.endIndex else { return true }
                let nextCharacter = source[range.upperBound]
                if !nextCharacter.isLetter, !nextCharacter.isNumber, nextCharacter != "_" {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Shell helpers

    private struct HandKeptIsolationEntry {
        let sourcePath: String
        let suiteName: String
    }

    private struct LaneInventoryRow {
        let lane: String
        let suiteTypePath: String
        let mode: String
    }

    /// The `printf '%s:%s\n' 'path' 'Suite'` pairs a helper function hand-maintains.
    private func explicitSuitePathPairs(in functionBody: String) -> [HandKeptIsolationEntry] {
        var entries: [HandKeptIsolationEntry] = []
        let lines = functionBody.components(separatedBy: "\n")
        var lineIndex = 0
        while lineIndex < lines.count {
            guard lines[lineIndex].contains("printf '%s:%s") else {
                lineIndex += 1
                continue
            }
            let quotedArguments = (lineIndex + 1..<min(lineIndex + 3, lines.count))
                .compactMap { singleQuotedValue(in: lines[$0]) }
            if quotedArguments.count == 2 {
                entries.append(
                    HandKeptIsolationEntry(sourcePath: quotedArguments[0], suiteName: quotedArguments[1])
                )
            }
            lineIndex += 3
        }
        return entries
    }

    private func singleQuotedValue(in line: String) -> String? {
        guard let openingQuote = line.firstIndex(of: "'"),
            let closingQuote = line.lastIndex(of: "'"),
            openingQuote < closingQuote
        else {
            return nil
        }
        return String(line[line.index(after: openingQuote)..<closingQuote])
    }

    private func shellFunctionBody(named functionName: String, in script: String) throws -> String {
        let marker = "\(functionName)() {"
        guard let startRange = script.range(of: marker) else {
            throw SwiftLaneIsolationListGateError.missingShellFunction(functionName)
        }
        let tail = script[startRange.lowerBound...]
        guard let endRange = tail.range(of: "\n}\n") else {
            return String(tail)
        }
        return String(tail[..<endRange.lowerBound])
    }

    /// Runs one helper function and returns its printed lines.
    ///
    /// The subprocess wait goes through `withoutBlockingCooperativePool`: waiting
    /// on process exit from a test body parks a cooperative thread, which is the
    /// blocking rule this standard exists to enforce (spec R8).
    private func shellHelperLines(_ helperFunction: String) async throws -> Set<String> {
        let rendered = try await withoutBlockingCooperativePool {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c",
                "source scripts/swift-test-helpers.sh; \(helperFunction)",
            ]
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.standardOutput = output
            process.standardError = output

            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let rendered = String(bytes: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw SwiftLaneIsolationListGateError.shellHelperFailed(helperFunction, rendered)
            }
            return rendered
        }
        return Set(rendered.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }
}

private enum SwiftLaneIsolationListGateError: Error {
    case missingShellFunction(String)
    case shellHelperFailed(String, String)
    case malformedInventoryRow(String)
}
