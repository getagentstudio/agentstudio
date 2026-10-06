import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Swift test failure scanner scripts")
struct SwiftTestFailureScannerScriptTests {
    @Test("Swift failure scanner handles large output with and without an early failure", arguments: [true, false])
    func swiftFailureScannerHandlesLargeOutput(hasEarlyFailure: Bool) async throws {
        // Arrange
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "ci-failure-scanner-\(UUIDv7.generate().uuidString).log")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let failureLine =
            hasEarlyFailure
            ? "✘ Test \"x\" recorded an issue at A.swift:1:1: Expectation failed\n" : ""
        let benignOutput = String(
            repeating: "✔ Test \"ok\" passed after 0.001 seconds.\n",
            count: 200_000
        )
        try (failureLine + benignOutput).write(to: outputURL, atomically: true, encoding: .utf8)
        let quotedOutputPath = "'" + outputURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"

        // Act
        let scannerStatus = try await runBashStatus(
            "source scripts/swift-test-helpers.sh; "
                + "swift_test_output_has_failures \(quotedOutputPath)"
        )

        // Assert
        let expectedStatus: Int32 = hasEarlyFailure ? 0 : 1
        #expect(scannerStatus == expectedStatus)
    }
}

private func runBashStatus(_ command: String) async throws -> Int32 {
    try await withoutBlockingCooperativePool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
