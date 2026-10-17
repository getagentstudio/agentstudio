import Foundation
import Testing

@testable import AgentStudioBridge

enum ReviewMetadataSourceTestError: Error {
    case unexpectedEvent
}

func deliverReviewPackage(
    _ package: BridgeReviewPackage,
    publicationId: UUID = reviewMetadataTestPublicationId,
    operationCorrelationID: String? = nil,
    classifiedRefreshImpact: BridgeReviewRefreshImpact? = nil,
    through source: BridgePaneProductReviewMetadataSource,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
    let reservation = try await source.reserve(
        package: package,
        publicationId: publicationId,
        productAdmission: productAdmission
    )
    return try await source.deliver(
        publication: reviewMetadataCommittedPublication(
            package,
            publicationId: publicationId,
            operationCorrelationID: operationCorrelationID,
            classifiedRefreshImpact: classifiedRefreshImpact
        ),
        reservation: reservation,
        productAdmission: productAdmission
    )
}

func reviewMetadataCommittedPublication(
    _ package: BridgeReviewPackage,
    publicationId: UUID = reviewMetadataTestPublicationId,
    operationCorrelationID: String? = nil,
    classifiedRefreshImpact: BridgeReviewRefreshImpact? = nil
) -> BridgeReviewCommittedPublication {
    BridgeReviewCommittedPublication(
        publicationId: publicationId,
        package: package,
        delta: nil,
        contentHandles: [],
        comparisonPresentationRevision: 1,
        reviewComparison: nil,
        operationCorrelationID: operationCorrelationID,
        classifiedRefreshImpact: classifiedRefreshImpact
    )
}

func deliveredReviewReceipt(
    _ outcome: BridgePaneProductReviewMetadataPublicationOutcome
) throws -> BridgeReviewMetadataPublicationReceipt {
    guard case .delivered(let receipt) = outcome else {
        throw ReviewMetadataSourceTestError.unexpectedEvent
    }
    return receipt
}

var reviewMetadataTestPublicationId: UUID {
    UUID(uuidString: "11111111-1111-7111-8111-111111111111")!
}

func makeReviewPackage(
    itemCount: Int,
    includesContentRoles: Bool = true,
    comparisonOrigin: BridgeReviewComparisonOrigin? = nil,
    reviewedSubjectLabel: String? = nil
) -> BridgeReviewPackage {
    let repoId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let worktreeId = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    let items = (0..<itemCount).map { index in
        makeBridgeReviewItemDescriptor(
            itemId: String(format: "review-item-%05d", index),
            path: String(format: "Sources/Module%02d/File%05d.swift", index % 32, index),
            fileClass: .source,
            contentRoles: includesContentRoles ? nil : .init()
        )
    }
    let orderedItemIds = items.map(\.itemId)
    return BridgeReviewPackage(
        packageId: "review-package-1",
        schemaVersion: 1,
        reviewGeneration: 7,
        revision: 11,
        query: BridgeReviewQuery(
            queryId: "review-query-1",
            queryKind: .compare,
            repoId: repoId,
            worktreeId: worktreeId,
            baseEndpointId: "review-base-endpoint",
            headEndpointId: "review-head-endpoint",
            comparisonSemantics: .threeDot,
            pathScope: [],
            fileTarget: nil,
            viewFilter: BridgeViewFilter(showBinaryFiles: true, showLargeFiles: true),
            grouping: BridgeChangeGrouping(kind: .folder),
            provenanceFilter: BridgeProvenanceFilter()
        ),
        baseEndpoint: reviewMetadataTestEndpoint(
            endpointId: "review-base-endpoint",
            kind: .gitRef,
            repoId: repoId,
            worktreeId: worktreeId
        ),
        headEndpoint: reviewMetadataTestEndpoint(
            endpointId: "review-head-endpoint",
            kind: .workingTree,
            repoId: repoId,
            worktreeId: worktreeId
        ),
        orderedItemIds: orderedItemIds,
        itemsById: Dictionary(uniqueKeysWithValues: items.map { ($0.itemId, $0) }),
        groups: [],
        summary: BridgeReviewPackageSummary(
            filesChanged: itemCount,
            additions: itemCount,
            deletions: itemCount,
            visibleFileCount: itemCount,
            hiddenFileCount: 0
        ),
        filterState: BridgeViewFilter(showBinaryFiles: true, showLargeFiles: true),
        generatedAtUnixMilliseconds: 100,
        comparisonOrigin: comparisonOrigin,
        reviewedSubjectLabel: reviewedSubjectLabel
    )
}

