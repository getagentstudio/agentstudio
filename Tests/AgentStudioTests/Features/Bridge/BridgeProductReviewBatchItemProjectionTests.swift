import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Review batch item projection")
struct BridgeProductReviewBatchItemProjectionTests {
    @Test("package order and role identities become complete typed item values")
    func initialPackageItemValues() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let fixtureURL = projectRoot.appending(
            path: "Tests/BridgeContractFixtures/valid/bridge-review-package.json"
        )
        let package = try JSONDecoder().decode(
            BridgeReviewPackage.self,
            from: Data(contentsOf: fixtureURL)
        )
        let revisions = Dictionary(
            uniqueKeysWithValues: package.itemsById.keys.map { ($0, 1) }
        )

        let items = try BridgeProductReviewBatchItemProjection.initialItems(
            in: package,
            revisionByItemId: revisions
        )

        #expect(items.map(\.record.itemId) == ["item-file-source-1", "item-file-generated-1"])
        #expect(items.map(\.record.sortKey) == [0, 1])
        #expect(items.map(\.revision) == [1, 1])
        let sourceItem = try #require(items.first?.record)
        #expect(sourceItem.parentPath == "Sources/AgentStudio/Features/Bridge/Runtime")
        #expect(sourceItem.provenance.operationIds == ["operation-1"])
        #expect(sourceItem.reviewState == .unreviewed)
        #expect(
            sourceItem.contentHashesByRole.head
                == package.itemsById[sourceItem.itemId]?.contentRoles.head?.contentHash
        )
        if case .available(let base) = sourceItem.contentByRole.base,
            case .available(let head) = sourceItem.contentByRole.head
        {
            #expect(base.itemId == sourceItem.itemId)
            #expect(base.role == .base)
            #expect(head.itemId == sourceItem.itemId)
            #expect(head.role == .head)
        } else {
            Issue.record("Expected role-qualified base and head sources")
        }
        #expect(sourceItem.contentByRole.diff == .absent)
        #expect(sourceItem.contentByRole.file == .absent)
        #expect(sourceItem.extentByRole.base == nil)
        #expect(sourceItem.extentByRole.head == nil)
        for item in items {
            let encoded = try JSONEncoder().encode(BridgeProductReviewBatchRecord.item(item.record))
            #expect(
                try BridgeProductStrictJSON.decode(BridgeProductReviewBatchRecord.self, from: encoded)
                    == .item(item.record)
            )
        }
    }
}
