import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test(arguments: [
        BridgePaneReviewBuildAttemptOutcome.failed, .cancelled, .stale, .streamReset, .succeeded,
    ])
    func comparisonWaitRejectsAttemptEndingBeforeArrival(_ outcome: BridgePaneReviewBuildAttemptOutcome) async throws {
        // Arrange: every producing-task outcome must close a comparison that was never reached.
        let events = BridgeProductWebKitReviewComparisonEvents()
        defer { events.finish() }
        let attempt = UUIDv7.generate()
        events.arm(1)
        events.record(.attempt(attempt), .admitted(attempt: attempt))
        events.record(.attempt(attempt), .attemptEnded(attempt: attempt, outcome: outcome))
        events.finish()

        // Act / Assert: source completion must win over a missing comparison, without waiting for a hang bound.
        await #expect(throws: BridgeProductWebKitComparisonWaitFailure.attemptEnded(attempt, outcome)) {
            _ = try await events.waitForBlockedComparisonCount(1)
        }
    }

    @Test(arguments: ["pane teardown started", "pageClosed", "webContentProcessTerminated"])
    func comparisonWaitRejectsRetirementBeforeArrival(_ reason: String) async throws {
        // Arrange
        let events = BridgeProductWebKitReviewComparisonEvents()
        defer { events.finish() }
        events.arm(1)
        events.retire(reason)
        events.finish()

        // Act / Assert
        await #expect(throws: BridgeProductWebKitComparisonWaitFailure.retired(reason)) {
            _ = try await events.waitForBlockedComparisonCount(1)
        }
    }
}
