import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product resync response contract")
struct BridgeProductResyncResponseContractTests {
    @Test("resync response carries ordered retained cancelled and reopen outcomes")
    func decodesEveryClosedReconciliationOutcome() throws {
        let response = try decode(
            BridgeProductControlResponse.self,
            object: responseObject(reconciliation: [
                outcome(disposition: "retained", subscriptionId: "review-retained"),
                outcome(
                    disposition: "cancelled",
                    subscriptionId: "review-cancelled",
                    extras: [
                        "priorWorkerDerivationEpoch": 7,
                        "reason": "native_revoked",
                    ]
                ),
                outcome(
                    disposition: "reopenRequired",
                    subscriptionId: "file-reopen",
                    extras: [
                        "reason": "native_missing",
                        "requiredWorkerDerivationEpoch": 3,
                    ]
                ),
            ])
        )

        guard case .resyncAccepted(let accepted) = response else {
            Issue.record("Expected resync.accepted")
            return
        }
        #expect(accepted.metadataStreamSequenceBarrier == 15)
        #expect(accepted.reconciliation.count == 3)
        #expect(
            accepted.reconciliation.map(\.dispositionName) == [
                "retained", "cancelled", "reopenRequired",
            ])
    }

    @Test("resync response rejects unknown outcomes and more than 64 entries")
    func rejectsOpenOrUnboundedReconciliation() throws {
        var unknown = outcome(disposition: "retained", subscriptionId: "review-retained")
        unknown["disposition"] = "silentlyIgnored"
        #expect(throws: (any Error).self) {
            _ = try decode(
                BridgeProductControlResponse.self,
                object: responseObject(reconciliation: [unknown])
            )
        }

        let oversized = (0...BridgeProductWireContract.maximumActiveSubscriptionCount).map {
            outcome(disposition: "retained", subscriptionId: "review-\($0)")
        }
        #expect(throws: (any Error).self) {
            _ = try decode(
                BridgeProductControlResponse.self,
                object: responseObject(reconciliation: oversized)
            )
        }
    }

    private func outcome(
        disposition: String,
        subscriptionId: String,
        extras: [String: Any] = [:]
    ) -> [String: Any] {
        let identity: [String: Any] = [
            "disposition": disposition,
            "subscriptionId": subscriptionId,
            "subscriptionKind": subscriptionId.hasPrefix("file")
                ? "file.metadata"
                : "review.metadata",
        ]
        let dispositionFields: [String: Any]
        switch disposition {
        case "retained":
            dispositionFields = [
                "workerDerivationEpoch": subscriptionId.hasPrefix("file") ? 3 : 7
            ]
        case "cancelled", "reopenRequired":
            dispositionFields = [:]
        default:
            dispositionFields = [:]
        }
        return
            identity
            .merging(dispositionFields) { _, replacement in replacement }
            .merging(extras) { _, replacement in replacement }
    }

    private func responseObject(reconciliation: [[String: Any]]) -> [String: Any] {
        [
            "kind": "resync.accepted",
            "metadataStreamSequenceBarrier": 15,
            "nextExpectedRequestSequence": 10,
            "paneSessionId": "pane-session-1",
            "reconciliation": reconciliation,
            "requestId": "resync-request-1",
            "requestSequence": 9,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ]
    }

    private func decode<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        object: [String: Any]
    ) throws -> DecodedValue {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try BridgeProductStrictJSON.decode(type, from: data)
    }
}
