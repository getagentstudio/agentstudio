import Foundation

enum BridgeProductSubscriptionStateError: Error, Equatable {
    case duplicateSubscriptionId
    case subscriptionCapacityExceeded
    case subscriptionKindMismatch
    case workerDerivationEpochMismatch
}

struct BridgeProductSubscriptionOpenReceipt: Equatable, Sendable {
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind
    let workerDerivationEpoch: Int
}

struct BridgeProductSubscriptionSnapshot: Equatable, Sendable {
    let subscription: BridgeProductSubscriptionRequest
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind
    let workerDerivationEpoch: Int
}

struct BridgeProductSubscriptionResyncResult: Equatable, Sendable {
    let reconciliation: [BridgeProductResyncReconciliationOutcome]
    let revokedNativeOnlySubscriptionIds: [String]

    static let empty = Self(reconciliation: [], revokedNativeOnlySubscriptionIds: [])
}

/// E3 owns subscription identity and lifetime. E4 owns changing view interest.
struct BridgeProductSubscriptionState: Sendable {
    private struct ExactUTF8Identity: Hashable, Sendable {
        let bytes: Data

        init(_ value: String) {
            bytes = Data(value.utf8)
        }
    }

    private struct SubscriptionRecord: Sendable {
        let subscription: BridgeProductSubscriptionRequest
        let subscriptionId: String
        let subscriptionKind: BridgeProductSubscriptionKind
        let workerDerivationEpoch: Int
    }

    private let maximumSubscriptionCount: Int
    private var recordsBySubscriptionId: [ExactUTF8Identity: SubscriptionRecord] = [:]

    init(maximumSubscriptionCount: Int = BridgeProductWireContract.maximumActiveSubscriptionCount) {
        precondition(maximumSubscriptionCount > 0)
        self.maximumSubscriptionCount = maximumSubscriptionCount
    }

    var subscriptionCount: Int { recordsBySubscriptionId.count }

    mutating func open(_ request: BridgeProductSubscriptionOpenRequest) throws -> BridgeProductSubscriptionOpenReceipt {
        let identity = ExactUTF8Identity(request.subscriptionId)
        guard recordsBySubscriptionId[identity] == nil else {
            throw BridgeProductSubscriptionStateError.duplicateSubscriptionId
        }
        guard recordsBySubscriptionId.count < maximumSubscriptionCount else {
            throw BridgeProductSubscriptionStateError.subscriptionCapacityExceeded
        }
        let record = SubscriptionRecord(
            subscription: request.subscription,
            subscriptionId: request.subscriptionId,
            subscriptionKind: request.subscription.subscriptionKind,
            workerDerivationEpoch: request.workerDerivationEpoch
        )
        recordsBySubscriptionId[identity] = record
        return .init(
            subscriptionId: record.subscriptionId,
            subscriptionKind: record.subscriptionKind,
            workerDerivationEpoch: record.workerDerivationEpoch
        )
    }

    func snapshot(subscriptionId: String) -> BridgeProductSubscriptionSnapshot? {
        recordsBySubscriptionId[ExactUTF8Identity(subscriptionId)].map(Self.snapshot)
    }

    func snapshots() -> [BridgeProductSubscriptionSnapshot] {
        let records: [SubscriptionRecord] = Array(recordsBySubscriptionId.values)
        return records.sorted(by: Self.hasEarlierSubscriptionID).map(Self.snapshot)
    }

    mutating func cancel(_ request: BridgeProductSubscriptionCancelRequest) throws -> BridgeProductSubscriptionSnapshot?
    {
        let identity = ExactUTF8Identity(request.subscriptionId)
        guard let record = recordsBySubscriptionId[identity] else { return nil }
        guard record.subscriptionKind == request.subscriptionKind else {
            throw BridgeProductSubscriptionStateError.subscriptionKindMismatch
        }
        guard record.workerDerivationEpoch == request.workerDerivationEpoch else {
            throw BridgeProductSubscriptionStateError.workerDerivationEpochMismatch
        }
        recordsBySubscriptionId.removeValue(forKey: identity)
        return Self.snapshot(record)
    }

    mutating func terminate(subscriptionId: String) {
        recordsBySubscriptionId.removeValue(forKey: ExactUTF8Identity(subscriptionId))
    }

