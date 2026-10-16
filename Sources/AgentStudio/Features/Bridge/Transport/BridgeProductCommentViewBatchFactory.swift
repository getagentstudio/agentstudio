import Foundation

struct BridgeProductCommentViewBatchInput: Sendable {
    let viewDomain: BridgeProductViewDomainKey
    let scopeRevision: Int
    let scope: BridgeProductJSONValue
    let firstDeliverySequence: Int
    let mode: BridgeProductBatchMode
    let batch: BridgeProductCommentCatalogBatch
    let subscriptionKind: BridgeProductSubscriptionKind
}

enum BridgeProductCommentViewBatchFactoryError: Error {
    case invalidSubscriptionKind
}

/// Freezes N10's serialized current-row install into one comment view batch.
enum BridgeProductCommentViewBatchFactory {
    static func seal(_ input: BridgeProductCommentViewBatchInput) throws -> BridgeProductSealedViewBatch {
        guard
            input.subscriptionKind == .fileAnnotations
                || input.subscriptionKind == .reviewAnnotations
        else {
            throw BridgeProductCommentViewBatchFactoryError.invalidSubscriptionKind
        }
        var parts: [BridgeProductBatchPart] = []
        parts.reserveCapacity(input.batch.puts.count + input.batch.deletes.count)
        for record in input.batch.puts.sorted(by: { $0.recordKey < $1.recordKey }) {
            let encoded = try JSONEncoder().encode(record)
            let value = try JSONDecoder().decode(BridgeProductJSONValue.self, from: encoded)
            parts.append(.put(key: record.recordKey, revision: record.revision, value: value))
        }
        for deletion in input.batch.deletes.sorted(by: { $0.key.recordKey < $1.key.recordKey }) {
            parts.append(.delete(key: deletion.key.recordKey, revision: deletion.revision))
        }
        return try BridgeProductSealedViewBatch(
            viewDomain: input.viewDomain,
            producerScanGeneration: input.scopeRevision,
            handle: input.batch.handle,
            subscriptionKind: input.subscriptionKind,
            scopeRevision: input.scopeRevision,
            baseRevision: input.batch.baseRevision,
            targetRevision: input.batch.targetRevision,
            mode: input.mode,
            scope: input.scope,
            coveredScope: input.scope,
            requiresCollection: nil,
            firstDeliverySequence: input.firstDeliverySequence,
            parts: parts
        )
    }
}
