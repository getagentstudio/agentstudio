import Foundation

struct BridgeProductReviewBatchPublicationInput: Sendable {
    let classifiedRefreshImpact: BridgeReviewRefreshImpact?
    let publicationId: UUID
    let revision: Int
    let desiredComparison: BridgePaneReviewComparisonPresentation?
    let desiredStatus: BridgeProductReviewBatchDesiredPublication.Status
    let displayedPackage: BridgeReviewPackage?
    let displayedPublicationId: UUID?
    let displayedComparison: BridgePaneReviewComparisonPresentation?
}

enum BridgeProductReviewBatchPublicationProjectionError: Error {
    case mismatchedDisplayedIdentity
}

/// Keeps the desired comparison separate from the last readable displayed one.
enum BridgeProductReviewBatchPublicationProjection {
    static func record(
        from input: BridgeProductReviewBatchPublicationInput
    ) throws -> BridgeProductReviewBatchPublicationRecord {
        guard (input.displayedPackage == nil) == (input.displayedPublicationId == nil) else {
            throw BridgeProductReviewBatchPublicationProjectionError.mismatchedDisplayedIdentity
        }
        let displayed: BridgeProductReviewBatchDisplayedPublication?
        if let package = input.displayedPackage, let displayedPublicationId = input.displayedPublicationId {
            displayed = try .init(
                package: package,
                publicationId: displayedPublicationId,
                reviewComparison: input.displayedComparison
            )
        } else {
            displayed = nil
        }
        return try .init(
            classifiedRefreshImpact: input.classifiedRefreshImpact,
            desired: .init(
                reviewComparison: input.desiredComparison,
                status: input.desiredStatus
            ),
            displayed: displayed,
            publicationId: input.publicationId,
            revision: input.revision
        )
    }
}

extension BridgeProductReviewBatchDesiredPublication {
    init(reviewComparison: BridgePaneReviewComparisonPresentation?, status: Status) {
        self.reviewComparison = reviewComparison
        self.status = status
    }
}

extension BridgeProductReviewBatchDisplayedPublication {
    init(
        package: BridgeReviewPackage,
        publicationId: UUID,
        reviewComparison: BridgePaneReviewComparisonPresentation?
    ) throws {
        baseEndpoint = try productEndpoint(package.baseEndpoint)
        comparisonOrigin = package.comparisonOrigin
        generation = package.reviewGeneration.rawValue
        headEndpoint = try productEndpoint(package.headEndpoint)
        packageId = package.packageId
        self.publicationId = publicationId
        query = try productQuery(package.query)
        self.reviewComparison = reviewComparison
        reviewedSubjectLabel = package.reviewedSubjectLabel
        revision = package.revision
        summary = try productSummary(package.summary)
    }
}

extension BridgeProductReviewBatchPublicationRecord {
    init(
        classifiedRefreshImpact: BridgeReviewRefreshImpact? = nil,
        desired: BridgeProductReviewBatchDesiredPublication,
        displayed: BridgeProductReviewBatchDisplayedPublication?,
        publicationId: UUID,
        revision: Int
    ) throws {
        _ = try BridgeProductReviewPublicationIdContract.decode(
            publicationId.uuidString.lowercased(),
            codingPath: []
        )
        try BridgeProductContractDecoding.validatePositive(
            revision,
            name: "Review publication revision",
            codingPath: []
        )
        self.desired = desired
        self.classifiedRefreshImpact = classifiedRefreshImpact
        self.displayed = displayed
        self.publicationId = publicationId
        recordKind = "publication"
        self.revision = revision
    }
}
