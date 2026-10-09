import Foundation
import Testing

@testable import AgentStudioBridge

func pullMetadataFrame(
    from pump: BridgeProductSchemeFramePump
) async throws -> BridgeProductMetadataFrame {
    guard case .frame(let delivery) = await pump.nextFrame() else {
        throw BridgePaneProductMetadataCoordinatorTestError.expectedFrame
    }
    #expect(await pump.acknowledgeFrameConsumed(delivery.receipt))
    let decoder = try BridgeProductMetadataFrameDecoder()
    let frames = try decoder.append(delivery.frame.data)
    return try #require(frames.first)
}

func controlExecutionToken(
    _ admission: BridgeProductSessionControlAdmission
) -> BridgeProductControlAdmissionToken? {
    guard case .execute(let token, _) = admission else { return nil }
    return token
}

enum BridgePaneProductMetadataCoordinatorTestError: Error {
    case expectedFrame
}

func reviewCommittedPresentationSnapshot(
    _: BridgeReviewPackage
) -> BridgePaneProductPresentationSnapshot {
    BridgePaneProductPresentationSnapshot(
        nativeActivity: .foreground,
        presentationRevision: 1,
        refreshingLanes: [],
        reviewComparison: nil
    )
}

enum CoordinatorReviewMetadataSourceError: Error {
    case unavailable
    case unknownSubscription
}

actor CoordinatorReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    private let event: BridgeProductReviewMetadataEvent?
    private var activeSubscriptionIds: Set<String> = []
    private(set) var cancelledSubscriptionIds: [String] = []
    private(set) var updatedItemIds: [String] = []

    init(event: BridgeProductReviewMetadataEvent?) {
        self.event = event
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {
        guard event != nil else { throw CoordinatorReviewMetadataSourceError.unavailable }
        activeSubscriptionIds.insert(subscription.subscriptionId)
    }

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        guard activeSubscriptionIds.contains(request.subscriptionId) else {
            throw CoordinatorReviewMetadataSourceError.unknownSubscription
        }
        guard event != nil else {
            throw CoordinatorReviewMetadataSourceError.unavailable
        }
        updatedItemIds = request.demand.interests.flatMap(\.itemIds)
        return nil
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        guard (productAdmission.withValidAdmission { true }) == true else {
            throw CancellationError()
        }
        return coordinatorReviewReservation(for: package, publicationId: publicationId)
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        guard reservation.packageId == publication.package.packageId,
            reservation.reviewGeneration == publication.package.reviewGeneration,
            reservation.revision == publication.package.revision,
            (productAdmission.withValidAdmission { true }) == true
        else { throw CoordinatorReviewMetadataSourceError.unavailable }
        return .deferred(retained: activeSubscriptionIds.count)
    }

    func cancel(subscriptionId: String) {
        activeSubscriptionIds.remove(subscriptionId)
        cancelledSubscriptionIds.append(subscriptionId)
    }
}

func coordinatorSourceAcceptedEvent() throws -> BridgePaneProductFileSourceFact {
    .sourceAccepted(
        try .init(
            repoId: "00000000-0000-4000-8000-000000000001",
            rootRevisionToken: "root-token-1",
            sourceCursor: "source-cursor-1",
            sourceId: "file-source-1",
            subscriptionGeneration: 1,
            worktreeId: "00000000-0000-4000-8000-000000000002"
        ))
}

func coordinatorReviewSourceAcceptedEvent() throws -> BridgeProductReviewMetadataEvent {
    try .init(
        generation: 7,
        packageId: "review-package-1",
        publicationId: UUID(uuidString: "11111111-1111-7111-8111-111111111111")!,
        revision: 11,
        sourceIdentity: "review-query-1"
    )
}

extension BridgeProductMetadataFrame {
    var streamSequenceForTest: Int {
        switch self {
        case .metadataStreamAccepted(let frame): frame.frameIdentity.streamSequence
        case .subscriptionAccepted(let frame): frame.frameIdentity.streamSequence
        case .batch(let frame): frame.identity.frame.streamSequence
        case .subscriptionReset(let frame): frame.identity.frameIdentity.streamSequence
        case .subscriptionCancelled(let frame): frame.identity.frameIdentity.streamSequence
        default: fatalError("Unexpected frame in contiguous stream assertion")
        }
    }
}

func coordinatorMetadataStreamRequest() throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-stream-1",
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}
