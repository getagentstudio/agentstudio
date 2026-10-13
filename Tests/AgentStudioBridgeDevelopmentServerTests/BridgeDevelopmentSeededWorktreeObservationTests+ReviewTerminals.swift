import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeDevelopmentSeededWorktreeObservationTests {
    @Test("Review terminal diagnostics persist when console output is unavailable")
    func reviewTerminalDiagnosticSurvivesUnavailableConsole() async throws {
        let diagnosticRoot = FileManager.default.temporaryDirectory.appending(path: "2026-10-tq56-diagnostics")
        try FileManager.default.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)
        let diagnosticFile = diagnosticRoot.appending(path: "\(UUIDv7.generate()).log")
        defer { try? FileManager.default.removeItem(at: diagnosticFile) }
        let recorder = SeededReviewLifecycleRecorder(
            diagnosticLog: HeldStepEventLog(path: diagnosticFile.path), emitConsoleDiagnostic: { _ in }
        )

        await recorder.record(
            seededReviewLifecycle(
                correlation: "silent-console-review", stage: .refreshOperationTerminal, result: .failure
            ))

        try #require(FileManager.default.fileExists(atPath: diagnosticFile.path))
        let diagnostic = try String(contentsOf: diagnosticFile, encoding: .utf8)
        #expect(
            diagnostic.hasPrefix(
                "TQ56 Review terminal: stage=refresh_operation_terminal result=failure correlation=silent-console-review\t"
            ))
        #expect(diagnostic.contains("\"clockDomain\":\"CLOCK_UPTIME_RAW\""))
        try await recorder.finish()
    }

    @Test("controllable deletion refresh commits the real Git deletion")
    func controllableDeletionRefreshCommitsRealGitDeletion() async throws {
        let fixture = try await captureControllableReviewPublications()
        #expect(fixture.baseline.package.itemsById.values.contains { $0.headPath == "tracked.txt" })
        #expect(
            fixture.deletion.package.itemsById.values.contains { $0.basePath == "tracked.txt" && $0.headPath == nil })
        #expect(fixture.deletion.operationCorrelationID != nil)
    }

    @Test("deletion observation rejects an earlier reservation's non-deletion commit")
    func deletionObservationRejectsEarlierReservation() async throws {
        try await exerciseSeededReviewOracleScenario(.earlierReservation)
    }

    @Test("stale predecessor terminal before successor announcement does not fail deletion")
    func deletionObservationAcceptsSuccessorAfterStaleTerminal() async throws {
        try await exerciseSeededReviewOracleScenario(.predecessorTerminal)
    }
}
