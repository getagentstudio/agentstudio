import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Review no-source contract")
struct BridgeReviewNoSourceContractTests {
    @Test("no-source attempt decodes and encodes the exact shared payload-free JSON value")
    func noSourceAttemptRoundTripsSharedFixture() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let fixtureBytes = try Data(
            contentsOf: projectRoot.appending(
                path: "Tests/BridgeContractFixtures/valid/bridge-product-review-comparison-attempt-no-source.json"
            )
        )
        let fixture = try #require(JSONSerialization.jsonObject(with: fixtureBytes) as? [String: String])
        #expect(fixture == ["status": "noSource"])

        let attempt = try BridgeProductStrictJSON.decode(BridgePaneReviewComparisonAttempt.self, from: fixtureBytes)
        #expect(attempt == .noSource)
        let encoded = try JSONEncoder().encode(BridgePaneReviewComparisonAttempt.noSource)
        let encodedObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(encodedObject == fixture)
        #expect(try BridgeProductStrictJSON.decode(BridgePaneReviewComparisonAttempt.self, from: encoded) == attempt)
    }

    @Test("no-source attempt rejects every payload field")
    func noSourceAttemptRejectsPayload() {
        for payload in [
            #"{"status":"noSource","reviewGeneration":0}"#,
            #"{"status":"noSource","failureKind":"missingRoot"}"#,
            #"{"status":"noSource","retryable":true}"#,
        ] {
            #expect(throws: (any Error).self) {
                _ = try BridgeProductStrictJSON.decode(BridgePaneReviewComparisonAttempt.self, from: Data(payload.utf8))
            }
        }
    }
}