func replacingReviewItem(
    in package: BridgeReviewPackage,
    itemId: String,
    fileClass: BridgeFileClass,
    revision: Int
) -> BridgeReviewPackage {
    var itemsById = package.itemsById
    let previous = itemsById[itemId]!
    itemsById[itemId] = makeBridgeReviewItemDescriptor(
        itemId: itemId,
        path: previous.headPath ?? previous.basePath ?? itemId,
        fileClass: fileClass,
        contentRoles: previous.contentRoles
    )
    return replacingReviewPackage(package, revision: revision, itemsById: itemsById)
}

private func reviewMetadataTestEndpoint(
    endpointId: String,
    kind: BridgeSourceEndpoint.Kind,
    repoId: UUID,
    worktreeId: UUID
) -> BridgeSourceEndpoint {
    BridgeSourceEndpoint(
        endpointId: endpointId,
        kind: kind,
        repoId: repoId,
        worktreeId: worktreeId,
        label: endpointId,
        createdAtUnixMilliseconds: 100,
        contentSetHash: nil,
        providerIdentity: "provider:\(endpointId)"
    )
}

func replacingReviewSource(
    _ package: BridgeReviewPackage,
    packageId: String,
    queryId: String,
    generation: Int
) -> BridgeReviewPackage {
    let query = BridgeReviewQuery(
        queryId: queryId,
        queryKind: package.query.queryKind,
        repoId: package.query.repoId,
        worktreeId: package.query.worktreeId,
        baseEndpointId: package.query.baseEndpointId,
        headEndpointId: package.query.headEndpointId,
        comparisonSemantics: package.query.comparisonSemantics,
        pathScope: package.query.pathScope,
        fileTarget: package.query.fileTarget,
        viewFilter: package.query.viewFilter,
        grouping: package.query.grouping,
        provenanceFilter: package.query.provenanceFilter
    )
    return BridgeReviewPackage(
        packageId: packageId,
        schemaVersion: package.schemaVersion,
        reviewGeneration: BridgeReviewGeneration(generation),
        revision: 0,
        query: query,
        baseEndpoint: package.baseEndpoint,
        headEndpoint: package.headEndpoint,
        orderedItemIds: package.orderedItemIds,
        itemsById: package.itemsById,
        groups: package.groups,
        summary: package.summary,
        filterState: package.filterState,
        generatedAtUnixMilliseconds: package.generatedAtUnixMilliseconds,
        changesetCluster: package.changesetCluster,
        comparisonOrigin: package.comparisonOrigin,
        reviewedSubjectLabel: package.reviewedSubjectLabel
    )
}

func replacingReviewPackage(
    _ package: BridgeReviewPackage,
    revision: Int,
    itemsById: [String: BridgeReviewItemDescriptor]
) -> BridgeReviewPackage {
    BridgeReviewPackage(
        packageId: package.packageId,
        schemaVersion: package.schemaVersion,
        reviewGeneration: package.reviewGeneration,
        revision: revision,
        query: package.query,
        baseEndpoint: package.baseEndpoint,
        headEndpoint: package.headEndpoint,
        orderedItemIds: package.orderedItemIds,
        itemsById: itemsById,
        groups: package.groups,
        summary: package.summary,
        filterState: package.filterState,
        generatedAtUnixMilliseconds: package.generatedAtUnixMilliseconds,
        changesetCluster: package.changesetCluster,
        comparisonOrigin: package.comparisonOrigin,
        reviewedSubjectLabel: package.reviewedSubjectLabel
    )
}

