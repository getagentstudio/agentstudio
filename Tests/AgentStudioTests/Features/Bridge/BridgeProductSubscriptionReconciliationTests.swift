import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product E3 resync reconciliation")
struct BridgeProductSubscriptionReconciliationTests {
    @Test("resync retains exact identity, reopens missing views, and revokes native-only subscriptions")
    func resyncReconcilesIdentityWithoutViewInterest() throws {
        var state = BridgeProductSubscriptionState()
        let file = try openRequest(id: "file-subscription-1", kind: .fileMetadata, epoch: 2)
        let review = try openRequest(id: "review-subscription-1", kind: .reviewMetadata, epoch: 7)
        _ = try state.open(file)
        _ = try state.open(review)
        let activeFile = try activeSubscription(id: "file-subscription-1", kind: .fileMetadata, epoch: 2)
        let missingReview = try activeSubscription(id: "review-subscription-missing", kind: .reviewMetadata, epoch: 7)

        let result = try state.reconcile(activeSubscriptions: [missingReview, activeFile])

        #expect(result.reconciliation.map(\.dispositionName) == ["reopenRequired", "retained"])
        #expect(result.reconciliation.map(\.subscriptionId) == ["review-subscription-missing", "file-subscription-1"])
        #expect(result.revokedNativeOnlySubscriptionIds == ["review-subscription-1"])
        #expect(state.snapshot(subscriptionId: "file-subscription-1")?.subscription == file.subscription)
        #expect(state.snapshot(subscriptionId: "review-subscription-1") == nil)
    }

    @Test("snapshot-required resync reopens the E3 identity for an E4 recapture")
    func snapshotRequiredReopensIdentity() throws {
        var state = BridgeProductSubscriptionState()
        _ = try state.open(openRequest(id: "file-subscription-1", kind: .fileMetadata, epoch: 2))
        let active = try activeSubscription(id: "file-subscription-1", kind: .fileMetadata, epoch: 2)

        let result = try state.reconcile(
            activeSubscriptions: [active],
            snapshotRequiredSubscriptionIds: ["file-subscription-1"]
        )

        guard case .reopenRequired(let reopen) = try #require(result.reconciliation.first) else {
            Issue.record("Expected a snapshot-required reopen")
            return
        }
        #expect(reopen.reason == .snapshotRequired)
        #expect(state.snapshot(subscriptionId: "file-subscription-1") == nil)
    }

    @Test("an epoch or kind mismatch reopens without mutating another subscription")
    func mismatchedIdentityReopensOnlyItsSubscription() throws {
        var state = BridgeProductSubscriptionState()
        _ = try state.open(openRequest(id: "file-subscription-1", kind: .fileMetadata, epoch: 2))
        _ = try state.open(openRequest(id: "review-subscription-1", kind: .reviewMetadata, epoch: 7))
        let changedFile = try activeSubscription(id: "file-subscription-1", kind: .fileMetadata, epoch: 3)
        let retainedReview = try activeSubscription(id: "review-subscription-1", kind: .reviewMetadata, epoch: 7)

        let result = try state.reconcile(activeSubscriptions: [changedFile, retainedReview])

        #expect(result.reconciliation.map(\.dispositionName) == ["reopenRequired", "retained"])
        #expect(state.snapshot(subscriptionId: "file-subscription-1") == nil)
        #expect(state.snapshot(subscriptionId: "review-subscription-1")?.workerDerivationEpoch == 7)
    }

    @Test("duplicate active identities fail before any E3 state changes")
    func duplicateActiveIdentityIsMutationFree() throws {
        var state = BridgeProductSubscriptionState()
        _ = try state.open(openRequest(id: "file-subscription-1", kind: .fileMetadata, epoch: 2))
        let before = state.snapshots()
        let active = try activeSubscription(id: "file-subscription-1", kind: .fileMetadata, epoch: 2)

        #expect(throws: BridgeProductSubscriptionStateError.duplicateSubscriptionId) {
            _ = try state.reconcile(activeSubscriptions: [active, active])
        }
        #expect(state.snapshots() == before)
    }

    private func activeSubscription(
        id: String,
        kind: BridgeProductSubscriptionKind,
        epoch: Int
    ) throws -> BridgeProductActiveSubscription {
        try decode(
            BridgeProductActiveSubscription.self,
            object: [
                "subscriptionId": id,
                "subscriptionKind": kind.rawValue,
                "workerDerivationEpoch": epoch,
            ])
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

    private func decode<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        object: [String: Any]
    ) throws -> DecodedValue {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try BridgeProductStrictJSON.decode(type, from: data)
    }
}