    mutating func reconcile(
        activeSubscriptions: [BridgeProductActiveSubscription],
        snapshotRequiredSubscriptionIds: [String] = []
    ) throws -> BridgeProductSubscriptionResyncResult {
        let activeIdentities = activeSubscriptions.map { ExactUTF8Identity($0.subscriptionId) }
        guard Set(activeIdentities).count == activeIdentities.count else {
            throw BridgeProductSubscriptionStateError.duplicateSubscriptionId
        }
        guard activeSubscriptions.count <= maximumSubscriptionCount else {
            throw BridgeProductSubscriptionStateError.subscriptionCapacityExceeded
        }
        let activeIdentitySet = Set(activeIdentities)
        let snapshotRequiredIdentities = Set(snapshotRequiredSubscriptionIds.map(ExactUTF8Identity.init))
        let currentRecords: [SubscriptionRecord] = Array(recordsBySubscriptionId.values)
        let revokedNativeOnlySubscriptionIds: [String] =
            currentRecords
            .filter { record in
                !activeIdentitySet.contains(ExactUTF8Identity(record.subscriptionId))
            }
            .map { record in record.subscriptionId }
            .sorted(by: Self.hasEarlierExactUTF8)
        for subscriptionId in revokedNativeOnlySubscriptionIds {
            recordsBySubscriptionId.removeValue(forKey: ExactUTF8Identity(subscriptionId))
        }

        var reconciliation: [BridgeProductResyncReconciliationOutcome] = []
        for active in activeSubscriptions {
            let identity = ExactUTF8Identity(active.subscriptionId)
            guard let record = recordsBySubscriptionId[identity] else {
                reconciliation.append(
                    .reopenRequired(
                        try .init(
                            subscriptionId: active.subscriptionId,
                            subscriptionKind: active.subscriptionKind,
                            requiredWorkerDerivationEpoch: active.workerDerivationEpoch,
                            reason: .nativeMissing
                        )))
                continue
            }
            guard record.subscriptionKind == active.subscriptionKind,
                record.workerDerivationEpoch == active.workerDerivationEpoch
            else {
                recordsBySubscriptionId.removeValue(forKey: identity)
                reconciliation.append(
                    .reopenRequired(
                        try .init(
                            subscriptionId: active.subscriptionId,
                            subscriptionKind: active.subscriptionKind,
                            requiredWorkerDerivationEpoch: active.workerDerivationEpoch,
                            reason: record.subscriptionKind == active.subscriptionKind
                                ? .epochAdvanced : .identityMismatch
                        )))
                continue
            }
            if snapshotRequiredIdentities.contains(identity) {
                recordsBySubscriptionId.removeValue(forKey: identity)
                reconciliation.append(
                    .reopenRequired(
                        try .init(
                            subscriptionId: active.subscriptionId,
                            subscriptionKind: active.subscriptionKind,
                            requiredWorkerDerivationEpoch: active.workerDerivationEpoch,
                            reason: .snapshotRequired
                        )))
                continue
            }
            reconciliation.append(
                .retained(
                    try .init(
                        subscriptionId: record.subscriptionId,
                        subscriptionKind: record.subscriptionKind,
                        workerDerivationEpoch: record.workerDerivationEpoch
                    )))
        }
        return .init(
            reconciliation: reconciliation,
            revokedNativeOnlySubscriptionIds: revokedNativeOnlySubscriptionIds
        )
    }

    @discardableResult
    mutating func retireSubscriptions(
        on surface: BridgeProductSurface,
        belowWorkerDerivationEpoch workerDerivationEpoch: Int
    ) -> [BridgeProductSubscriptionSnapshot] {
        let currentRecords: [SubscriptionRecord] = Array(recordsBySubscriptionId.values)
        let retired: [SubscriptionRecord] =
            currentRecords
            .filter { record in
                record.subscriptionKind.surface == surface
                    && record.workerDerivationEpoch < workerDerivationEpoch
            }
            .sorted(by: Self.hasEarlierSubscriptionID)
        for record in retired {
            recordsBySubscriptionId.removeValue(forKey: ExactUTF8Identity(record.subscriptionId))
        }
        return retired.map(Self.snapshot)
    }

    mutating func revokeWorker() {
        recordsBySubscriptionId.removeAll(keepingCapacity: false)
    }

    private static func snapshot(_ record: SubscriptionRecord) -> BridgeProductSubscriptionSnapshot {
        .init(
            subscription: record.subscription,
            subscriptionId: record.subscriptionId,
            subscriptionKind: record.subscriptionKind,
            workerDerivationEpoch: record.workerDerivationEpoch
        )
    }

    private static func hasEarlierSubscriptionID(
        _ left: SubscriptionRecord,
        _ right: SubscriptionRecord
    ) -> Bool {
        hasEarlierExactUTF8(left.subscriptionId, right.subscriptionId)
    }

    private static func hasEarlierExactUTF8(_ left: String, _ right: String) -> Bool {
        Data(left.utf8).lexicographicallyPrecedes(Data(right.utf8))
    }
}
