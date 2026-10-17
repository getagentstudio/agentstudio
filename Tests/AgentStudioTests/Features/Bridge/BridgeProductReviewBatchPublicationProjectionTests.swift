import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge Review batch publication projection")
struct BridgeProductReviewBatchPublicationProjectionTests {
    @Test("failed desired comparison keeps the last displayed publication readable")
    func desiredFailureRetainsDisplayedPublication() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let package = try JSONDecoder().decode(
            BridgeReviewPackage.self,
            from: Data(
                contentsOf: projectRoot.appending(
                    path: "Tests/BridgeContractFixtures/valid/bridge-review-package.json"
                ))
        )
        let displayedPublicationId = UUIDv7.generate()
        let statusPublicationId = UUIDv7.generate()
        let refreshImpact = BridgeReviewRefreshImpact.exact(
            newlyImportedCommitCount: 0,
            affectedFileCount: AppPolicies.Bridge.reviewRefreshPromotionAffectedFileCount,
            addedLineCount: 0,
            deletedLineCount: 0,
            affectedStableFileIdentities: ["stable-file-1"]
        )

        let record = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: refreshImpact,
                publicationId: statusPublicationId,
                revision: 12,
                desiredComparison: nil,
                desiredStatus: .failedRetryable,
                displayedPackage: package,
                displayedPublicationId: displayedPublicationId,
                displayedComparison: nil
            )
        )

        #expect(record.publicationId == statusPublicationId)
        #expect(record.desired.status == .failedRetryable)
        #expect(record.displayed?.publicationId == displayedPublicationId)
        #expect(record.displayed?.packageId == package.packageId)
        #expect(record.displayed?.query.queryId == package.query.queryId)
        #expect(record.displayed?.revision == package.revision)
        #expect(record.classifiedRefreshImpact == refreshImpact)
        let encoded = try JSONEncoder().encode(BridgeProductReviewBatchRecord.publication(record))
        #expect(
            try BridgeProductStrictJSON.decode(BridgeProductReviewBatchRecord.self, from: encoded)
                == .publication(record)
        )
        var untrustedRecord = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        untrustedRecord.removeValue(forKey: "classifiedRefreshImpact")
        let missingImpact = try JSONSerialization.data(withJSONObject: untrustedRecord)
        #expect(throws: (any Error).self) {
            try BridgeProductStrictJSON.decode(BridgeProductReviewBatchRecord.self, from: missingImpact)
        }
    }

    @Test("an empty publication has no displayed identity")
    func emptyPublicationHasNoDisplayedIdentity() throws {
        let record = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: nil,
                publicationId: UUIDv7.generate(),
                revision: 1,
                desiredComparison: nil,
                desiredStatus: .ready,
                displayedPackage: nil,
                displayedPublicationId: nil,
                displayedComparison: nil
            )
        )
        #expect(record.displayed == nil)
        #expect(record.desired.status == .ready)
    }
}
