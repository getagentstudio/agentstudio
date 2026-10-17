import Foundation

struct BridgeProductSubscriptionOpenAcceptedResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case subscriptionId
        case subscriptionKind
        case worktreeId
    }

    private let identity: BridgeProductControlCorrelation
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind
    let worktreeId: String?

    var correlation: BridgeProductControlCorrelation { identity }

    init(
        correlation: BridgeProductControlCorrelation,
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind,
        worktreeId: String?
    ) throws {
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: [])
        try Self.validateWorktreeId(worktreeId, for: subscriptionKind, codingPath: [])
        self.identity = correlation
        self.subscriptionId = subscriptionId
        self.subscriptionKind = subscriptionKind
        self.worktreeId = worktreeId
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlCorrelation.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.openAccepted response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.openAccepted" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.openAccepted response kind",
                codingPath: decoder.codingPath
            )
        }
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.subscriptionKind = try container.decode(
            BridgeProductSubscriptionKind.self,
            forKey: .subscriptionKind
        )
        self.worktreeId = try container.decodeIfPresent(String.self, forKey: .worktreeId)
        self.identity = try BridgeProductControlCorrelation(from: decoder)
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
        try Self.validateWorktreeId(worktreeId, for: subscriptionKind, codingPath: decoder.codingPath)
        if worktreeId == nil, container.contains(.worktreeId) {
            throw BridgeProductContractDecoding.invalidValue(
                "File and Review metadata open replies cannot carry worktreeId",
                codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.openAccepted", forKey: .kind)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
        if let worktreeId { try container.encode(worktreeId, forKey: .worktreeId) }
    }

    private static func validateWorktreeId(
        _ worktreeId: String?,
        for subscriptionKind: BridgeProductSubscriptionKind,
        codingPath: [any CodingKey]
    ) throws {
        switch subscriptionKind {
        case .fileAnnotations, .reviewAnnotations:
            guard let worktreeId else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Comment subscription open reply requires worktreeId",
                    codingPath: codingPath
                )
            }
            try BridgeProductContractDecoding.validateIdentifier(worktreeId, codingPath: codingPath)
        case .fileMetadata, .reviewMetadata:
            guard worktreeId == nil else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Metadata subscription open reply cannot carry worktreeId",
                    codingPath: codingPath
                )
            }
        default:
            guard worktreeId == nil else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Only Comment subscription open replies carry worktreeId",
                    codingPath: codingPath
                )
            }
        }
    }
}

struct BridgeProductSubscriptionCancelAcceptedResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case subscriptionId
        case subscriptionKind
    }

    private let identity: BridgeProductControlCorrelation
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind

    var correlation: BridgeProductControlCorrelation { identity }

    init(
        correlation: BridgeProductControlCorrelation,
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind
    ) {
        self.identity = correlation
        self.subscriptionId = subscriptionId
        self.subscriptionKind = subscriptionKind
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlCorrelation.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.cancelAccepted response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.cancelAccepted" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.cancelAccepted response kind",
                codingPath: decoder.codingPath
            )
        }
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.subscriptionKind = try container.decode(
            BridgeProductSubscriptionKind.self,
            forKey: .subscriptionKind
        )
        self.identity = try BridgeProductControlCorrelation(from: decoder)
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.cancelAccepted", forKey: .kind)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
    }
}
