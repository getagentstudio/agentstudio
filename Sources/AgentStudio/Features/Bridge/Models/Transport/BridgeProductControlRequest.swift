import Foundation

private typealias BridgeProductPaneControlRequestIdentity = BridgeProductControlCorrelation
private typealias BridgeProductSurfaceControlRequestIdentity = BridgeProductSurfaceRequestIdentity

enum BridgeProductControlRequest: Codable, Equatable, Sendable {
    case workerSessionOpen(BridgeProductWorkerSessionOpenRequest)
    case productCall(BridgeProductCallControlRequest)
    case subscriptionOpen(BridgeProductSubscriptionOpenRequest)
    case subscriptionCancel(BridgeProductSubscriptionCancelRequest)
    case viewScope(BridgeProductViewScopeRequest)
    case viewResnapshot(BridgeProductViewResnapshotRequest)
    case workerSessionResync(BridgeProductWorkerSessionResyncRequest)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    var kind: String {
        switch self {
        case .workerSessionOpen: "workerSession.open"
        case .productCall: "product.call"
        case .subscriptionOpen: "subscription.open"
        case .subscriptionCancel: "subscription.cancel"
        case .viewScope: "subscription.setScope"
        case .viewResnapshot: "subscription.resnapshot"
        case .workerSessionResync: "workerSession.resync"
        }
    }

    var isSlotFreeEscape: Bool {
        if case .subscriptionCancel = self { return true }
        return false
    }

    var correlation: BridgeProductControlCorrelation {
        switch self {
        case .workerSessionOpen(let request): request.correlation
        case .productCall(let request): request.correlation
        case .subscriptionOpen(let request): request.correlation
        case .subscriptionCancel(let request): request.correlation
        case .viewScope(let request): request.correlation
        case .viewResnapshot(let request): request.correlation
        case .workerSessionResync(let request): request.correlation
        }
    }

    var paneSessionId: String { correlation.paneSessionId }
    var requestId: String { correlation.requestId }
    var requestSequence: Int { correlation.requestSequence }
    var workerInstanceId: String { correlation.workerInstanceId }

    var viewControlSubscription: (id: String, kind: BridgeProductSubscriptionKind)? {
        switch self {
        case .viewScope(let request):
            (request.subscriptionId, request.subscriptionKind)
        case .viewResnapshot(let request):
            (request.subscriptionId, request.subscriptionKind)
        default:
            nil
        }
    }

    var surface: BridgeProductSurface? {
        switch self {
        case .workerSessionOpen, .workerSessionResync:
            nil
        case .productCall(let request):
            request.surface
        case .subscriptionOpen(let request):
            request.surface
        case .subscriptionCancel(let request):
            request.surface
        case .viewScope(let request):
            request.subscriptionKind.surface
        case .viewResnapshot(let request):
            request.subscriptionKind.surface
        }
    }

    var workerDerivationEpoch: Int? {
        switch self {
        case .workerSessionOpen, .workerSessionResync:
            nil
        case .productCall(let request):
            request.workerDerivationEpoch
        case .subscriptionOpen(let request):
            request.workerDerivationEpoch
        case .subscriptionCancel(let request):
            request.workerDerivationEpoch
        case .viewScope, .viewResnapshot:
            nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "workerSession.open":
            self = .workerSessionOpen(try BridgeProductWorkerSessionOpenRequest(from: decoder))
        case "product.call":
            self = .productCall(try BridgeProductCallControlRequest(from: decoder))
        case "subscription.open":
            self = .subscriptionOpen(try BridgeProductSubscriptionOpenRequest(from: decoder))
        case "subscription.cancel":
            self = .subscriptionCancel(try BridgeProductSubscriptionCancelRequest(from: decoder))
        case "subscription.setScope":
            self = .viewScope(try BridgeProductViewScopeRequest(from: decoder))
        case "subscription.resnapshot":
            self = .viewResnapshot(try BridgeProductViewResnapshotRequest(from: decoder))
        case "workerSession.resync":
            self = .workerSessionResync(try BridgeProductWorkerSessionResyncRequest(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown Bridge product control request kind"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .workerSessionOpen(let request): try request.encode(to: encoder)
        case .productCall(let request): try request.encode(to: encoder)
        case .subscriptionOpen(let request): try request.encode(to: encoder)
        case .subscriptionCancel(let request): try request.encode(to: encoder)
        case .viewScope(let request): try request.encode(to: encoder)
        case .viewResnapshot(let request): try request.encode(to: encoder)
        case .workerSessionResync(let request): try request.encode(to: encoder)
        }
    }
}

struct BridgeProductWorkerSessionOpenRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case request
    }

