import AgentStudioTestSupport
import Foundation

@testable import AgentStudioBridge

actor CoordinatorTrackingReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    private let source = BridgePaneProductReviewMetadataSource()
    private var didRegisterOpen = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var publicationReceipt: BridgeReviewMetadataPublicationReceipt?
    private var publicationReceiptWaiters: [CheckedContinuation<BridgeReviewMetadataPublicationReceipt, Never>] = []

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        try await source.applyViewDemand(request)
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        try await source.open(
            subscription: subscription,
            productAdmission: productAdmission
        )
        didRegisterOpen = true
        let waiters = openWaiters
        openWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        try await source.reserve(
            package: package,
            publicationId: publicationId,
            productAdmission: productAdmission
        )
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        let outcome = try await source.deliver(
            publication: publication,
            reservation: reservation,
            productAdmission: productAdmission
        )
        if case .delivered(let receipt) = outcome {
            publicationReceipt = receipt
            let waiters = publicationReceiptWaiters
            publicationReceiptWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume(returning: receipt) }
        }
        return outcome
    }

    func cancel(subscriptionId: String) async {
        await source.cancel(subscriptionId: subscriptionId)
    }

    func waitUntilOpenRegistered() async {
        guard !didRegisterOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilPublicationReceipt() async -> BridgeReviewMetadataPublicationReceipt {
        if let publicationReceipt { return publicationReceipt }
        return await withCheckedContinuation { continuation in
            publicationReceiptWaiters.append(continuation)
        }
    }
}

actor CoordinatorReviewDeliveryDispositionProbe {
    private(set) var disposition: BridgeReviewPublicationDeliveryDisposition?

    func record(_ disposition: BridgeReviewPublicationDeliveryDisposition) {
        self.disposition = disposition
    }
}

@MainActor
final class CoordinatorCurrentReviewPublication {
    var publicationId: UUID

    init(publicationId: UUID) {
        self.publicationId = publicationId
    }

    func matches(
        _ publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) -> Bool {
        self.publicationId == publicationId
    }
}

actor CoordinatorSupersededDeliveryReviewMetadataSource:
    BridgePaneProductReviewMetadataProducing
{
    private var deliveryRelease: CheckedContinuation<Void, Never>?
    private var deliveryStarted = false
    private var deliveryStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var deliveryFinished = false
    private var deliveryFinishedWaiters: [CheckedContinuation<Void, Never>] = []
    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) {}

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgeReviewMetadataPublicationReservation {
        coordinatorReviewReservation(for: package, publicationId: publicationId)
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        defer {
            deliveryFinished = true
            let waiters = deliveryFinishedWaiters
            deliveryFinishedWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
        }
        deliveryStarted = true
        let waiters = deliveryStartedWaiters
        deliveryStartedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            deliveryRelease = continuation
        }
        return .delivered(
            .init(
                retained: 1,
                publishedSubscriptions: 1,
                emittedEvents: 0,
                superseded: 0,
                finalFrames: []
            ))
    }

    func cancel(subscriptionId _: String) {
        releaseDelivery()
    }

    func releaseDelivery() {
        deliveryRelease?.resume()
        deliveryRelease = nil
    }

    func waitUntilDeliveryStarted() async {
        guard !deliveryStarted else { return }
        await withCheckedContinuation { continuation in
            deliveryStartedWaiters.append(continuation)
        }
    }

    func waitUntilDeliveryFinished() async {
        guard !deliveryFinished else { return }
        await withCheckedContinuation { continuation in
            deliveryFinishedWaiters.append(continuation)
        }
    }
}

actor CoordinatorRepairingReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    private let source = BridgePaneProductReviewMetadataSource()
    private var deliverAttemptCount = 0
    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        try await source.open(subscription: subscription, productAdmission: productAdmission)
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        try await source.reserve(
            package: package, publicationId: publicationId, productAdmission: productAdmission
        )
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        deliverAttemptCount += 1
        if deliverAttemptCount == 1 {
            throw BridgePaneProductMetadataCoordinatorError.producerQueueReset
        }
        return try await source.deliver(
            publication: publication, reservation: reservation, productAdmission: productAdmission
        )
    }

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        try await source.applyViewDemand(request)
    }

    func cancel(subscriptionId: String) async {
        await source.cancel(subscriptionId: subscriptionId)
    }

    var deliveryAttempts: Int { deliverAttemptCount }
}

func coordinatorReviewPackageFixture() throws -> BridgeReviewPackage {
    let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
    let fixtureURL = projectRoot.appending(
        path: "Tests/BridgeContractFixtures/valid/bridge-review-package.json"
    )
    return try JSONDecoder().decode(
        BridgeReviewPackage.self,
        from: Data(contentsOf: fixtureURL)
    )
}

func coordinatorCommittedReviewPublication(
    _ package: BridgeReviewPackage
) -> BridgeReviewCommittedPublication {
    BridgeReviewCommittedPublication(
        publicationId: UUID(uuidString: "11111111-1111-7111-8111-111111111111")!,
        package: package,
        delta: nil,
        contentHandles: [],
        comparisonPresentationRevision: 1,
        reviewComparison: nil
    )
}

func coordinatorReviewReservation(
    for package: BridgeReviewPackage,
    publicationId: UUID
) -> BridgeReviewMetadataPublicationReservation {
    BridgeReviewMetadataPublicationReservation(
        reservationId: UUID(uuidString: "22222222-2222-7222-8222-222222222222")!,
        packageId: package.packageId,
        publicationId: publicationId,
        reviewGeneration: package.reviewGeneration,
        revision: package.revision,
        projectionPlan: try! BridgeReviewMetadataPublicationProjectionPlan.prepare(
            package: package,
            publicationId: publicationId
        )
    )
}
