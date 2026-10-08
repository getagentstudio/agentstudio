import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

actor BridgeWebKitFailingReviewMetadataSource:
    BridgePaneProductReviewMetadataProducing
{
    typealias CaptureBoundaryObserver = @Sendable (BridgePaneProductReviewViewDemandRequest) async throws -> Void

    private let source = BridgePaneProductReviewMetadataSource()
    private let captureReturnedObserver: CaptureBoundaryObserver
    private let replayBlockedObserver: CaptureBoundaryObserver
    private var armedPredecessorPublicationId: UUID?
    private var cancelledSubscriptionIds: [String] = []
    private var corruptedPublicationId: UUID?
    private var pendingCorruptionCaptureAttempt: HeldStep<Void>?
    private var didCorruptViewCapture = false
    private var deliveryAttempts: [BridgeProductWebKitCarrierReviewDeliveryAttempt] = []
    private var firstViewCapture: BridgePaneProductReviewViewCapture?
    private var openedSubscriptions: [BridgeProductWebKitCarrierSubscriptionIdentity] = []
    private let firstOpen = HeldStep<BridgeProductWebKitCarrierSubscriptionIdentity>("first carrier metadata open")
    private var replayIsBlocked = false
    private var successorEventKinds: [String] = []
    private let replayRelease = HeldStep<Void>("Review successor capture replay release")
    private let replayFailureReady = HeldStep<Void>("corrupted Review capture and held replay observed")

    init(
        captureReturnedObserver: @escaping CaptureBoundaryObserver = { _ in },
        replayBlockedObserver: @escaping CaptureBoundaryObserver = { _ in }
    ) {
        self.captureReturnedObserver = captureReturnedObserver
        self.replayBlockedObserver = replayBlockedObserver
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        let identity = BridgeProductWebKitCarrierSubscriptionIdentity(
            subscriptionId: subscription.subscriptionId,
            workerDerivationEpoch: subscription.workerDerivationEpoch
        )
        openedSubscriptions.append(identity)
        firstOpen.release()
        try await firstOpen.arrive(identity)
        try await source.open(subscription: subscription, productAdmission: productAdmission)
    }

    func waitForFirstOpen() async -> BridgeProductWebKitCarrierSubscriptionIdentity? {
        try? await firstOpen.firstArrival()
    }

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        // A failed or refused capture releases its claim; a successful one
        // establishes the corruption before any later demand reaches replay.
        let targetsCorruptedPublication = request.expectedPublicationId == corruptedPublicationId
        var ownedCaptureAttempt: HeldStep<Void>?
        var observedReplayGate = false
        while targetsCorruptedPublication && !didCorruptViewCapture {
            if let pendingCorruptionCaptureAttempt {
                if !observedReplayGate {
                    try await replayBlockedObserver(request)
                    observedReplayGate = true
                }
                try await pendingCorruptionCaptureAttempt.arrive(())
            } else {
                let captureAttempt = HeldStep<Void>("Review successor corruption capture attempt completion")
                pendingCorruptionCaptureAttempt = captureAttempt
                ownedCaptureAttempt = captureAttempt
                break
            }
        }
        defer {
            if let ownedCaptureAttempt {
                pendingCorruptionCaptureAttempt = nil
                ownedCaptureAttempt.release()
            }
        }
        if targetsCorruptedPublication && ownedCaptureAttempt == nil {
            if !observedReplayGate { try await replayBlockedObserver(request) }
            if !replayIsBlocked {
                replayIsBlocked = true
                successorEventKinds.append("recoveryCapture")
                releaseReplayFailureStateIfReady()
            }
            try await replayRelease.arrive(())
        }
        guard
            let capture = try await source.applyViewDemand(request)
        else { return nil }
        try await captureReturnedObserver(request)
        if firstViewCapture == nil { firstViewCapture = capture }
        guard ownedCaptureAttempt != nil,
            let itemIndex = capture.snapshot.items.firstIndex(where: { item in
                let roles = item.record.contentByRole
                return [roles.base, roles.diff, roles.file, roles.head].contains {
                    if case .available = $0 { true } else { false }
                }
            })
        else { return capture }
        var items = capture.snapshot.items
        let original = items[itemIndex]
        var recordObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original.record)) as? [String: Any]
        )
        var contentByRole = try #require(recordObject["contentByRole"] as? [String: Any])
        for role in ["base", "diff", "file", "head"] {
            guard var content = contentByRole[role] as? [String: Any],
                content["state"] as? String == "available",
                var sourceIdentity = content["source"] as? [String: Any]
            else { continue }
            sourceIdentity["sourceIdentity"] = "wrong-publication-source"
            content["source"] = sourceIdentity
            contentByRole[role] = content
            break
        }
        recordObject["contentByRole"] = contentByRole
        let corruptedRecord = try BridgeProductStrictJSON.decode(
            BridgeProductReviewBatchItemRecord.self,
            from: JSONSerialization.data(withJSONObject: recordObject)
        )
        items[itemIndex] = BridgeProductReviewKeyedItem(
            record: corruptedRecord,
            revision: original.revision
        )
        didCorruptViewCapture = true
        successorEventKinds.append("corruptedCapture")
        releaseReplayFailureStateIfReady()
        return BridgePaneProductReviewViewCapture(
            handle: capture.handle,
            scopeRevision: capture.scopeRevision,
            publicationId: capture.publicationId,
            snapshot: BridgeProductReviewKeyedSnapshot(
                targetRevision: capture.snapshot.targetRevision,
                publication: capture.snapshot.publication,
                items: items
            )
        )
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
        deliveryAttempts.append(
            BridgeProductWebKitCarrierReviewDeliveryAttempt(
                package: publication.package,
                publicationId: reservation.publicationId
            )
        )
        if let armedPredecessorPublicationId,
            reservation.publicationId != armedPredecessorPublicationId,
            corruptedPublicationId == nil
        {
            corruptedPublicationId = reservation.publicationId
        }
        return try await source.deliver(
            publication: publication,
            reservation: reservation,
            productAdmission: productAdmission
        )
    }

    func cancel(subscriptionId: String) async {
        cancelledSubscriptionIds.append(subscriptionId)
        await source.cancel(subscriptionId: subscriptionId)
    }

    func armFailure(after publicationId: UUID) {
        armedPredecessorPublicationId = publicationId
    }

    func firstViewCaptureDiagnostic() -> String {
        guard let capture = firstViewCapture else { return "none" }
        let records =
            [BridgeProductReviewBatchRecord.publication(capture.snapshot.publication)]
            + capture.snapshot.items.map { BridgeProductReviewBatchRecord.item($0.record) }
        let encodedRecords =
            (try? JSONEncoder().encode(records))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
        return
            "publication=\(capture.publicationId),scopeRevision=\(capture.scopeRevision),targetRevision=\(capture.snapshot.targetRevision),items=\(capture.snapshot.items.count),records=\(encodedRecords)"
    }

    func releaseReplay() {
        replayRelease.release()
    }

    func snapshot() -> BridgeProductWebKitCarrierReviewMetadataSnapshot {
        BridgeProductWebKitCarrierReviewMetadataSnapshot(
            cancelledSubscriptionIds: cancelledSubscriptionIds,
            corruptedPublicationId: corruptedPublicationId,
            didCorruptViewCapture: didCorruptViewCapture,
            deliveryAttempts: deliveryAttempts,
            openedSubscriptions: openedSubscriptions,
            replayIsBlocked: replayIsBlocked,
            successorEventKinds: successorEventKinds
        )
    }

    func waitForReplayFailureState() async -> Bool {
        guard !(replayIsBlocked && didCorruptViewCapture) else { return true }
        do {
            try await replayFailureReady.arrive(())
            return replayIsBlocked && didCorruptViewCapture
        } catch {
            return false
        }
    }

    private func releaseReplayFailureStateIfReady() {
        guard replayIsBlocked && didCorruptViewCapture else { return }
        replayFailureReady.release()
    }
}
