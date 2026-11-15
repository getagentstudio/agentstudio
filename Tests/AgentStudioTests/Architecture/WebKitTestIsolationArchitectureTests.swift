import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("WebKitTestIsolationArchitectureTests")
struct WebKitTestIsolationArchitectureTests {
    private static let webKitRuntimeConstructors: [String] = [
        "WebPage(",
        "BridgePaneController(",
        "WebviewPaneController(",
        "WebviewTabPage(",
        "BridgePaneMountView(",
        "WebviewPaneMountView(",
        "createBridgePaneView(",
        "installBridgeControllerAndEnterForeground(",
    ]

    @Test("real WebKit runtime tests stay in the retry-isolated WebKit suite")
    func realWebKitRuntimeTestsStayInWebKitSerializedSuite() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let testsRoot = projectRoot.appending(path: "Tests/AgentStudioTests")
        let enumerator = FileManager.default.enumerator(
            at: testsRoot,
            includingPropertiesForKeys: nil
        )

        var nonIsolatedRuntimeTests: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                url.lastPathComponent.hasSuffix("Tests.swift")
            else {
                continue
            }

            let source = try String(contentsOf: url, encoding: .utf8)
            let createsRealWebKitRuntime = Self.webKitRuntimeConstructors.contains { constructor in
                source.contains(constructor)
            }
            guard createsRealWebKitRuntime else { continue }
            guard !source.contains("extension WebKitSerializedTests") else { continue }

            let relativePath = url.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
            nonIsolatedRuntimeTests.append(relativePath)
        }

        let sortedNonIsolatedRuntimeTests = nonIsolatedRuntimeTests.sorted()
        if !sortedNonIsolatedRuntimeTests.isEmpty {
            Issue.record(
                """
                Real WebKit runtime tests must be nested under WebKitSerializedTests:
                \(sortedNonIsolatedRuntimeTests.joined(separator: "\n"))
                """
            )
        }
        #expect(sortedNonIsolatedRuntimeTests.isEmpty)
    }
}
