import Testing

@testable import AgentStudioBridge

@Suite("Bridge Review metadata publication projection plan")
struct BridgeReviewMetadataPublicationProjectionPlanTests {
    @Test("reservation carries one immutable projection plan into keyed delivery")
    func reservationCarriesProjectionPlanIntoDelivery() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 3420)
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )

        // Act
        let reservation = try await source.reserve(
            package: package,
            publicationId: reviewMetadataTestPublicationId,
            productAdmission: productAdmission.context
        )
        let outcome = try await source.deliver(
            publication: reviewMetadataCommittedPublication(package),
            reservation: reservation,
            productAdmission: productAdmission.context
        )

        // Assert
        let plan = reservation.projectionPlan
        #expect(plan.packageId == package.packageId)
        #expect(plan.publicationId == reviewMetadataTestPublicationId)
        #expect(plan.reviewGeneration == package.reviewGeneration)
        #expect(plan.revision == package.revision)
        #expect(plan.itemCount == package.orderedItemIds.count)
        #expect(try deliveredReviewReceipt(outcome).publishedSubscriptions == 1)
        #expect(try deliveredReviewReceipt(outcome).emittedEvents == 0)
        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        #expect(capture.snapshot.items.count == plan.itemCount)
        #expect(capture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
    }
}
