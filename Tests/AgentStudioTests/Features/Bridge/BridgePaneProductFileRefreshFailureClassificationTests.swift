import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File refresh failure classification")
struct BridgeFileRefreshFailureClassificationTests {
    private struct ExpectedRootFailureClassification {
        let error: BridgeWorktreeFileRootAccessError
        let cause: BridgeFileSurfaceReconciler.FailureCause
        let disposition: BridgeFileSurfaceReconciler.FailureDisposition
        let wireKind: BridgePaneProductFileRefreshFailureKind
        let wireJSON: String
    }

    @Test("every closed failure kind round-trips with derived retryability")
    func everyFailureKindRoundTrips() throws {
        for failureKind in BridgePaneProductFileRefreshFailureKind.allCases {
            let failure = BridgePaneProductFileRefreshFailure(failureKind: failureKind)
            let encoded = try JSONEncoder().encode(failure)

            #expect(try JSONDecoder().decode(BridgePaneProductFileRefreshFailure.self, from: encoded) == failure)
            #expect(failure.retryable == failureKind.retryable)
        }
    }

    @Test("typed root failures preserve their cause and encode the existing wire value")
    func typedRootFailuresUseExistingWireValues() throws {
        let cases: [ExpectedRootFailureClassification] = [
            .init(
                error: .missingRoot,
                cause: .missingRoot,
                disposition: .retryable,
                wireKind: .fileSourceUnavailable,
                wireJSON: #"{"failureKind":"fileSourceUnavailable","retryable":true}"#
            ),
            .init(
                error: .unreadable,
                cause: .unreadableRoot,
                disposition: .retryable,
                wireKind: .fileSourceUnavailable,
                wireJSON: #"{"failureKind":"fileSourceUnavailable","retryable":true}"#
            ),
            .init(
                error: .refused,
                cause: .accessRefused,
                disposition: .permanent,
                wireKind: .producerRejected,
                wireJSON: #"{"failureKind":"producerRejected","retryable":false}"#
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for expected in cases {
            let classification = BridgeFileSurfaceReconciler.failure(for: expected.error, phase: .build)
            #expect(classification.cause == expected.cause)
            #expect(classification.disposition == expected.disposition)

            guard
                case .failed(let wireFailure) =
                    BridgePaneProductMetadataCoordinator.fileRefreshDisposition(for: expected.error)
            else {
                Issue.record("Expected root access failure to use the existing File failure wire shape")
                continue
            }
            #expect(wireFailure == classification.refreshFailure)
            #expect(wireFailure.failureKind == expected.wireKind)
            #expect(wireFailure.retryable == (expected.disposition == .retryable))
            let encodedJSON = try #require(String(data: encoder.encode(wireFailure), encoding: .utf8))
            #expect(encodedJSON == expected.wireJSON)
        }
    }

    @Test("invalid retryability and unknown members fail closed")
    func invalidWireFailuresFailClosed() {
        for json in [
            #"{"failureKind":"fileSourceUnavailable","retryable":false}"#,
            #"{"failureKind":"fileRefreshFailed","retryable":false,"unknown":1}"#,
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(
                    BridgePaneProductFileRefreshFailure.self,
                    from: Data(json.utf8)
                )
            }
        }
    }

    @Test("producer queue reset requires stream replacement without spending File retry")
    func producerQueueResetRequiresStreamReplacement() {
        #expect(
            BridgePaneProductMetadataCoordinator.fileRefreshDisposition(
                for: BridgePaneProductMetadataCoordinatorError.producerQueueReset
            ) == .streamResetRequired
        )
    }

    @Test("foreground invalidation is stale instead of failed")
    func foregroundInvalidationIsStale() {
        #expect(
            BridgePaneProductMetadataCoordinator.fileRefreshDisposition(
                for: BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
            ) == .stale
        )
    }

    @Test("temporary File source failure is retryable")
    func temporaryFileSourceFailureIsRetryable() {
        #expect(
            BridgePaneProductMetadataCoordinator.fileRefreshDisposition(
                for: BridgePaneProductFileMetadataSourceError.unavailableAuthority
            )
                == .failed(
                    .init(failureKind: .fileSourceUnavailable)
                )
        )
    }
}
