import Foundation

enum BridgeProductBatchMode: String, Codable, Equatable, Sendable {
    case snapshot
    case change
    case coverage
}

enum BridgeProductSnapshotCause: String, Codable, Equatable, Sendable {
    case open
    case requested
    case recovery
    case newerInput

    func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.open, _), (_, .open): .open
        case (.requested, _), (_, .requested): .requested
        case (.recovery, _), (_, .recovery): .recovery
        case (.newerInput, .newerInput): .newerInput
        }
    }
}

struct BridgeProductBatchFrameIdentity: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case batchId
        case domain
        case handle
        case incarnation
        case scopeRevision
        case subscriptionId
        case subscriptionKind
    }

    static let codingKeyNames = BridgeProductMetadataFrameIdentity.codingKeyNames.union(
        CodingKeys.allCases.map(\.rawValue)
    )

    let frame: BridgeProductMetadataFrameIdentity
    let batchId: String
    let domain: String
    let handle: String
    let incarnation: String
    let scopeRevision: Int
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind

    init(
        frame: BridgeProductMetadataFrameIdentity,
        batchId: String,
        domain: String,
        handle: String,
        incarnation: String,
        scopeRevision: Int,
        subscriptionId: String,
        subscriptionKind: BridgeProductSubscriptionKind
    ) throws {
        try frame.validateProgressSequence(codingPath: [])
        try BridgeProductContractDecoding.validateIdentifier(batchId, codingPath: [])
        try BridgeProductContractDecoding.validateIdentifier(domain, codingPath: [])
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: [])
        try BridgeProductContractDecoding.validateIdentifier(incarnation, codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(scopeRevision, name: "scopeRevision", codingPath: [])
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: [])
        self.frame = frame
        self.batchId = batchId
        self.domain = domain
        self.handle = handle
        self.incarnation = incarnation
        self.scopeRevision = scopeRevision
        self.subscriptionId = subscriptionId
        self.subscriptionKind = subscriptionKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try BridgeProductMetadataFrameIdentity(from: decoder)
        try frame.validateProgressSequence(codingPath: decoder.codingPath)
        batchId = try container.decode(String.self, forKey: .batchId)
        domain = try container.decode(String.self, forKey: .domain)
        handle = try container.decode(String.self, forKey: .handle)
        incarnation = try container.decode(String.self, forKey: .incarnation)
        scopeRevision = try container.decode(Int.self, forKey: .scopeRevision)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        subscriptionKind = try container.decode(BridgeProductSubscriptionKind.self, forKey: .subscriptionKind)
        try BridgeProductContractDecoding.validateIdentifier(batchId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(domain, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(incarnation, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            scopeRevision,
            name: "scopeRevision",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try frame.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(batchId, forKey: .batchId)
        try container.encode(domain, forKey: .domain)
        try container.encode(handle, forKey: .handle)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(scopeRevision, forKey: .scopeRevision)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
    }
}

enum BridgeProductBatchPart: Codable, Equatable, Sendable {
    case put(key: String, revision: Int, value: BridgeProductJSONValue)
    case delete(key: String, revision: Int)
    case evict(key: String)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key
        case operation
        case revision
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decode(String.self, forKey: .operation)
        let key = try container.decode(String.self, forKey: .key)
        try BridgeProductContractDecoding.validateDisplayPath(key, codingPath: decoder.codingPath)
        switch operation {
        case "put":
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                contract: "batch put part"
            )
            let revision = try container.decode(Int.self, forKey: .revision)
            try BridgeProductContractDecoding.validatePositive(
                revision,
                name: "revision",
                codingPath: decoder.codingPath
            )
            self = .put(
                key: key,
                revision: revision,
                value: try container.decode(BridgeProductJSONValue.self, forKey: .value)
            )
        case "delete":
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [CodingKeys.key.rawValue, CodingKeys.operation.rawValue, CodingKeys.revision.rawValue],
                contract: "batch delete part"
            )
            let revision = try container.decode(Int.self, forKey: .revision)
            try BridgeProductContractDecoding.validatePositive(
                revision,
                name: "revision",
                codingPath: decoder.codingPath
            )
            self = .delete(key: key, revision: revision)
        case "evict":
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [CodingKeys.key.rawValue, CodingKeys.operation.rawValue],
                contract: "batch evict part"
            )
            self = .evict(key: key)
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid batch part operation",
                codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .put(let key, let revision, let value):
            try container.encode(key, forKey: .key)
            try container.encode("put", forKey: .operation)
            try container.encode(revision, forKey: .revision)
            try container.encode(value, forKey: .value)
        case .delete(let key, let revision):
            try container.encode(key, forKey: .key)
            try container.encode("delete", forKey: .operation)
            try container.encode(revision, forKey: .revision)
        case .evict(let key):
            try container.encode(key, forKey: .key)
            try container.encode("evict", forKey: .operation)
        }
    }
}

struct BridgeProductBatchBeginFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case baseRevision
        case kind
        case mode
        case partCount
        case publicationId
        case requiresCollection
        case scope
        case snapshotCause
        case targetRevision
    }

    let identity: BridgeProductBatchFrameIdentity
    let baseRevision: Int
    let mode: BridgeProductBatchMode
    let partCount: Int
    let publicationId: UUID?
    let requiresCollection: Int?
    let scope: BridgeProductJSONValue
    let snapshotCause: BridgeProductSnapshotCause?
    let targetRevision: Int

    init(
        identity: BridgeProductBatchFrameIdentity,
        baseRevision: Int,
        mode: BridgeProductBatchMode,
        partCount: Int,
        publicationId: UUID? = nil,
        requiresCollection: Int?,
        scope: BridgeProductJSONValue,
        snapshotCause: BridgeProductSnapshotCause?,
        targetRevision: Int
    ) throws {
        guard (mode == .snapshot) == (snapshotCause != nil) else {
            throw BridgeProductContractDecoding.invalidValue("Snapshot mode requires exactly one cause", codingPath: [])
        }
        try BridgeProductContractDecoding.validateNonnegative(baseRevision, name: "baseRevision", codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(partCount, name: "partCount", codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(targetRevision, name: "targetRevision", codingPath: [])
        if let requiresCollection {
            try BridgeProductContractDecoding.validateNonnegative(
                requiresCollection, name: "requiresCollection", codingPath: [])
        }
        guard targetRevision >= baseRevision else {
            throw BridgeProductContractDecoding.invalidValue("Batch target precedes base", codingPath: [])
        }
        if identity.subscriptionKind == .reviewMetadata, publicationId == nil {
            throw BridgeProductContractDecoding.invalidValue("Review batch requires publicationId", codingPath: [])
        }
        if identity.subscriptionKind != .reviewMetadata, publicationId != nil {
            throw BridgeProductContractDecoding.invalidValue("Only Review batches name a publication", codingPath: [])
        }
        try BridgeProductViewScopeContract.validate(scope, codingPath: [])
        self.identity = identity
        self.baseRevision = baseRevision
        self.mode = mode
        self.partCount = partCount
        self.publicationId = publicationId
        self.requiresCollection = requiresCollection
        self.scope = scope
        self.snapshotCause = snapshotCause
        self.targetRevision = targetRevision
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductBatchFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.batchBegin frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.batchBegin" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.batchBegin frame kind",
                codingPath: decoder.codingPath
            )
        }
        identity = try BridgeProductBatchFrameIdentity(from: decoder)
        baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        mode = try container.decode(BridgeProductBatchMode.self, forKey: .mode)
        snapshotCause = try container.decodeIfPresent(BridgeProductSnapshotCause.self, forKey: .snapshotCause)
        guard mode == .snapshot ? snapshotCause != nil : !container.contains(.snapshotCause) else {
            throw BridgeProductContractDecoding.invalidValue(
                "Snapshot mode requires exactly one cause", codingPath: decoder.codingPath
            )
        }
        partCount = try container.decode(Int.self, forKey: .partCount)
        publicationId = try container.decodeIfPresent(String.self, forKey: .publicationId).map {
            try BridgeProductReviewPublicationIdContract.decode($0, codingPath: decoder.codingPath)
        }
        requiresCollection = try container.decodeIfPresent(Int.self, forKey: .requiresCollection)
        if let requiresCollection {
            try BridgeProductContractDecoding.validateNonnegative(
                requiresCollection,
                name: "requiresCollection",
                codingPath: decoder.codingPath
            )
        }
        scope = try container.decode(BridgeProductJSONValue.self, forKey: .scope)
        try BridgeProductViewScopeContract.validate(scope, codingPath: decoder.codingPath)
        targetRevision = try container.decode(Int.self, forKey: .targetRevision)
        try BridgeProductContractDecoding.validateNonnegative(
            baseRevision,
            name: "baseRevision",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            partCount,
            name: "partCount",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            targetRevision,
            name: "targetRevision",
            codingPath: decoder.codingPath
        )
        guard targetRevision >= baseRevision else {
            throw BridgeProductContractDecoding.invalidValue(
                "Batch target revision precedes its base",
                codingPath: decoder.codingPath
            )
        }
        if identity.subscriptionKind == .reviewMetadata, publicationId == nil {
            throw BridgeProductContractDecoding.invalidValue(
                "Review batch requires publicationId", codingPath: decoder.codingPath
            )
        }
        if identity.subscriptionKind != .reviewMetadata, publicationId != nil {
            throw BridgeProductContractDecoding.invalidValue(
                "Only Review batches name a publication", codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode("subscription.batchBegin", forKey: .kind)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(snapshotCause, forKey: .snapshotCause)
        try container.encode(partCount, forKey: .partCount)
        try container.encodeIfPresent(
            publicationId.map(BridgeProductReviewPublicationIdContract.encode), forKey: .publicationId)
        try container.encodeIfPresent(requiresCollection, forKey: .requiresCollection)
        try container.encode(scope, forKey: .scope)
        try container.encode(targetRevision, forKey: .targetRevision)
    }
}

struct BridgeProductBatchPartFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case deliverySequence
        case kind
        case part
        case partIndex
    }

    let identity: BridgeProductBatchFrameIdentity
    let deliverySequence: Int
    let part: BridgeProductBatchPart
    let partIndex: Int

    init(
        identity: BridgeProductBatchFrameIdentity,
        deliverySequence: Int,
        part: BridgeProductBatchPart,
        partIndex: Int
    ) throws {
        try BridgeProductContractDecoding.validatePositive(deliverySequence, name: "deliverySequence", codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(partIndex, name: "partIndex", codingPath: [])
        self.identity = identity
        self.deliverySequence = deliverySequence
        self.part = part
        self.partIndex = partIndex
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductBatchFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.batchPart frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.batchPart" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.batchPart frame kind",
                codingPath: decoder.codingPath
            )
        }
        identity = try BridgeProductBatchFrameIdentity(from: decoder)
        deliverySequence = try container.decode(Int.self, forKey: .deliverySequence)
        part = try container.decode(BridgeProductBatchPart.self, forKey: .part)
        partIndex = try container.decode(Int.self, forKey: .partIndex)
        try BridgeProductContractDecoding.validatePositive(
            deliverySequence,
            name: "deliverySequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            partIndex,
            name: "partIndex",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deliverySequence, forKey: .deliverySequence)
        try container.encode("subscription.batchPart", forKey: .kind)
        try container.encode(part, forKey: .part)
        try container.encode(partIndex, forKey: .partIndex)
    }
}

struct BridgeProductBatchCompleteFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case coveredScope
        case kind
    }

    let identity: BridgeProductBatchFrameIdentity
    let coveredScope: BridgeProductJSONValue

    init(identity: BridgeProductBatchFrameIdentity, coveredScope: BridgeProductJSONValue) throws {
        try BridgeProductViewScopeContract.validate(coveredScope, codingPath: [])
        self.identity = identity
        self.coveredScope = coveredScope
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductBatchFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.batchComplete frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.batchComplete" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.batchComplete frame kind",
                codingPath: decoder.codingPath
            )
        }
        identity = try BridgeProductBatchFrameIdentity(from: decoder)
        coveredScope = try container.decode(BridgeProductJSONValue.self, forKey: .coveredScope)
        try BridgeProductViewScopeContract.validate(coveredScope, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coveredScope, forKey: .coveredScope)
        try container.encode("subscription.batchComplete", forKey: .kind)
    }
}

enum BridgeProductBatchFrame: Codable, Equatable, Sendable {
    case begin(BridgeProductBatchBeginFrame)
    case part(BridgeProductBatchPartFrame)
    case complete(BridgeProductBatchCompleteFrame)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    var identity: BridgeProductBatchFrameIdentity {
        switch self {
        case .begin(let frame): frame.identity
        case .part(let frame): frame.identity
        case .complete(let frame): frame.identity
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "subscription.batchBegin": self = .begin(try .init(from: decoder))
        case "subscription.batchPart": self = .part(try .init(from: decoder))
        case "subscription.batchComplete": self = .complete(try .init(from: decoder))
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Unknown subscription batch frame kind",
                codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .begin(let frame): try frame.encode(to: encoder)
        case .part(let frame): try frame.encode(to: encoder)
        case .complete(let frame): try frame.encode(to: encoder)
        }
    }
}
