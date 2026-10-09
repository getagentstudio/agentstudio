import Foundation

struct BridgeProductReviewKeyedItem: Sendable {
    let record: BridgeProductReviewBatchItemRecord
    let revision: Int
}

struct BridgeProductReviewKeyedSnapshot: Sendable {
    let targetRevision: Int
    let publication: BridgeProductReviewBatchPublicationRecord
    let items: [BridgeProductReviewKeyedItem]
}

struct BridgeProductReviewViewSnapshotInput: Sendable {
    let viewDomain: BridgeProductViewDomainKey
    let handle: String
    let scopeRevision: Int
    let scope: BridgeProductJSONValue
    let firstDeliverySequence: Int
    let targetRevision: Int
    let publication: BridgeProductReviewBatchPublicationRecord
    let items: [BridgeProductReviewKeyedItem]
}

enum BridgeProductReviewViewBatchFactoryError: Error {
    case duplicateItemId
    case itemsWithoutDisplayedPublication
    case revisionAheadOfTarget
}

/// Freezes N10's minted Review records as one complete comparison replacement.
enum BridgeProductReviewViewBatchFactory {
    static func sealSnapshot(
        _ input: BridgeProductReviewViewSnapshotInput
    ) throws -> BridgeProductSealedViewBatch {
        guard input.publication.revision <= input.targetRevision else {
            throw BridgeProductReviewViewBatchFactoryError.revisionAheadOfTarget
        }
        guard input.publication.displayed != nil || input.items.isEmpty else {
            throw BridgeProductReviewViewBatchFactoryError.itemsWithoutDisplayedPublication
        }
        var seenItemIds = Set<String>()
        var parts: [BridgeProductBatchPart] = []
        parts.reserveCapacity(input.items.count + 1)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for item in input.items.sorted(by: { $0.record.itemId < $1.record.itemId }) {
            guard seenItemIds.insert(item.record.itemId).inserted else {
                throw BridgeProductReviewViewBatchFactoryError.duplicateItemId
            }
            guard item.revision <= input.targetRevision else {
                throw BridgeProductReviewViewBatchFactoryError.revisionAheadOfTarget
            }
            let encoded = try encoder.encode(BridgeProductReviewBatchRecord.item(item.record))
            let value = try decoder.decode(BridgeProductJSONValue.self, from: encoded)
            parts.append(.put(key: item.record.itemId, revision: item.revision, value: value))
        }
        let encodedPublication = try encoder.encode(
            BridgeProductReviewBatchRecord.publication(input.publication)
        )
        let publicationValue = try decoder.decode(
            BridgeProductJSONValue.self,
            from: encodedPublication
        )
        parts.append(
            .put(
                key: "publication",
                revision: input.publication.revision,
                value: publicationValue
            )
        )
        return try BridgeProductSealedViewBatch(
            viewDomain: input.viewDomain,
            producerScanGeneration: input.scopeRevision,
            handle: input.handle,
            subscriptionKind: .reviewMetadata,
            scopeRevision: input.scopeRevision,
            baseRevision: 0,
            targetRevision: input.targetRevision,
            mode: .snapshot,
            publicationId: input.publication.publicationId,
            scope: input.scope,
            coveredScope: input.scope,
            requiresCollection: nil,
            firstDeliverySequence: input.firstDeliverySequence,
            parts: parts
        )
    }
}
