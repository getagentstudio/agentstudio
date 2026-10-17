import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product E3 subscription state")
struct BridgeProductSessionSubscriptionTests {
    @Test("open owns identity while cancel validates kind and derivation epoch")
    func openAndCancelPreserveIdentityBoundaries() throws {
        var state = BridgeProductSubscriptionState()
        let open = try openRequest(id: "review-subscription-1", kind: .reviewMetadata, epoch: 7)
        let receipt = try state.open(open)
        let opened = try #require(state.snapshot(subscriptionId: receipt.subscriptionId))
        #expect(receipt.subscriptionKind == .reviewMetadata)
        #expect(receipt.workerDerivationEpoch == 7)
        #expect(opened.subscription == open.subscription)

        #expect(throws: BridgeProductSubscriptionStateError.subscriptionKindMismatch) {
            _ = try state.cancel(cancelRequest(id: receipt.subscriptionId, kind: .fileMetadata, epoch: 7))
        }
        #expect(throws: BridgeProductSubscriptionStateError.workerDerivationEpochMismatch) {
            _ = try state.cancel(cancelRequest(id: receipt.subscriptionId, kind: .reviewMetadata, epoch: 8))
        }
        #expect(state.snapshot(subscriptionId: receipt.subscriptionId) == opened)
        #expect(try state.cancel(cancelRequest(id: receipt.subscriptionId, kind: .reviewMetadata, epoch: 7)) == opened)
        #expect(state.snapshot(subscriptionId: receipt.subscriptionId) == nil)
        #expect(try state.cancel(cancelRequest(id: receipt.subscriptionId, kind: .reviewMetadata, epoch: 7)) == nil)
    }

    @Test("duplicate and capacity refusal leave the original E3 record intact")
    func duplicateAndCapacityAreMutationFree() throws {
        var state = BridgeProductSubscriptionState(maximumSubscriptionCount: 1)
        let first = try openRequest(id: "review-subscription-1", kind: .reviewMetadata, epoch: 7)
        _ = try state.open(first)
        let original = state.snapshots()
        #expect(throws: BridgeProductSubscriptionStateError.duplicateSubscriptionId) {
            _ = try state.open(first)
        }
        #expect(throws: BridgeProductSubscriptionStateError.subscriptionCapacityExceeded) {
            _ = try state.open(openRequest(id: "file-subscription-1", kind: .fileMetadata, epoch: 3))
        }
        #expect(state.snapshots() == original)
    }

    @Test("surface floor retirement reports only older matching subscriptions")
    func floorRetirementIsScoped() throws {
        var state = BridgeProductSubscriptionState()
        _ = try state.open(openRequest(id: "review-old", kind: .reviewMetadata, epoch: 7))
        _ = try state.open(openRequest(id: "review-current", kind: .reviewMetadata, epoch: 8))
        _ = try state.open(openRequest(id: "file-current", kind: .fileMetadata, epoch: 3))

        let retired = state.retireSubscriptions(on: .review, belowWorkerDerivationEpoch: 8)

        #expect(retired.map(\.subscriptionId) == ["review-old"])
        #expect(state.snapshots().map(\.subscriptionId) == ["file-current", "review-current"])
        state.revokeWorker()
        #expect(state.subscriptionCount == 0)
    }

    private func openRequest(
        id: String,
        kind: BridgeProductSubscriptionKind,
        epoch: Int
    ) throws -> BridgeProductSubscriptionOpenRequest {
        var subscription: [String: Any] = ["subscriptionKind": kind.rawValue]
        if kind == .fileMetadata {
            subscription["source"] = [
                "cwdScope": NSNull(),
                "freshness": "live",
                "includeStatuses": true,
                "repoId": "00000000-0000-4000-8000-000000000001",
                "rootPathToken": "root-token-1",
                "worktreeId": "00000000-0000-4000-8000-000000000002",
            ]
        }
        return try decode(
            BridgeProductSubscriptionOpenRequest.self,
            object: [
                "kind": "subscription.open",
                "paneSessionId": "pane-session-1",
                "requestId": "open:\(id)",
                "requestSequence": 1,
                "subscription": subscription,
                "subscriptionId": id,
                "wireVersion": BridgeProductWireContract.version,
                "workerDerivationEpoch": epoch,
                "workerInstanceId": "worker-instance-1",
            ])
    }

    private func cancelRequest(
        id: String,
        kind: BridgeProductSubscriptionKind,
        epoch: Int
    ) throws -> BridgeProductSubscriptionCancelRequest {
        try decode(
            BridgeProductSubscriptionCancelRequest.self,
            object: [
                "kind": "subscription.cancel",
                "paneSessionId": "pane-session-1",
                "requestId": "cancel:\(id)",
                "requestSequence": 2,
                "subscriptionId": id,
                "subscriptionKind": kind.rawValue,
                "wireVersion": BridgeProductWireContract.version,
                "workerDerivationEpoch": epoch,
                "workerInstanceId": "worker-instance-1",
            ])
    }

    private func decode<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        object: [String: Any]
    ) throws -> DecodedValue {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try BridgeProductStrictJSON.decode(type, from: data)
    }
}
