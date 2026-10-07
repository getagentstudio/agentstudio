import Foundation
import Testing

@Suite("Swift test failure scanner scripts")
struct SwiftTestFailureScannerScriptTests {
    @Test("facts verdict retains an early issue through a large event stream", arguments: [true, false])
    func earlyIssueSurvivesLargeEventStream(hasEarlyFailure: Bool) async throws {
        // Arrange
        let fixture = try InvocationReceiptFixture()
        defer { fixture.remove() }
        try writeCapturedInvocation(
            fixture, selecting: hasEarlyFailure ? "recordsFailure()" : "recordsPass()",
            extraRecords: 200_000)

        // Act
        let result = try await fixture.runEventFixture(as: "swift test", expectedRuns: 1, exitStatus: 0)

        // Assert
        #expect(result.record["command_status"] as? Int == 0)
        #expect(result.output.contains("STATUS=\(hasEarlyFailure ? 1 : 0)"), Comment(rawValue: result.output))
        #expect(result.output.contains("stream=complete"), Comment(rawValue: result.output))
        #expect(result.output.contains("unreadable_records=0"), Comment(rawValue: result.output))
        #expect(result.output.contains("failing_issues=\(hasEarlyFailure ? 1 : 0)"), Comment(rawValue: result.output))
        let failingName = "failing_test=AgentStudioTests.Xcode27EventStreamEvidenceScratchTests/recordsFailure()"
        #expect(result.output.contains(failingName) == hasEarlyFailure, Comment(rawValue: result.output))
        #expect(
            result.output.components(separatedBy: "lane-report failing_test=").count - 1 == (hasEarlyFailure ? 1 : 0))
    }
}