    private let identity: BridgeProductPaneControlRequestIdentity

    var correlation: BridgeProductControlCorrelation { identity }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductPaneControlRequestIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "workerSession.open request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "workerSession.open" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid workerSession.open request kind",
                codingPath: decoder.codingPath
            )
        }
        try BridgeProductContractDecoding.decodeRequiredNull(
            forKey: .request,
            from: container,
            codingPath: decoder.codingPath
        )
        self.identity = try BridgeProductPaneControlRequestIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("workerSession.open", forKey: .kind)
        try container.encodeNil(forKey: .request)
    }
}

struct BridgeProductCallControlRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case call
        case kind
    }

    private let identity: BridgeProductSurfaceControlRequestIdentity
    let call: BridgeProductCallRequest

    var correlation: BridgeProductControlCorrelation { identity.correlation }
    var surface: BridgeProductSurface { call.surface }
    var workerDerivationEpoch: Int { identity.workerDerivationEpoch }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductSurfaceControlRequestIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "product.call request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.call = try container.decode(BridgeProductCallRequest.self, forKey: .call)
        guard try container.decode(String.self, forKey: .kind) == "product.call" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid product.call request kind",
                codingPath: decoder.codingPath
            )
        }
        self.identity = try BridgeProductSurfaceControlRequestIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(call, forKey: .call)
        try container.encode("product.call", forKey: .kind)
    }
}

struct BridgeProductSubscriptionOpenRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case subscription
        case subscriptionId
    }

    private let identity: BridgeProductSurfaceControlRequestIdentity
    let subscription: BridgeProductSubscriptionRequest
    let subscriptionId: String

    var correlation: BridgeProductControlCorrelation { identity.correlation }
    var surface: BridgeProductSurface { subscription.surface }
    var workerDerivationEpoch: Int { identity.workerDerivationEpoch }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductSurfaceControlRequestIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.open request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.open" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.open request kind",
                codingPath: decoder.codingPath
            )
        }
        self.subscription = try container.decode(BridgeProductSubscriptionRequest.self, forKey: .subscription)
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.identity = try BridgeProductSurfaceControlRequestIdentity(from: decoder)
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.open", forKey: .kind)
        try container.encode(subscription, forKey: .subscription)
        try container.encode(subscriptionId, forKey: .subscriptionId)
    }
}

struct BridgeProductSubscriptionCancelRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case subscriptionId
        case subscriptionKind
    }

    private let identity: BridgeProductSurfaceControlRequestIdentity
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind

    var correlation: BridgeProductControlCorrelation { identity.correlation }
    var surface: BridgeProductSurface? { subscriptionKind.surface }
    var workerDerivationEpoch: Int { identity.workerDerivationEpoch }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductSurfaceControlRequestIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.cancel request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.cancel" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.cancel request kind",
                codingPath: decoder.codingPath
            )
        }
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.subscriptionKind = try container.decode(BridgeProductSubscriptionKind.self, forKey: .subscriptionKind)
        _ = try BridgeProductMetadataApplicationRegistry.product.registration(for: subscriptionKind)
        self.identity = try BridgeProductSurfaceControlRequestIdentity(from: decoder)
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.cancel", forKey: .kind)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
    }
}

