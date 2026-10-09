import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File refresh failure classification")
struct BridgeFileRefreshFailureClassificationTests {
    private struct ExpectedRootFailureClassification {
        let error: BridgeWorktreeFileRootAccessError
        let fixtureCaseName: String
        let cause: BridgeFileSurfaceReconciler.FailureCause
        let disposition: BridgeFileSurfaceReconciler.FailureDisposition
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

    @Test("typed root failures encode the shared page-decodable failure cases")
    func typedRootFailuresEncodeSharedWireValues() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let corpusData = try Data(
            contentsOf: projectRoot.appending(
                path: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
            )
        )
        let corpus = try #require(JSONSerialization.jsonObject(with: corpusData) as? [String: Any])
        let sharedCases = try #require(corpus["fileRefreshFailureCases"] as? [[String: Any]])
        let cases: [ExpectedRootFailureClassification] = [
            .init(
                error: .missingRoot,
                fixtureCaseName: "missingRoot",
                cause: .missingRoot,
                disposition: .retryable
            ),
            .init(
                error: .unreadable,
                fixtureCaseName: "unreadable",
                cause: .unreadableRoot,
                disposition: .retryable
            ),
            .init(
                error: .refused,
                fixtureCaseName: "refused",
                cause: .accessRefused,
                disposition: .permanent
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
                Issue.record("Expected root access failure to use its File failure wire value")
                continue
            }
            guard
                let sharedCase = sharedCases.first(
                    where: { $0["rootAccessFailure"] as? String == expected.fixtureCaseName }
                ),
                let expectedFailure = sharedCase["failure"] as? [String: Any]
            else {
                Issue.record("Expected a shared File failure case for \(expected.fixtureCaseName)")
                continue
            }
            let expectedKind = try #require(expectedFailure["failureKind"] as? String)
            let expectedRetryable = try #require(expectedFailure["retryable"] as? Bool)
            #expect(wireFailure.failureKind.rawValue == expectedKind)
            #expect(wireFailure.retryable == expectedRetryable)
            #expect(wireFailure.retryable == (expected.disposition == .retryable))

            let encodedJSON = try #require(String(data: encoder.encode(wireFailure), encoding: .utf8))
            let expectedJSONData = try JSONSerialization.data(
                withJSONObject: expectedFailure,
                options: [.sortedKeys]
            )
            let expectedJSON = try #require(String(data: expectedJSONData, encoding: .utf8))
            #expect(encodedJSON == expectedJSON)
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

    @Test("unknown File changeset publication failures keep the permanent disposition")
    func unknownChangesetPublicationFailureKeepsPermanentDisposition() {
        let disposition = BridgePaneProductMetadataCoordinator.fileRefreshDisposition(
            for: UnknownChangesetPublicationFailure.injected
        )

        guard case .failed(let failure) = disposition else {
            Issue.record("Expected unknown changeset publication failure to retain a File failure")
            return
        }
        #expect(failure == .init(failureKind: .fileRefreshFailed))
        #expect(!failure.retryable)
    }

    @Test("current File cancellation and construction invalidation stay retryable")
    func currentCancellationAndConstructionInvalidationStayRetryable() {
        let errors: [any Error] = [
            CancellationError(),
            BridgeWorktreeProductConstructionError.invalidated,
        ]
        for error in errors {
            #expect(
                BridgePaneProductMetadataCoordinator.fileRefreshDisposition(for: error)
                    == .failed(.init(failureKind: .fileSourceUnavailable))
            )
        }
    }

    private enum UnknownChangesetPublicationFailure: Error {
        case injected
    }
}