func replacingReviewOrigin(
    _ package: BridgeReviewPackage,
    revision: Int,
    comparisonOrigin: BridgeReviewComparisonOrigin,
    reviewedSubjectLabel: String?
) -> BridgeReviewPackage {
    BridgeReviewPackage(
        packageId: package.packageId,
        schemaVersion: package.schemaVersion,
        reviewGeneration: package.reviewGeneration,
        revision: revision,
        query: package.query,
        baseEndpoint: package.baseEndpoint,
        headEndpoint: package.headEndpoint,
        orderedItemIds: package.orderedItemIds,
        itemsById: package.itemsById,
        groups: package.groups,
        summary: package.summary,
        filterState: package.filterState,
        generatedAtUnixMilliseconds: package.generatedAtUnixMilliseconds,
        changesetCluster: package.changesetCluster,
        comparisonOrigin: comparisonOrigin,
        reviewedSubjectLabel: reviewedSubjectLabel
    )
}

func reviewItemWithDiffStatistics(
    _ item: BridgeReviewItemDescriptor,
    additions: Int,
    deletions: Int
) -> BridgeReviewItemDescriptor {
    BridgeReviewItemDescriptor(
        itemId: item.itemId,
        itemKind: item.itemKind,
        itemVersion: item.itemVersion,
        basePath: item.basePath,
        headPath: item.headPath,
        changeKind: item.changeKind,
        fileClass: item.fileClass,
        language: item.language,
        extension: item.extension,
        sizeBytes: item.sizeBytes,
        baseContentHash: item.baseContentHash,
        headContentHash: item.headContentHash,
        contentHashAlgorithm: item.contentHashAlgorithm,
        additions: additions,
        deletions: deletions,
        isHiddenByDefault: item.isHiddenByDefault,
        hiddenReason: item.hiddenReason,
        reviewPriority: item.reviewPriority,
        contentRoles: item.contentRoles,
        cacheKey: item.cacheKey,
        provenance: item.provenance,
        annotationSummary: item.annotationSummary,
        reviewState: item.reviewState,
        collapsed: item.collapsed
    )
}

func reviewSubscription() -> BridgeProductSubscriptionSnapshot {
    BridgeProductSubscriptionSnapshot(
        subscription: .reviewMetadata,
        subscriptionId: "review-subscription-1",
        subscriptionKind: .reviewMetadata,
        workerDerivationEpoch: 1
    )
}

func reviewTestViewScopeRequest(
    itemIds: [String],
    handle: String = "review-availability-handle"
) throws -> BridgeProductViewScopeRequest {
    let interests: [[String: Any]] =
        itemIds.isEmpty
        ? [] : [["lane": "foreground", "itemIds": itemIds]]
    let data = try JSONSerialization.data(withJSONObject: [
        "kind": "subscription.setScope",
        "wireVersion": BridgeProductWireContract.version,
        "paneSessionId": "pane-session-1",
        "workerInstanceId": "worker-instance-1",
        "requestId": "review-test-scope",
        "requestSequence": 3,
        "subscriptionId": "review-subscription-1",
        "subscriptionKind": "review.metadata",
        "domain": "default",
        "handle": handle,
        "incarnation": "review-test-incarnation",
        "scopeRevision": 1,
        "scope": ["kind": "review", "interests": interests],
    ])
    return try BridgeProductStrictJSON.decode(BridgeProductViewScopeRequest.self, from: data)
}

func reviewViewDemand(itemIds: [String]) throws -> BridgeProductReviewMetadataInterestState {
    guard !itemIds.isEmpty else { return BridgeProductReviewMetadataInterestState(interests: []) }
    return BridgeProductReviewMetadataInterestState(
        interests: [try BridgeProductReviewMetadataInterestStateGroup(itemIds: itemIds, lane: .foreground)]
    )
}

func applyReviewViewDemand(
    through source: any BridgePaneProductReviewMetadataProducing,
    subscriptionId: String = "review-subscription-1",
    handle: String = "review-handle-1",
    scopeRevision: Int = 1,
    admissionSequence: Int? = nil,
    itemIds: [String],
    expectedPublicationId: UUID = reviewMetadataTestPublicationId,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgePaneProductReviewViewCapture? {
    try await source.applyViewDemand(
        .init(
            subscriptionId: subscriptionId,
            handle: handle,
            scopeRevision: scopeRevision,
            admissionSequence: admissionSequence ?? scopeRevision,
            demand: reviewViewDemand(itemIds: itemIds),
            expectedPublicationId: expectedPublicationId,
            productAdmission: productAdmission
        ))
}
