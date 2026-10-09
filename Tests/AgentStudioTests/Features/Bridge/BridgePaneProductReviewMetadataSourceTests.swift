import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge pane product Review metadata source")
struct BridgePaneProductReviewMetadataSourceTests {
    @Test("typed Review capture freezes the committed package with one N10 revision")
    func keyedBatchCaptureUsesCommittedPublication() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 2)
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )
        let outcome = try await deliverReviewPackage(
            package,
            through: source,
            productAdmission: productAdmission.context
        )
        let receipt = try deliveredReviewReceipt(outcome)
        #expect(receipt.publishedSubscriptions == 1)

        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        let snapshot = capture.snapshot
        #expect(capture.handle == "review-handle-1")
        #expect(capture.scopeRevision == 1)
        #expect(capture.publicationId == reviewMetadataTestPublicationId)
        #expect(snapshot.targetRevision > 0)
        #expect(snapshot.publication.revision == snapshot.targetRevision)
        #expect(snapshot.publication.displayed?.packageId == package.packageId)
        #expect(snapshot.items.map(\.record.itemId) == package.orderedItemIds)
        #expect(snapshot.items.allSatisfy { $0.revision == snapshot.targetRevision })
        #expect(
            try await applyReviewViewDemand(
                through: source,
                subscriptionId: "unknown-subscription",
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) == nil
        )
    }

    @Test("origin change replaces the keyed Review publication and its subject")
    func originChangeResetsMetadataAndProjectsSuccessorOriginAndSubject() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let initialOrigin = BridgeReviewComparisonOrigin.contribution(
            BridgeReviewContributionOrigin(
                symbolicTarget: .branch(name: "main"),
                resolvedTargetOID: "target-oid-1",
                reviewedHeadOID: "head-oid-1",
                baseRole: .commonCommit,
                baseOID: "base-oid-1"
            )
        )
        let successorOrigin = BridgeReviewComparisonOrigin.contribution(
            BridgeReviewContributionOrigin(
                symbolicTarget: .branch(name: "main"),
                resolvedTargetOID: "target-oid-2",
                reviewedHeadOID: "head-oid-2",
                baseRole: .commonCommit,
                baseOID: "base-oid-2"
            )
        )
        let initialPackage = makeReviewPackage(
            itemCount: 1,
            comparisonOrigin: initialOrigin,
            reviewedSubjectLabel: "feature/review"
        )
        let successorPackage = replacingReviewOrigin(
            initialPackage,
            revision: initialPackage.revision + 1,
            comparisonOrigin: successorOrigin,
            reviewedSubjectLabel: "feature/review"
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

        _ = try await deliverReviewPackage(
            successorPackage,
            through: source,
            productAdmission: productAdmission.context
        )

        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: successorPackage.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        let snapshot = capture.snapshot
        #expect(snapshot.publication.displayed?.comparisonOrigin == successorOrigin)
        #expect(snapshot.publication.displayed?.reviewedSubjectLabel == "feature/review")
        #expect(snapshot.publication.displayed?.packageId == successorPackage.packageId)
        #expect(snapshot.items.map(\.record.itemId) == successorPackage.orderedItemIds)
    }

    @Test("first empty-interest Review scope seals all 3,420 ordered keyed items")
    func opensWithCompleteOrderedWindows() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 3420)
        let source = BridgePaneProductReviewMetadataSource()

        try await source.open(
            subscription: reviewSubscription(), productAdmission: productAdmission.context
        )
        let outcome = try await deliverReviewPackage(
            package,
            through: source,
            productAdmission: productAdmission.context
        )
        let receipt = try deliveredReviewReceipt(outcome)
        #expect(receipt.publishedSubscriptions == 1)
        #expect(receipt.emittedEvents == 0)
        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: [],
                productAdmission: productAdmission.context
            )
        )
        let snapshot = capture.snapshot
        #expect(snapshot.items.count == 3420)
        let preservesPackageOrder = zip(snapshot.items, package.orderedItemIds).allSatisfy {
            $0.0.record.itemId == $0.1
        }
        #expect(preservesPackageOrder)
        let scope = BridgeProductJSONValue.object([
            "kind": .string("review"),
            "interests": .array([]),
        ])
        let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: .init(
                    viewId: "review-subscription-1", domain: .singleDomain, incarnation: "review-incarnation-1"
                ),
                handle: "review-handle-1",
                scopeRevision: 1,
                scope: scope,
                firstDeliverySequence: 1,
                targetRevision: snapshot.targetRevision,
                publication: snapshot.publication,
                items: snapshot.items
            )
        )
        #expect(batch.parts.count == 3421)
        #expect(batch.frameCount == 3423)
        let keyedItems = batch.parts.compactMap { part -> String? in
            guard case .put(let key, _, _) = part, key != "publication" else { return nil }
            return key
        }
        let hasExactItemKeys = Set(keyedItems) == Set(package.orderedItemIds)
        #expect(hasExactItemKeys)
    }

    @Test("view publication records carry no operation correlation")
    func admittedReviewPublicationCarriesOperationCorrelation() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 2)
        let operationCorrelationID = String(repeating: "d", count: 64)
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )

        _ = try await deliverReviewPackage(
            package,
            operationCorrelationID: operationCorrelationID,
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
        let snapshot = capture.snapshot
        let encoded = try #require(String(data: JSONEncoder().encode(snapshot.publication), encoding: .utf8))
        #expect(!encoded.contains("operationCorrelationId"))
    }

    @Test("new Review view demand preserves complete package order")
    func changedViewDemandKeepsCompletePackageOrder() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 4)
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            package,
            through: source,
            productAdmission: productAdmission.context
        )
        let firstItemId = try #require(package.orderedItemIds.first)
        let lastItemId = try #require(package.orderedItemIds.last)

        let firstCapture = try #require(
            try await applyReviewViewDemand(
                through: source,
                scopeRevision: 1,
                itemIds: [lastItemId],
                productAdmission: productAdmission.context
            )
        )
        #expect(firstCapture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)

        let changedCapture = try #require(
            try await applyReviewViewDemand(
                through: source,
                scopeRevision: 2,
                itemIds: [lastItemId, firstItemId],
                productAdmission: productAdmission.context
            )
        )
        #expect(changedCapture.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
        #expect(changedCapture.snapshot.items.map(\.record.sortKey) == [0, 1, 2, 3])
    }

    @Test("Review view capture rejects stale scope revisions and superseded publications")
    func staleViewCaptureIsRejectedAfterScopeOrPublicationSupersedesIt() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let firstPackage = makeReviewPackage(itemCount: 2)
        let secondPackage = makeReviewPackage(itemCount: 3)
        let successorPublicationId = UUID(uuidString: "22222222-2222-7222-8222-222222222222")!
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            firstPackage,
            through: source,
            productAdmission: productAdmission.context
        )
        let currentCapture = try #require(
            try await applyReviewViewDemand(
                through: source,
                scopeRevision: 4,
                itemIds: firstPackage.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        #expect(currentCapture.publicationId == reviewMetadataTestPublicationId)

        _ = try await deliverReviewPackage(
            secondPackage,
            publicationId: successorPublicationId,
            through: source,
            productAdmission: productAdmission.context
        )
        #expect(
            try await applyReviewViewDemand(
                through: source,
                scopeRevision: 3,
                itemIds: firstPackage.orderedItemIds,
                productAdmission: productAdmission.context
            ) == nil
        )
        #expect(
            try await applyReviewViewDemand(
                through: source,
                scopeRevision: 5,
                itemIds: secondPackage.orderedItemIds,
                expectedPublicationId: reviewMetadataTestPublicationId,
                productAdmission: productAdmission.context
            ) == nil
        )
        let successorCapture = try #require(
            try await applyReviewViewDemand(
                through: source,
                scopeRevision: 6,
                itemIds: secondPackage.orderedItemIds,
                expectedPublicationId: successorPublicationId,
                productAdmission: productAdmission.context
            )
        )
        #expect(successorCapture.publicationId == successorPublicationId)
        #expect(successorCapture.snapshot.items.map(\.record.itemId) == secondPackage.orderedItemIds)
    }

    @Test("older admission sequence cannot replace a newer Review role scope")
    func olderAdmissionSequenceCannotReplaceReviewRoleScope() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(itemCount: 2)
        let selectedItemId = try #require(package.orderedItemIds.first)
        let otherItemId = try #require(package.orderedItemIds.last)
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            package, through: source, productAdmission: productAdmission.context
        )
        let current = try #require(
            try await applyReviewViewDemand(
                through: source, handle: "review-handle-new", scopeRevision: 4,
                admissionSequence: 10, itemIds: [selectedItemId],
                productAdmission: productAdmission.context
            )
        )
        #expect(current.snapshot.items.map(\.record.itemId) == package.orderedItemIds)

        #expect(
            try await applyReviewViewDemand(
                through: source, handle: "review-handle-stale", scopeRevision: 5,
                admissionSequence: 9, itemIds: [otherItemId],
                productAdmission: productAdmission.context
            ) == nil
        )
        let retained = try #require(
            try await applyReviewViewDemand(
                through: source, handle: "review-handle-new", scopeRevision: 5,
                admissionSequence: 11, itemIds: [selectedItemId],
                productAdmission: productAdmission.context
            )
        )
        #expect(retained.snapshot.items.map(\.record.itemId) == package.orderedItemIds)
    }

    @Test("diff statistics do not publish unverified full-content extent facts")
    func omitsUnverifiedExtentFacts() async throws {
        // Arrange
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let originalPackage = makeReviewPackage(itemCount: 1)
        let itemId = try #require(originalPackage.orderedItemIds.first)
        let originalItem = try #require(originalPackage.itemsById[itemId])
        let package = replacingReviewPackage(
            originalPackage,
            revision: originalPackage.revision,
            itemsById: [
                itemId: reviewItemWithDiffStatistics(
                    originalItem,
                    additions: 2,
                    deletions: 1
                )
            ]
        )
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(),
            productAdmission: productAdmission.context
        )

        // Act
        _ = try await deliverReviewPackage(
            package,
            through: source,
            productAdmission: productAdmission.context
        )

        // Assert
        let capture = try #require(
            try await applyReviewViewDemand(
                through: source,
                itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        let itemMetadata = try #require(capture.snapshot.items.first?.record)
        #expect(itemMetadata.additions == 2)
        #expect(itemMetadata.deletions == 1)
        #expect(itemMetadata.extentByRole.base == nil)
        #expect(itemMetadata.extentByRole.diff == nil)
        #expect(itemMetadata.extentByRole.file == nil)
        #expect(itemMetadata.extentByRole.head == nil)
    }

    @Test("same-id successor replaces keyed items at a newer view revision")
    func sameIdSuccessorReplacesKeyedItems() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let initialPackage = makeReviewPackage(itemCount: 32)
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
            initialPackage, through: source, productAdmission: productAdmission.context
        )
        let first = try #require(
            try await applyReviewViewDemand(
                through: source, itemIds: [],
                productAdmission: productAdmission.context
            )
        )

        let outcome = try await deliverReviewPackage(
            successor, through: source, productAdmission: productAdmission.context
        )
        let replacement = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 2,
                itemIds: [], productAdmission: productAdmission.context
            )
        )
        #expect(try deliveredReviewReceipt(outcome).emittedEvents == 0)
        #expect(replacement.snapshot.targetRevision > first.snapshot.targetRevision)
        #expect(replacement.snapshot.publication.revision == replacement.snapshot.targetRevision)
        #expect(replacement.snapshot.items.map(\.record.itemId) == successor.orderedItemIds)
        #expect(
            replacement.snapshot.items.first { $0.record.itemId == changedItemId }?.record.fileClass
                == .config
        )
        #expect(replacement.snapshot.items.allSatisfy { $0.revision == replacement.snapshot.targetRevision })
    }

    @Test("source identity replacement seals an explicit empty ready snapshot")
    func sourceIdentityReplacementSealsEmptySnapshot() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let initialPackage = makeReviewPackage(itemCount: 2)
        let emptyPackage = replacingReviewSource(
            makeReviewPackage(itemCount: 0),
            packageId: "review-package-empty-successor",
            queryId: "review-query-empty-successor",
            generation: initialPackage.reviewGeneration.rawValue + 1
        )
        let successorPublicationId = UUID(uuidString: "22222222-2222-7222-8222-222222222222")!
        let source = BridgePaneProductReviewMetadataSource()
        try await source.open(
            subscription: reviewSubscription(), productAdmission: productAdmission.context
        )
        _ = try await deliverReviewPackage(
            initialPackage, through: source, productAdmission: productAdmission.context
        )
        let first = try #require(
            try await applyReviewViewDemand(
                through: source, itemIds: initialPackage.orderedItemIds,
                productAdmission: productAdmission.context
            )
        )
        _ = try await deliverReviewPackage(
            emptyPackage, publicationId: successorPublicationId,
            through: source, productAdmission: productAdmission.context
        )
        let empty = try #require(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 2, itemIds: [],
                expectedPublicationId: successorPublicationId,
                productAdmission: productAdmission.context
            )
        )
        #expect(first.snapshot.items.count == 2)
        #expect(empty.snapshot.items.isEmpty)
        let displayed = try #require(empty.snapshot.publication.displayed)
        #expect(displayed.packageId == emptyPackage.packageId)
        #expect(displayed.publicationId == successorPublicationId)
        #expect(displayed.generation == emptyPackage.reviewGeneration.rawValue)
        #expect(displayed.revision == emptyPackage.revision)
        #expect(displayed.query.queryId == emptyPackage.query.queryId)
        #expect(empty.snapshot.publication.desired.status == .ready)
        #expect(empty.snapshot.publication.publicationId == successorPublicationId)
        let batch = try BridgeProductReviewViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: .init(
                    viewId: "review-subscription-1", domain: .singleDomain,
                    incarnation: "review-incarnation-empty"
                ),
                handle: empty.handle, scopeRevision: empty.scopeRevision,
                scope: .object(["kind": .string("review"), "interests": .array([])]),
                firstDeliverySequence: 1,
                targetRevision: empty.snapshot.targetRevision,
                publication: empty.snapshot.publication, items: empty.snapshot.items
            )
        )
        #expect(batch.parts.count == 1)
        #expect(batch.frameCount == 3)
    }

    @Test("reservation does not expose a package until explicit delivery")
    func reservationDoesNotCreateGlobalPackageAvailability() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let package = makeReviewPackage(itemCount: 4)
        let reservation = try await source.reserve(
            package: package, publicationId: reviewMetadataTestPublicationId,
            productAdmission: productAdmission.context
        )
        try await source.open(
            subscription: reviewSubscription(), productAdmission: productAdmission.context
        )
        #expect(
            try await applyReviewViewDemand(
                through: source, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) == nil
        )
        _ = try await source.deliver(
            publication: reviewMetadataCommittedPublication(package), reservation: reservation,
            productAdmission: productAdmission.context
        )
        #expect(
            try await applyReviewViewDemand(
                through: source, scopeRevision: 2, itemIds: package.orderedItemIds,
                productAdmission: productAdmission.context
            ) != nil
        )
    }

    @Test("reservation rejects an invalid package before delivery")
    func reservationRejectsInvalidPackageBeforeDelivery() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let validPackage = makeReviewPackage(itemCount: 4)
        let invalidPackage = replacingReviewSource(
            validPackage, packageId: "review-package-invalid-reservation",
            queryId: "review-query-invalid-reservation", generation: -1
        )
        await #expect(throws: DecodingError.self) {
            _ = try await source.reserve(
                package: invalidPackage, publicationId: reviewMetadataTestPublicationId,
                productAdmission: productAdmission.context
            )
        }
    }

    @Test("closed admission cannot install a reserved Review package")
    func closedAdmissionPreventsCommit() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let source = BridgePaneProductReviewMetadataSource()
        let package = makeReviewPackage(itemCount: 4)
        try await source.open(
            subscription: reviewSubscription(), productAdmission: productAdmission.context
        )
        let reservation = try await source.reserve(
            package: package, publicationId: reviewMetadataTestPublicationId,
            productAdmission: productAdmission.context
        )
        productAdmission.close()
        await #expect(throws: BridgePaneProductReviewMetadataSourceError.self) {
            _ = try await source.deliver(
                publication: reviewMetadataCommittedPublication(package), reservation: reservation,
                productAdmission: productAdmission.context
            )
        }
    }
}
