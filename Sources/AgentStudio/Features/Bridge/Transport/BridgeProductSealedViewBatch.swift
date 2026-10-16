import AgentStudioInfrastructure
import Foundation

enum BridgeProductSealedViewBatchError: Error {
    case invalidFrameOrdinal
}

/// Freezes one publisher capture before the first frame is emitted. The stream
/// sequence is supplied by the producer registry for each frame; part order,
/// target revision and the collection dependency never change on retry.
struct BridgeProductSealedViewBatch: Sendable {
    let batchId: String
    let viewDomain: BridgeProductViewDomainKey
    let producerScanGeneration: Int
    let handle: String
    let subscriptionKind: BridgeProductSubscriptionKind
    let scopeRevision: Int
    let baseRevision: Int
    let targetRevision: Int
    let mode: BridgeProductBatchMode
    let publicationId: UUID?
    let scope: BridgeProductJSONValue
    let coveredScope: BridgeProductJSONValue
    let requiresCollection: Int?
    let firstDeliverySequence: Int
    let parts: [BridgeProductBatchPart]

    init(
        viewDomain: BridgeProductViewDomainKey,
        producerScanGeneration: Int,
        handle: String,
        subscriptionKind: BridgeProductSubscriptionKind,
        scopeRevision: Int,
        baseRevision: Int,
        targetRevision: Int,
        mode: BridgeProductBatchMode,
        publicationId: UUID? = nil,
        scope: BridgeProductJSONValue,
        coveredScope: BridgeProductJSONValue,
        requiresCollection: Int?,
        firstDeliverySequence: Int,
        parts: [BridgeProductBatchPart]
    ) throws {
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(
            producerScanGeneration,
            name: "producerScanGeneration",
            codingPath: []
        )
        try BridgeProductContractDecoding.validateNonnegative(scopeRevision, name: "scopeRevision", codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(baseRevision, name: "baseRevision", codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(targetRevision, name: "targetRevision", codingPath: [])
        try BridgeProductContractDecoding.validatePositive(
            firstDeliverySequence,
            name: "firstDeliverySequence",
            codingPath: []
        )
        guard targetRevision >= baseRevision,
            parts.count <= BridgeProductWireContract.maximumSafeInteger - firstDeliverySequence
        else {
            throw BridgeProductContractDecoding.invalidValue("Invalid sealed batch revision or size", codingPath: [])
        }
        try BridgeProductViewScopeContract.validate(scope, codingPath: [])
        try BridgeProductViewScopeContract.validate(coveredScope, codingPath: [])
        if let requiresCollection {
            try BridgeProductContractDecoding.validateNonnegative(
                requiresCollection,
                name: "requiresCollection",
                codingPath: []
            )
        }
        for part in parts {
            switch part {
            case .put(let key, let revision, _), .delete(let key, let revision):
                try BridgeProductContractDecoding.validateDisplayPath(key, codingPath: [])
                try BridgeProductContractDecoding.validatePositive(revision, name: "revision", codingPath: [])
            case .evict(let key):
                try BridgeProductContractDecoding.validateDisplayPath(key, codingPath: [])
            }
        }
        batchId = UUIDv7.generate().uuidString.lowercased()
        self.viewDomain = viewDomain
        self.producerScanGeneration = producerScanGeneration
        self.handle = handle
        self.subscriptionKind = subscriptionKind
        self.scopeRevision = scopeRevision
        self.baseRevision = baseRevision
        self.targetRevision = targetRevision
        self.mode = mode
        self.publicationId = publicationId
        self.scope = scope
        self.coveredScope = coveredScope
        self.requiresCollection = requiresCollection
        self.firstDeliverySequence = firstDeliverySequence
        self.parts = parts
    }

    var frameCount: Int { parts.count + 2 }

    func frame(
        atOrdinal ordinal: Int,
        stream: BridgeProductMetadataStreamCorrelation,
        streamSequence: Int,
        snapshotCause: BridgeProductSnapshotCause?
    ) throws -> BridgeProductMetadataFrame {
        guard (0..<frameCount).contains(ordinal) else {
            throw BridgeProductSealedViewBatchError.invalidFrameOrdinal
        }
        let identity = try BridgeProductBatchFrameIdentity(
            frame: .init(correlation: stream, streamSequence: streamSequence),
            batchId: batchId,
            domain: viewDomain.domain.rawValue,
            handle: handle,
            incarnation: viewDomain.incarnation,
            scopeRevision: scopeRevision,
            subscriptionId: viewDomain.viewId,
            subscriptionKind: subscriptionKind
        )
        if ordinal == 0 {
            return .batch(
                .begin(
                    try .init(
                        identity: identity,
                        baseRevision: baseRevision,
                        mode: mode,
                        partCount: parts.count,
                        publicationId: publicationId,
                        requiresCollection: requiresCollection,
                        scope: scope,
                        snapshotCause: snapshotCause,
                        targetRevision: targetRevision
                    )))
        }
        if ordinal == frameCount - 1 {
            return .batch(.complete(try .init(identity: identity, coveredScope: coveredScope)))
        }
        let partIndex = ordinal - 1
        return .batch(
            .part(
                try .init(
                    identity: identity,
                    deliverySequence: firstDeliverySequence + partIndex,
                    part: parts[partIndex],
                    partIndex: partIndex
                )))
    }
}
