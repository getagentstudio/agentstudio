import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

@MainActor
final class AvailabilityReviewPublicationProvider {
    var publication: BridgeReviewCommittedPublication?
}

actor AvailabilityHeldReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    private let source = BridgePaneProductReviewMetadataSource()
    private let holdFirstDelivery: Bool
    private var firstDeliveryPublicationId: UUID?
    private let firstDelivery = HeldStep<UUID>("first Review metadata delivery", cancellation: .holdThroughCancellation)

    init(holdFirstDelivery: Bool = false) {
        self.holdFirstDelivery = holdFirstDelivery
    }

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
        if holdFirstDelivery && firstDeliveryPublicationId == nil {
            firstDeliveryPublicationId = reservation.publicationId
            try await firstDelivery.arrive(reservation.publicationId)
        }
        return try await source.deliver(
            publication: publication, reservation: reservation, productAdmission: productAdmission
        )
    }

    func waitUntilFirstDeliveryStarted() async throws -> UUID {
        try await firstDelivery.firstArrival()
    }

    func releaseFirstDelivery() { firstDelivery.release() }

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        try await source.applyViewDemand(request)
    }

    func cancel(subscriptionId: String) async {
        await source.cancel(subscriptionId: subscriptionId)
    }
}

actor AvailabilityReviewPublicationTraceRecorder:
    BridgeProductMetadataLifecycleTraceRecording
{
    private(set) var publicationEvents: [BridgeProductReviewMetadataPublicationTraceEvent] = []
    private var reviewBootstrapFinished: BridgeProductMetadataLifecycleTraceEvent?
    private let bootstrapFinished = HeldStep<BridgeProductMetadataLifecycleTraceEvent>("Review bootstrap finished")

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async {
        guard case .bootstrapFinished = event.stage,
            case .reviewMetadata = event.subscriptionKind,
            case .success = event.result
        else { return }
        reviewBootstrapFinished = event
        bootstrapFinished.release()
        try? await bootstrapFinished.arrive(event)
    }

    func waitUntilReviewBootstrapFinished() async throws -> BridgeProductMetadataLifecycleTraceEvent {
        try await bootstrapFinished.firstArrival()
    }

    func record(_ event: BridgeProductReviewMetadataPublicationTraceEvent) {
        publicationEvents.append(event)
    }
}
