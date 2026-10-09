import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product E3 subscription identity")
struct BridgeProductSubscriptionRollingHistoryTests {
    @Test("case-distinct valid subscription IDs remain distinct")
    func exactUTF8SubscriptionIdsStayDistinct() throws {
        let uppercaseID = "review-A"
        let lowercaseID = "review-a"
        var state = BridgeProductSubscriptionState(maximumSubscriptionCount: 2)
        _ = try state.open(openRequest(id: uppercaseID))
        _ = try state.open(openRequest(id: lowercaseID))

        #expect(Data(uppercaseID.utf8) != Data(lowercaseID.utf8))
        #expect(state.subscriptionCount == 2)
        #expect(state.snapshot(subscriptionId: uppercaseID)?.subscriptionId == uppercaseID)
        #expect(state.snapshot(subscriptionId: lowercaseID)?.subscriptionId == lowercaseID)
        _ = try state.cancel(cancelRequest(id: uppercaseID))
        #expect(state.snapshot(subscriptionId: uppercaseID) == nil)
        #expect(state.snapshot(subscriptionId: lowercaseID) != nil)
    }

    @Test("many E3 open and cancel cycles leave no retained update history")
    func subscriptionChurnKeepsOnlyLiveIdentity() throws {
        var state = BridgeProductSubscriptionState(maximumSubscriptionCount: 1)
        for index in 0..<1100 {
            let id = "rolling-review-\(index)"
            _ = try state.open(openRequest(id: id))
            #expect(state.subscriptionCount == 1)
            #expect(state.snapshot(subscriptionId: id) != nil)
            _ = try state.cancel(cancelRequest(id: id))
            #expect(state.subscriptionCount == 0)
        }
    }

    @Test("a copied candidate may retire without mutating its parent")
    func candidateStateIsValueIsolated() throws {
        var parent = BridgeProductSubscriptionState(maximumSubscriptionCount: 2)
        _ = try parent.open(openRequest(id: "review-a"))
        var candidate = parent
        _ = try candidate.open(openRequest(id: "review-b"))
        candidate.terminate(subscriptionId: "review-a")

        #expect(parent.snapshots().map(\.subscriptionId) == ["review-a"])
        #expect(candidate.snapshots().map(\.subscriptionId) == ["review-b"])
    }

    private func openRequest(id: String) throws -> BridgeProductSubscriptionOpenRequest {
        try decode(
            BridgeProductSubscriptionOpenRequest.self,
            object: [
                "kind": "subscription.open",
                "wireVersion": BridgeProductWireContract.version,
                "paneSessionId": "rolling-pane",
                "workerInstanceId": "rolling-worker",
                "workerDerivationEpoch": 1,
                "requestId": "open-\(id)",
                "requestSequence": 1,
                "subscriptionId": id,
                "subscription": ["subscriptionKind": "review.metadata"],
            ])
    }

    private func cancelRequest(id: String) throws -> BridgeProductSubscriptionCancelRequest {
        try decode(
            BridgeProductSubscriptionCancelRequest.self,
            object: [
                "kind": "subscription.cancel",
                "wireVersion": BridgeProductWireContract.version,
                "paneSessionId": "rolling-pane",
                "workerInstanceId": "rolling-worker",
                "workerDerivationEpoch": 1,
                "requestId": "cancel-\(id)",
                "requestSequence": 2,
                "subscriptionId": id,
                "subscriptionKind": "review.metadata",
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
