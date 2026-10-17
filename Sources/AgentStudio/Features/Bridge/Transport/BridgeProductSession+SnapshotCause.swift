import Foundation

extension BridgeProductSession {
    func viewSnapshotRequired(subscriptionId: String) -> Bool {
        viewScopeByDomain.keys.contains { domain in
            guard domain.viewId == subscriptionId else { return false }
            if case .snapshotRequired = viewSenderState.pending(for: domain) { return true }
            return false
        }
    }

    func requireViewRecoverySnapshot(subscriptionId: String) {
        for domain in viewScopeByDomain.keys where domain.viewId == subscriptionId {
            viewSenderState.resnapshot(domain, cause: .recovery)
            pendingFileSnapshotByViewDomain.removeValue(forKey: domain)
            lastSealedFileTargetByViewDomain.removeValue(forKey: domain)
            pendingReviewSnapshotByViewDomain.removeValue(forKey: domain)
            finishViewEmissionWaiter(for: domain, outcome: .resnapshotRequired)
        }
        rescheduleViewAcknowledgementDeadline()
    }

}
