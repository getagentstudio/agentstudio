import Foundation

enum BridgeProductResyncCancellationReason: String, Codable, Equatable, Sendable {
    case nativeRevoked = "native_revoked"
    case sourceUnavailable = "source_unavailable"
}

enum BridgeProductResyncReopenReason: String, Codable, Equatable, Sendable {
    case epochAdvanced = "epoch_advanced"
    case identityMismatch = "identity_mismatch"
    case nativeMissing = "native_missing"
    case snapshotRequired = "snapshot_required"
}

private struct BridgeProductResyncSubscriptionIdentity: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case subscriptionId
        case subscriptionKind
    }

    static let codingKeyNames = Set(CodingKeys.allCases.map(\.rawValue))

    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind

    init(subscriptionId: String, subscriptionKind: BridgeProductSubscriptionKind) throws {
        self.subscriptionId = subscriptionId
        self.subscriptionKind = subscriptionKind
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: [])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.subscriptionKind = try container.decode(
            BridgeProductSubscriptionKind.self,
            forKey: .subscriptionKind
        )
        try BridgeProductContractDecoding.validateIdentifier(
            subscriptionId,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
    }
}

struct BridgeProductResyncRetainedOutcome: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case disposition
        case workerDerivationEpoch
    }

    private let identity: BridgeProductResyncSubscriptionIdentity
    let workerDerivationEpoch: Int

    var subscriptionId: String { identity.subscriptionId }
    var subscriptionKind: BridgeProductSubscriptionKind { identity.subscriptionKind }

    init(
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind,
        workerDerivationEpoch: Int
    ) throws {
        self.identity = try .init(
            subscriptionId: subscriptionId,
            subscriptionKind: subscriptionKind
        )
        self.workerDerivationEpoch = workerDerivationEpoch
        try validate(codingPath: [])
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductResyncSubscriptionIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "retained Bridge product resync outcome"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .disposition) == "retained" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid retained Bridge product resync disposition",
                codingPath: decoder.codingPath
            )
        }
        self.identity = try BridgeProductResyncSubscriptionIdentity(from: decoder)
        self.workerDerivationEpoch = try container.decode(Int.self, forKey: .workerDerivationEpoch)
        try validate(codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("retained", forKey: .disposition)
        try container.encode(workerDerivationEpoch, forKey: .workerDerivationEpoch)
    }

    private func validate(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validateNonnegative(
            workerDerivationEpoch,
            name: "workerDerivationEpoch",
            codingPath: codingPath
        )
    }
}

struct BridgeProductResyncCancelledOutcome: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case disposition
        case priorWorkerDerivationEpoch
        case reason
    }

    private let identity: BridgeProductResyncSubscriptionIdentity
    let priorWorkerDerivationEpoch: Int
    let reason: BridgeProductResyncCancellationReason

    var subscriptionId: String { identity.subscriptionId }
    var subscriptionKind: BridgeProductSubscriptionKind { identity.subscriptionKind }

    init(
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind,
        priorWorkerDerivationEpoch: Int,
        reason: BridgeProductResyncCancellationReason
    ) throws {
        self.identity = try .init(
            subscriptionId: subscriptionId,
            subscriptionKind: subscriptionKind
        )
        self.priorWorkerDerivationEpoch = priorWorkerDerivationEpoch
        self.reason = reason
        try BridgeProductContractDecoding.validateNonnegative(
            priorWorkerDerivationEpoch,
            name: "priorWorkerDerivationEpoch",
            codingPath: []
        )
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductResyncSubscriptionIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "cancelled Bridge product resync outcome"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .disposition) == "cancelled" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid cancelled Bridge product resync disposition",
                codingPath: decoder.codingPath
            )
        }
        self.identity = try BridgeProductResyncSubscriptionIdentity(from: decoder)
        self.priorWorkerDerivationEpoch = try container.decode(
            Int.self,
            forKey: .priorWorkerDerivationEpoch
        )
        self.reason = try container.decode(
            BridgeProductResyncCancellationReason.self,
            forKey: .reason
        )
        try BridgeProductContractDecoding.validateNonnegative(
            priorWorkerDerivationEpoch,
            name: "priorWorkerDerivationEpoch",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("cancelled", forKey: .disposition)
        try container.encode(priorWorkerDerivationEpoch, forKey: .priorWorkerDerivationEpoch)
        try container.encode(reason, forKey: .reason)
    }
}

