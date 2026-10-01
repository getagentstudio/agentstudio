import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File refresh failure values")
struct BridgePaneProductFileRefreshFailureTests {
    private struct ExpectedWireFailure {
        let failureKind: BridgePaneProductFileRefreshFailureKind
        let retryable: Bool
        let json: String
    }

    @Test("File refresh failures retain the existing closed wire values")
    func fileRefreshFailuresRetainExistingWireValues() throws {
        let cases: [ExpectedWireFailure] = [
            .init(
                failureKind: .fileRefreshFailed,
                retryable: false,
                json: #"{"failureKind":"fileRefreshFailed","retryable":false}"#
            ),
            .init(
                failureKind: .fileSourceUnavailable,
                retryable: true,
                json: #"{"failureKind":"fileSourceUnavailable","retryable":true}"#
            ),
            .init(
                failureKind: .producerRejected,
                retryable: false,
                json: #"{"failureKind":"producerRejected","retryable":false}"#
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for expected in cases {
            let failure = BridgePaneProductFileRefreshFailure(failureKind: expected.failureKind)
            #expect(failure.retryable == expected.retryable)
            let encoded = try encoder.encode(failure)
            let encodedJSON = try #require(String(data: encoded, encoding: .utf8))
            #expect(encodedJSON == expected.json)
            #expect(try JSONDecoder().decode(BridgePaneProductFileRefreshFailure.self, from: encoded) == failure)
        }
    }

    @Test("decoder rejects deferred root-specific wire kinds and copy fields")
    func decoderRejectsDeferredRootSpecificWireValues() {
        for json in [
            #"{"failureKind":"missingRoot","retryable":true}"#,
            #"{"failureKind":"unreadable","retryable":true}"#,
            #"{"failureKind":"refused","retryable":false}"#,
            #"{"failureKind":"fileSourceUnavailable","retryable":true,"safeMessage":"provider path leaked"}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(BridgePaneProductFileRefreshFailure.self, from: Data(json.utf8))
            }
        }
    }
}
