import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeReviewPublicationStateSnapshot {
    static let closed = Self(
        active: nil,
        acknowledgedDisplayed: nil,
        admitted: nil,
        pending: nil,
        retiring: [],
        activeContentLeaseCount: 0,
        isClosed: true
    )
}

extension BridgeReviewPublicationCommitResult {
    var committedPublication: BridgeReviewCommittedPublication? {
        guard case .committed(let committedPublication) = self else { return nil }
        return committedPublication
    }
}

@MainActor
func commitObserved(
    _ publication: BridgeReviewPreparedPublication,
    in coordinator: BridgeReviewPublicationCoordinator,
    productAdmission: BridgeProductAdmissionContext
) throws -> BridgeReviewCommittedPublication {
    let token = try #require(
        coordinator.stage(
            publication,
            productAdmission: productAdmission
        )
    )
    let committedPublication = try #require(
        coordinator.commit(
            token,
            productAdmission: productAdmission,
            captureCommittedPresentation: reviewCommittedPresentationSnapshot,
            presentCommitted: { _ in }
        ).committedPublication
    )
    #expect(
        coordinator.recordTransportDeliveryDisposition(
            .viewBatchSealed,
            publicationId: committedPublication.publicationId,
            productAdmission: productAdmission
        ) == .committed(delivery: .viewBatchSealed)
    )
    return committedPublication
}

func makeReviewPreparedPublication(
    suffix: String,
    reviewGeneration: BridgeReviewGeneration,
    revision: Int = 0
) async throws -> BridgeReviewPreparedPublication {
    let candidate = makeReviewPublicationCandidate(
        suffix: suffix,
        reviewGeneration: reviewGeneration
    )
    let revisedCandidate = BridgeReviewPublicationCandidate(
        package: candidate.package.withRevision(revision),
        delta: candidate.delta,
        contentHandles: candidate.contentHandles
    )
    return try #require(
        await BridgeReviewPreparedPublication.prepare(revisedCandidate)
    )
}

func makeReviewPublicationCandidate(
    suffix: String,
    reviewGeneration: BridgeReviewGeneration
) -> BridgeReviewPublicationCandidate {
    let itemId = "item-\(suffix)"
    let baseEndpoint = makeBridgeEndpoint(
        endpointId: "base-\(suffix)",
        kind: .gitRef
    )
    let headEndpoint = makeBridgeEndpoint(
        endpointId: "head-\(suffix)",
        kind: .workingTree
    )
    let contentHandle = makeBridgeContentHandle(
        itemId: itemId,
        role: .head,
        endpointId: headEndpoint.endpointId,
        reviewGeneration: reviewGeneration,
        contentHash: bridgeSHA256ContentHash("contents-\(suffix)")
    )
    let item = makeBridgeReviewItemDescriptor(
        itemId: itemId,
        path: "Sources/\(suffix).swift",
        fileClass: .source,
        contentRoles: .init(base: nil, head: contentHandle, diff: nil)
    )
    let package = BridgeReviewPackage(
        packageId: "package-\(suffix)",
        schemaVersion: 1,
        reviewGeneration: reviewGeneration,
        revision: 0,
        query: makeBridgeReviewQuery(
            baseEndpointId: baseEndpoint.endpointId,
            headEndpointId: headEndpoint.endpointId
        ),
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        orderedItemIds: [itemId],
        itemsById: [itemId: item],
        groups: [],
        summary: .init(
            filesChanged: 1,
            additions: 1,
            deletions: 0,
            visibleFileCount: 1,
            hiddenFileCount: 0
        ),
        filterState: BridgeViewFilter(),
        generatedAtUnixMilliseconds: 1
    )
    return BridgeReviewPublicationCandidate(
        package: package,
        delta: nil,
        contentHandles: [contentHandle]
    )
}

actor BridgeReviewPublicationDeliveryGate {
    private var isSuspended = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

actor BridgeReviewPublicationDeliveryProbe {
    private var publicationIds: [UUID] = []

    func recordDelivery(publicationId: UUID) {
        publicationIds.append(publicationId)
    }

    func deliveredPublicationIds() -> [UUID] {
        publicationIds
    }
}
