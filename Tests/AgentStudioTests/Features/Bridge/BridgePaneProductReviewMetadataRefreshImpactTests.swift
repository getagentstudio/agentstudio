import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge pane product Review metadata refresh impact")
struct BridgePaneProductReviewMetadataRefreshImpactTests {
    @Test("same-looking unclassified successor replaces the keyed item")
    func sameLookingUnclassifiedSuccessorRemainsReplacement() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let initialPackage = makeReviewPackage(itemCount: 2)
        let changedItemId = try #require(initialPackage.orderedItemIds.first)
        let successor = replacingReviewItem(
            in: initialPackage,
            itemId: changedItemId,
            fileClass: .config,
            revision: initialPackage.revision + 1
        )
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            initialPackage,
            through: source,
            productAdmission: productAdmission.context
        )
        let first = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: initialPackage.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )

        _ = try await deliverReviewPackage(
            successor,
            through: source,
            productAdmission: productAdmission.context
        )
        let replacement = try #require(
            try await applyReviewViewDemand(
                through: source,
                scopeRevision: 2,
                itemIds: successor.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )

        #expect(replacement.snapshot.targetRevision > first.snapshot.targetRevision)
        #expect(replacement.snapshot.publication.publicationId == first.snapshot.publication.publicationId)
        #expect(
            replacement.snapshot.items.first { $0.record.itemId == changedItemId }?.record.fileClass
                == .config
        )
    }

    @Test("classified refresh seals a complete keyed Review batch")
    func classifiedRefreshSealsCompleteBatch() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 130)
        let impact = BridgeReviewRefreshImpact.exact(
            newlyImportedCommitCount: 10,
            affectedFileCount: 2,
            addedLineCount: 4,
            deletedLineCount: 3,
            affectedStableFileIdentities: ["review-item-00000", "review-item-00001"]
        )
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            package,
            classifiedRefreshImpact: impact,
            through: source,
            productAdmission: productAdmission.context
        )

        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        let batch = try sealReviewCapture(capture)
        #expect(batch.parts.count == 131)
        #expect(batch.frameCount == 133)
        #expect(capture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
    }

    @Test("symbolic unknown impact admits a keyed batch beyond the old metadata-window limit")
    func carriesSymbolicUnknownForLargeReview() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 4097)
        let impact = BridgeReviewRefreshImpact.unknown(
            displayedPackage: package,
            candidatePackage: package
        )
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            package,
            classifiedRefreshImpact: impact,
            through: source,
            productAdmission: productAdmission.context
        )

        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        let batch = try sealReviewCapture(capture)
        #expect(impact.affectedStableFileIdentities.isEmpty)
        #expect(capture.snapshot.items.count == 4097)
        #expect(batch.parts.count == 4098)
    }
}

private func sealReviewCapture(
    _ capture: BridgePaneProductReviewViewCapture
) throws -> BridgeProductSealedViewBatch {
    try BridgeProductReviewViewBatchFactory.sealSnapshot(
        .init(
            viewDomain: .init(
                viewId: "review-subscription-1", domain: .singleDomain,
                incarnation: "review-incarnation-1"
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
}
