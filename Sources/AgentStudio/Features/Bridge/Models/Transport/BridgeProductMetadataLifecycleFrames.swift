import Foundation

struct BridgeProductSubscriptionProgressIdentity: Equatable, Sendable {
    static let codingKeyNames = BridgeProductMetadataFrameIdentity.codingKeyNames.union(
        BridgeProductSubscriptionFrameIdentity.codingKeyNames
    )

    let frameIdentity: BridgeProductMetadataFrameIdentity
    let subscriptionIdentity: BridgeProductSubscriptionFrameIdentity

    init(from decoder: Decoder) throws {
        self.frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
        self.subscriptionIdentity = try BridgeProductSubscriptionFrameIdentity(from: decoder)
        try frameIdentity.validateProgressSequence(codingPath: decoder.codingPath)
        try subscriptionIdentity.validateProgressSequence(codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        try subscriptionIdentity.encode(to: encoder)
    }
}

struct BridgeProductSubscriptionResetFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case reason
    }

    let identity: BridgeProductSubscriptionProgressIdentity
    let reason: BridgeProductResetReason

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductSubscriptionProgressIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.reset frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.reset" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.reset frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.reason = try container.decode(BridgeProductResetReason.self, forKey: .reason)
        self.identity = try BridgeProductSubscriptionProgressIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.reset", forKey: .kind)
        try container.encode(reason, forKey: .reason)
    }
}

struct BridgeProductSubscriptionEndFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
    }

    let identity: BridgeProductSubscriptionProgressIdentity

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductSubscriptionProgressIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.end frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.end" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.end frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.identity = try BridgeProductSubscriptionProgressIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.end", forKey: .kind)
    }
}

struct BridgeProductSubscriptionCancelledFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
    }

    let identity: BridgeProductSubscriptionProgressIdentity

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductSubscriptionProgressIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.cancelled frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.cancelled" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.cancelled frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.identity = try BridgeProductSubscriptionProgressIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.cancelled", forKey: .kind)
    }
}

struct BridgeProductContentCancelledFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contentRequestId
        case disposition
        case identity
        case kind
        case leaseId
        case operationCorrelationId
        case workerDerivationEpoch
    }

    let frameIdentity: BridgeProductMetadataFrameIdentity
    let contentRequestId: String
    let disposition: BridgeProductContentCancellationDisposition
    let identity: BridgeProductContentIdentity
    let leaseId: String
    let operationCorrelationID: String?
    let workerDerivationEpoch: Int

    var surface: BridgeProductSurface { identity.surface }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductMetadataFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "content.cancelled frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.contentRequestId = try container.decode(String.self, forKey: .contentRequestId)
        self.disposition = try container.decode(
            BridgeProductContentCancellationDisposition.self,
            forKey: .disposition
        )
        self.identity = try container.decode(BridgeProductContentIdentity.self, forKey: .identity)
        guard try container.decode(String.self, forKey: .kind) == "content.cancelled" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid content.cancelled frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.leaseId = try container.decode(String.self, forKey: .leaseId)
        self.operationCorrelationID = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .operationCorrelationId,
            from: container,
            codingPath: decoder.codingPath
        )
        self.workerDerivationEpoch = try container.decode(
            Int.self,
            forKey: .workerDerivationEpoch
        )
        self.frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
        try frameIdentity.validateProgressSequence(codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(contentRequestId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(leaseId, codingPath: decoder.codingPath)
        if let operationCorrelationID {
            try BridgeProductContractDecoding.validateSHA256(
                operationCorrelationID,
                codingPath: decoder.codingPath
            )
        }
        try BridgeProductContractDecoding.validateNonnegative(
            workerDerivationEpoch,
            name: "workerDerivationEpoch",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentRequestId, forKey: .contentRequestId)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(identity, forKey: .identity)
        try container.encode("content.cancelled", forKey: .kind)
        try container.encode(leaseId, forKey: .leaseId)
        try container.encode(operationCorrelationID, forKey: .operationCorrelationId)
        try container.encode(workerDerivationEpoch, forKey: .workerDerivationEpoch)
    }
}

struct BridgeProductMetadataStreamErrorFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case kind
        case retryable
        case safeMessage
    }

    let frameIdentity: BridgeProductMetadataFrameIdentity
    let code: BridgeProductRequestErrorCode
    let retryable: Bool
    let safeMessage: String?

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductMetadataFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "metadataStream.error frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(BridgeProductRequestErrorCode.self, forKey: .code)
        guard try container.decode(String.self, forKey: .kind) == "metadataStream.error" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid metadataStream.error frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.retryable = try container.decode(Bool.self, forKey: .retryable)
        self.safeMessage = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .safeMessage,
            from: container,
            codingPath: decoder.codingPath
        )
        self.frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
        try frameIdentity.validateProgressSequence(codingPath: decoder.codingPath)
        if let safeMessage {
            try BridgeProductContractDecoding.validateSafeMessage(safeMessage, codingPath: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode("metadataStream.error", forKey: .kind)
        try container.encode(retryable, forKey: .retryable)
        try container.encode(safeMessage, forKey: .safeMessage)
    }
}
