import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Review sealed snapshot")
struct BridgeProductReviewViewBatchFactoryTests {
    @Test("a committed package projects into one complete Review replacement snapshot")
    func packageProjectionSealsOnePublication() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let package = try JSONDecoder().decode(
            BridgeReviewPackage.self,
            from: Data(
                contentsOf: projectRoot.appending(
                    path: "Tests/BridgeContractFixtures/valid/bridge-review-package.json"
                ))
        )
        let revision = 2
        let items = try BridgeProductReviewBatchItemProjection.initialItems(
            in: package,
            revisionByItemId: Dictionary(
                uniqueKeysWithValues: package.itemsById.keys.map { ($0, revision) }
            )
        )
        let publication = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: nil,
                publicationId: UUIDv7.generate(),
                revision: revision,
                desiredComparison: nil,
                desiredStatus: .ready,
                displayedPackage: package,
                displayedPublicationId: UUIDv7.generate(),
                displayedComparison: nil
            )
        )
        let scope: BridgeProductJSONValue = .object(["kind": .string("review"), "interests": .array([])])

        let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: .init(
                    viewId: "review-subscription-1",
                    domain: .singleDomain,
                    incarnation: "review-incarnation-1"
                ),
                handle: "review-handle-1",
                scopeRevision: 1,
                scope: scope,
                firstDeliverySequence: 1,
                targetRevision: revision,
                publication: publication,
                items: items
            )
        )

        #expect(batch.mode == .snapshot)
        #expect(batch.publicationId == publication.publicationId)
        #expect(batch.parts.count == package.itemsById.count + 1)
        #expect(batch.targetRevision == revision)
        #expect(
            batch.parts.compactMap { part -> String? in
                guard case .put(let key, _, _) = part else { return nil }
                return key
            }.sorted() == package.itemsById.keys.sorted() + ["publication"])
    }

    @Test("a complete Review snapshot seals typed items and its matching publication")
    func completePublicationSnapshot() throws {
        let records = try reviewBatchFixtureRecords()
        let viewDomain = BridgeProductViewDomainKey(
            viewId: "review-subscription-1",
            domain: .singleDomain,
            incarnation: "review-incarnation-1"
        )
        let scope: BridgeProductJSONValue = .object(["kind": .string("review"), "interests": .array([])])

        let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: viewDomain,
                handle: "review-handle-1",
                scopeRevision: 2,
                scope: scope,
                firstDeliverySequence: 1,
                targetRevision: records.displayedPublication.revision,
                publication: records.displayedPublication,
                items: [.init(record: records.item, revision: records.displayedPublication.revision)]
            )
        )

        #expect(batch.subscriptionKind == .reviewMetadata)
        #expect(batch.mode == .snapshot)
        #expect(batch.baseRevision == 0)
        #expect(batch.publicationId == records.displayedPublication.publicationId)
        #expect(batch.parts.count == 2)
        #expect(batch.frameCount == 4)
        guard case .put(let itemKey, let itemRevision, let itemValue) = batch.parts[0],
            case .put(let publicationKey, let publicationRevision, let publicationValue) = batch.parts[1]
        else {
            Issue.record("Expected one typed item and one publication in the sealed snapshot")
            return
        }
        #expect(itemKey == records.item.itemId)
        #expect(itemRevision == records.displayedPublication.revision)
        #expect(publicationKey == "publication")
        #expect(publicationRevision == records.displayedPublication.revision)
        let decoder = JSONDecoder()
        #expect(
            try decoder.decode(BridgeProductReviewBatchRecord.self, from: JSONEncoder().encode(itemValue))
                == .item(records.item)
        )
        #expect(
            try decoder.decode(BridgeProductReviewBatchRecord.self, from: JSONEncoder().encode(publicationValue))
                == .publication(records.displayedPublication)
        )
    }

    @Test("an empty Review publication is a complete sealed snapshot")
    func emptyPublicationSnapshot() throws {
        let records = try reviewBatchFixtureRecords()
        let scope: BridgeProductJSONValue = .object(["kind": .string("review"), "interests": .array([])])
        let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: .init(
                    viewId: "review-subscription-1",
                    domain: .singleDomain,
                    incarnation: "review-incarnation-1"
                ),
                handle: "review-handle-1",
                scopeRevision: 1,
                scope: scope,
                firstDeliverySequence: 1,
                targetRevision: records.emptyPublication.revision,
                publication: records.emptyPublication,
                items: []
            )
        )

        #expect(batch.mode == .snapshot)
        #expect(batch.publicationId == records.emptyPublication.publicationId)
        #expect(batch.parts.count == 1)
        #expect(batch.frameCount == 3)
        guard case .put(let key, _, _) = batch.parts[0] else {
            Issue.record("Expected the reserved Review publication record")
            return
        }
        #expect(key == "publication")
    }
}

private func reviewBatchFixtureRecords() throws -> (
    item: BridgeProductReviewBatchItemRecord,
    emptyPublication: BridgeProductReviewBatchPublicationRecord,
    displayedPublication: BridgeProductReviewBatchPublicationRecord
) {
    let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
    let data = try Data(
        contentsOf: projectRoot.appending(
            path: "Tests/BridgeContractFixtures/valid/bridge-product-review-batch-record-corpus.json"
        ))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try #require(object["records"] as? [[String: Any]])
    let records = try entries.map { entry in
        let recordObject = try #require(entry["record"] as? [String: Any])
        return try JSONDecoder().decode(
            BridgeProductReviewBatchRecord.self,
            from: JSONSerialization.data(withJSONObject: recordObject)
        )
    }
    guard records.count == 3,
        case .item(let item) = records[0],
        case .publication(let emptyPublication) = records[1],
        case .publication(let displayedPublication) = records[2]
    else {
        throw BridgeProductReviewViewBatchFixtureError.unexpectedRecords
    }
    return (item, emptyPublication, displayedPublication)
}

private enum BridgeProductReviewViewBatchFixtureError: Error {
    case unexpectedRecords
}