struct BridgeProductActiveSubscription: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case subscriptionId
        case subscriptionKind
        case workerDerivationEpoch
    }

    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind
    let workerDerivationEpoch: Int
    private let registeredSurface: BridgeProductSurface

    var surface: BridgeProductSurface { registeredSurface }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "active Bridge product subscription"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.subscriptionKind = try container.decode(BridgeProductSubscriptionKind.self, forKey: .subscriptionKind)
        registeredSurface = try BridgeProductMetadataApplicationRegistry.product.registration(
            for: subscriptionKind
        ).surface
        self.workerDerivationEpoch = try container.decode(
            Int.self,
            forKey: .workerDerivationEpoch
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            workerDerivationEpoch,
            name: "workerDerivationEpoch",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
        try container.encode(workerDerivationEpoch, forKey: .workerDerivationEpoch)
    }
}

struct BridgeProductWorkerSessionResyncRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case activeSubscriptions
        case kind
        case lastAcceptedRequestSequence
        case lastAcceptedStreamSequence
    }

    private let identity: BridgeProductPaneControlRequestIdentity
    let activeSubscriptions: [BridgeProductActiveSubscription]
    let lastAcceptedRequestSequence: Int
    let lastAcceptedStreamSequence: Int

    var correlation: BridgeProductControlCorrelation { identity }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductPaneControlRequestIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "workerSession.resync request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeSubscriptions = try container.decode(
            [BridgeProductActiveSubscription].self,
            forKey: .activeSubscriptions
        )
        guard try container.decode(String.self, forKey: .kind) == "workerSession.resync" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid workerSession.resync request kind",
                codingPath: decoder.codingPath
            )
        }
        self.lastAcceptedRequestSequence = try container.decode(Int.self, forKey: .lastAcceptedRequestSequence)
        self.lastAcceptedStreamSequence = try container.decode(Int.self, forKey: .lastAcceptedStreamSequence)
        self.identity = try BridgeProductPaneControlRequestIdentity(from: decoder)
        try BridgeProductContractDecoding.validateCollectionCount(
            activeSubscriptions.count,
            maximum: BridgeProductWireContract.maximumActiveSubscriptionCount,
            name: "active subscriptions",
            codingPath: decoder.codingPath
        )
        guard Set(activeSubscriptions.map(\.subscriptionId)).count == activeSubscriptions.count else {
            throw BridgeProductContractDecoding.invalidValue(
                "Duplicate active Bridge product subscription id",
                codingPath: decoder.codingPath
            )
        }
        var workerDerivationEpochBySurface: [BridgeProductSurface: Int] = [:]
        for subscription in activeSubscriptions {
            if let existingEpoch = workerDerivationEpochBySurface[subscription.surface],
                existingEpoch != subscription.workerDerivationEpoch
            {
                throw BridgeProductContractDecoding.invalidValue(
                    "Active subscriptions for one surface must share a derivation epoch",
                    codingPath: decoder.codingPath
                )
            }
            workerDerivationEpochBySurface[subscription.surface] = subscription.workerDerivationEpoch
        }
        try BridgeProductContractDecoding.validateNonnegative(
            lastAcceptedRequestSequence,
            name: "lastAcceptedRequestSequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            lastAcceptedStreamSequence,
            name: "lastAcceptedStreamSequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateMaximum(
            lastAcceptedStreamSequence,
            maximum: BridgeProductWireContract.maximumResumableStreamSequence,
            name: "lastAcceptedStreamSequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateMaximum(
            lastAcceptedRequestSequence,
            maximum: BridgeProductWireContract.maximumControlRequestSequence - 1,
            name: "lastAcceptedRequestSequence",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeSubscriptions, forKey: .activeSubscriptions)
        try container.encode("workerSession.resync", forKey: .kind)
        try container.encode(lastAcceptedRequestSequence, forKey: .lastAcceptedRequestSequence)
        try container.encode(lastAcceptedStreamSequence, forKey: .lastAcceptedStreamSequence)
    }
}
