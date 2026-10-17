import AgentStudioInfrastructure
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge Review complete empty publication identity")
struct BridgePaneProductReviewEmptyPublicationTests {
    @Test("first empty and A to empty B to main retain exact publication and comparison", arguments: [0, 2])
    func completeEmptyPublicationRetainsIdentity(firstItemCount: Int) async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(subscription: reviewSubscription(), productAdmission: productAdmission.context)
        let steps = [
            (itemCount: firstItemCount, target: "A"),
            (itemCount: 0, target: "B"),
            (itemCount: 2, target: "main"),
        ]
        for (index, step) in steps.enumerated() {
            let package = replacingReviewSource(
                makeReviewPackage(itemCount: step.itemCount),
                packageId: "complete-empty-package-\(index)",
                queryId: "complete-empty-query-\(index)",
                generation: 7 + index
            )
            let publicationId = UUIDv7.generate()
            let comparison = BridgePaneReviewComparisonPresentation(
                activeTarget: .branch(name: step.target),
                attempt: .settled(reviewGeneration: package.reviewGeneration.rawValue),
                displayedSnapshot: .current(
                    BridgePaneReviewDisplayedSnapshotIdentity(
                        packageId: package.packageId,
                        reviewGeneration: package.reviewGeneration.rawValue,
                        revision: package.revision
                    )
                )
            )
            let reservation = try await source.reserve(
                package: package,
                publicationId: publicationId,
                productAdmission: productAdmission.context
            )
            _ = try await source.deliver(
                publication: BridgeReviewCommittedPublication(
                    publicationId: publicationId,
                    package: package,
                    delta: nil,
                    contentHandles: [],
                    comparisonPresentationRevision: index + 1,
                    reviewComparison: comparison,
                    operationCorrelationID: nil,
                    classifiedRefreshImpact: nil
                ),
                reservation: reservation,
                productAdmission: productAdmission.context
            )
            let capture = try #require(
                try await applyReviewViewDemand(
                    through: source,
                    scopeRevision: index + 1,
                    itemIds: package.orderedItemIds,
                    expectedPublicationId: publicationId,
                    productAdmission: productAdmission.context
                )
            )
            let displayed = try #require(capture.snapshot.publication.displayed)
            #expect(displayed.packageId == package.packageId)
            #expect(displayed.publicationId == publicationId)
            #expect(displayed.generation == package.reviewGeneration.rawValue)
            #expect(displayed.revision == package.revision)
            #expect(displayed.query.queryId == package.query.queryId)
            #expect(displayed.reviewComparison == comparison)
            #expect(capture.snapshot.publication.desired.reviewComparison == comparison)
            #expect(capture.snapshot.items.count == step.itemCount)
            if step.itemCount == 0 {
                #expect(displayed.summary.filesChanged == 0)
                let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
                    .init(
                        viewDomain: .init(
                            viewId: "review-subscription-1", domain: .singleDomain,
                            incarnation: "complete-empty-incarnation"
                        ),
                        handle: capture.handle,
                        scopeRevision: capture.scopeRevision,
                        scope: .object(["kind": .string("review"), "interests": .array([])]),
                        firstDeliverySequence: 1,
                        targetRevision: capture.snapshot.targetRevision,
                        publication: capture.snapshot.publication,
                        items: capture.snapshot.items
                    )
                )
                #expect(batch.parts.count == 1)
                #expect(batch.frameCount == 3)
            }
        }
    }
}
