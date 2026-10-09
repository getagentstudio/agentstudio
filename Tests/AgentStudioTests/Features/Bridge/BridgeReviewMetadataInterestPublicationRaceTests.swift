import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Review metadata scope update during publication")
struct BridgeReviewMetadataInterestPublicationRaceTests {
    @Test("A to B to A demand retains current Review content descriptors without inventory churn")
    func returningDemandSeesCurrentDescriptors() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let package = makeReviewPackage(itemCount: 2)
        let firstItemID = try #require(package.orderedItemIds.first)
        let secondItemID = try #require(package.orderedItemIds.last)
        try await source.open(subscription: reviewSubscription(), productAdmission: admission.context)
        _ = try await deliverReviewPackage(package, through: source, productAdmission: admission.context)

        let firstCapture = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 1, itemIds: [firstItemID],
                productAdmission: admission.context
            )
        )
        let secondCapture = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 2, itemIds: [secondItemID],
                productAdmission: admission.context
            )
        )
        let returnCapture = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 3, itemIds: [firstItemID],
                productAdmission: admission.context
            )
        )

        for capture in [firstCapture, secondCapture, returnCapture] {
            #expect(capture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
        }
        let firstContent = try #require(
            firstCapture.snapshot.items.first { $0.record.itemId == firstItemID }?.record.contentByRole
        )
        let returningContent = try #require(
            returnCapture.snapshot.items.first { $0.record.itemId == firstItemID }?.record.contentByRole
        )
        #expect(returningContent == firstContent)
        await source.cancel(subscriptionId: "review-subscription-1")
    }

    @Test("a stale scope cannot strand a committed Review successor")
    func staleScopeAfterSuccessorPreservesCompletePublication() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let initialPackage = makeReviewPackage(itemCount: 4)
        let successor = replacingReviewSource(
            initialPackage,
            packageId: "review-interest-race-successor",
            queryId: "review-interest-race-query",
            generation: initialPackage.reviewGeneration.rawValue + 1
        )
        let successorPublicationId = UUID(uuidString: "22222222-2222-7222-8222-222222222222")!
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: admission.context
        )
        _ = try await deliverReviewPackage(
            initialPackage, through: source, productAdmission: admission.context
        )
        let selectedItemId = try #require(initialPackage.orderedItemIds.first)
        let first = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 1, admissionSequence: 1,
                itemIds: [selectedItemId],
                productAdmission: admission.context
            )
        )
        #expect(first.snapshot.items.map(\.record.itemId) == initialPackage.orderedItemIds)

        let outcome = try await deliverReviewPackage(
            successor, publicationId: successorPublicationId,
            through: source, productAdmission: admission.context
        )
        #expect(try deliveredReviewReceipt(outcome).publishedSubscriptions == 1)
        #expect(
            try await applyReviewViewDemand(
                through: source, handle: "review-stale-handle", scopeRevision: 3,
                admissionSequence: 0, itemIds: initialPackage.orderedItemIds,
                expectedPublicationId: reviewMetadataTestPublicationId,
                productAdmission: admission.context
            ) == nil
        )
        let capture = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 2, admissionSequence: 2,
                itemIds: successor.orderedItemIds,
                expectedPublicationId: successorPublicationId,
                productAdmission: admission.context
            )
        )
        #expect(capture.publicationId == successorPublicationId)
        #expect(capture.snapshot.publication.displayed?.packageId == successor.packageId)
        #expect(capture.snapshot.items.map(\.record.itemId) == successor.orderedItemIds)
        await source.cancel(subscriptionId: "review-subscription-1")
    }
}