struct BridgeProductResyncReopenRequiredOutcome: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case disposition
        case reason
        case requiredWorkerDerivationEpoch
    }

    private let identity: BridgeProductResyncSubscriptionIdentity
    let reason: BridgeProductResyncReopenReason
    let requiredWorkerDerivationEpoch: Int

    var subscriptionId: String { identity.subscriptionId }
    var subscriptionKind: BridgeProductSubscriptionKind { identity.subscriptionKind }

    init(
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind,
        requiredWorkerDerivationEpoch: Int,
        reason: BridgeProductResyncReopenReason
    ) throws {
        self.identity = try .init(
            subscriptionId: subscriptionId,
            subscriptionKind: subscriptionKind
        )
        self.requiredWorkerDerivationEpoch = requiredWorkerDerivationEpoch
        self.reason = reason
        try BridgeProductContractDecoding.validateNonnegative(
            requiredWorkerDerivationEpoch,
            name: "requiredWorkerDerivationEpoch",
            codingPath: []
        )
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductResyncSubscriptionIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "reopen-required Bridge product resync outcome"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .disposition) == "reopenRequired" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid reopen-required Bridge product resync disposition",
                codingPath: decoder.codingPath
            )
        }
        self.identity = try BridgeProductResyncSubscriptionIdentity(from: decoder)
        self.requiredWorkerDerivationEpoch = try container.decode(
            Int.self,
            forKey: .requiredWorkerDerivationEpoch
        )
        self.reason = try container.decode(BridgeProductResyncReopenReason.self, forKey: .reason)
        try BridgeProductContractDecoding.validateNonnegative(
            requiredWorkerDerivationEpoch,
            name: "requiredWorkerDerivationEpoch",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("reopenRequired", forKey: .disposition)
        try container.encode(reason, forKey: .reason)
        try container.encode(requiredWorkerDerivationEpoch, forKey: .requiredWorkerDerivationEpoch)
    }
}

enum BridgeProductResyncReconciliationOutcome: Codable, Equatable, Sendable {
    case retained(BridgeProductResyncRetainedOutcome)
    case cancelled(BridgeProductResyncCancelledOutcome)
    case reopenRequired(BridgeProductResyncReopenRequiredOutcome)

    private enum CodingKeys: String, CodingKey {
        case disposition
    }

    var dispositionName: String {
        switch self {
        case .retained: "retained"
        case .cancelled: "cancelled"
        case .reopenRequired: "reopenRequired"
        }
    }

    var subscriptionId: String {
        switch self {
        case .retained(let outcome): outcome.subscriptionId
        case .cancelled(let outcome): outcome.subscriptionId
        case .reopenRequired(let outcome): outcome.subscriptionId
        }
    }

    var subscriptionKind: BridgeProductSubscriptionKind {
        switch self {
        case .retained(let outcome): outcome.subscriptionKind
        case .cancelled(let outcome): outcome.subscriptionKind
        case .reopenRequired(let outcome): outcome.subscriptionKind
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .disposition) {
        case "retained": self = .retained(try .init(from: decoder))
        case "cancelled": self = .cancelled(try .init(from: decoder))
        case "reopenRequired": self = .reopenRequired(try .init(from: decoder))
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Unknown Bridge product resync reconciliation disposition",
                codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .retained(let outcome): try outcome.encode(to: encoder)
        case .cancelled(let outcome): try outcome.encode(to: encoder)
        case .reopenRequired(let outcome): try outcome.encode(to: encoder)
        }
    }
}
