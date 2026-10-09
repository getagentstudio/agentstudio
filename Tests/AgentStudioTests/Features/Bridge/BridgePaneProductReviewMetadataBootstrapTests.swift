import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge pane product Review metadata bootstrap")
struct BridgePaneProductReviewMetadataBootstrapTests {
    @Test("reopened subscriber captures the complete current package as one keyed snapshot")
    func reopenedSubscriberCapturesCompleteCurrentPackage() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let subscription = reviewSubscription()
        let package = makeReviewPackage(itemCount: 4)
        try await source.open(
            subscription: subscription,
            productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            package,
            through: source,
            productAdmission: productAdmission.context
        )
        await source.cancel(subscriptionId: subscription.subscriptionId)

        // Act
        try await source.open(
            subscription: subscription,
            productAdmission: productAdmission.context
        )
        #expect(
            try await applyReviewViewDemand(
                through: source,
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) == nil
        )
        let outcome = try await deliverReviewPackage(
            package,
            through: source,
            productAdmission: productAdmission.context
        )

        // Assert
        let receipt = try deliveredReviewReceipt(outcome)
        #expect(receipt.publishedSubscriptions == 1)
        #expect(receipt.emittedEvents == 0)
        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        #expect(capture.publicationId == reviewMetadataTestPublicationId)
        #expect(capture.snapshot.publication.displayed?.packageId == package.packageId)
        #expect(capture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
    }

    @Test("open before publication stays pending until a committed package is delivered")
    func openBeforePublicationCapturesOnlyAfterDelivery() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let package = makeReviewPackage(itemCount: 4)
        try await source.open(
            subscription: reviewSubscription(), productAdmission: productAdmission.context
        )
        #expect(
            try await applyReviewViewDemand(
                through: source, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) == nil
        )
        let outcome = try await deliverReviewPackage(
            package, through: source, productAdmission: productAdmission.context
        )
        let capture = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 2, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        #expect(try deliveredReviewReceipt(outcome).publishedSubscriptions == 1)
        #expect(capture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
    }

    @Test("cancelling a pending open leaves no package capture")
    func cancellationBeforePackagePublicationLeavesNoPendingResidue() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let subscription = reviewSubscription()
        let package = makeReviewPackage(itemCount: 4)
        try await source.open(subscription: subscription, productAdmission: productAdmission.context)
        await source.cancel(subscriptionId: subscription.subscriptionId)
        let outcome = try await deliverReviewPackage(
            package, through: source, productAdmission: productAdmission.context
        )
        #expect(outcome == .deferred(retained: 0))
        #expect(
            try await applyReviewViewDemand(
                through: source, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) == nil
        )
    }

    @Test("reopening the same subscription discards its prior package capture")
    func reopenedSubscriptionNeedsFreshDelivery() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let subscription = reviewSubscription()
        let package = makeReviewPackage(itemCount: 4)
        try await source.open(subscription: subscription, productAdmission: productAdmission.context)
        _ = try await deliverReviewPackage(
            package, through: source, productAdmission: productAdmission.context
        )
        #expect(
            try await applyReviewViewDemand(
                through: source, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) != nil
        )
        try await source.open(subscription: subscription, productAdmission: productAdmission.context)
        #expect(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 2, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) == nil
        )
        _ = try await deliverReviewPackage(
            package, through: source, productAdmission: productAdmission.context
        )
        #expect(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 3, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) != nil
        )
    }
}
