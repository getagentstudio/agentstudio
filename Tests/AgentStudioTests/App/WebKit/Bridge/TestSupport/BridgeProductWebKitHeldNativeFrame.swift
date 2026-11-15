import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

/// Keeps an unrelated native content delivery claimed until the journey releases its exact receipt.
struct BridgeProductWebKitHeldNativeFrame {
    private let pump: BridgeProductSchemeFramePump
    private let receipt: BridgeProductProducerFrameReceipt
    private let producer: HeldStep<BridgeProductProducerLease>

    @MainActor
    static func whileClaimed(
        in controller: BridgePaneController, operation: @MainActor () async throws -> Void
    ) async throws {
        let heldFrame = try await hold(in: controller)
        do {
            try await operation()
        } catch {
            try? await heldFrame.finish()
            throw error
        }
        try await heldFrame.finish()
    }

    @MainActor
    static func hold(in controller: BridgePaneController) async throws -> Self {
        let installation = try #require(await controller.productSessionOwner.activeInstallation)
        let admission = try #require(controller.productAdmissionGate.acquire())
        let session = installation.session
        let epoch = await session.snapshot.workerDerivationEpochBySurface[.file] ?? 0
        let identity = UUIDv7.generate().uuidString
        let request = try makeRequest(installation: installation, epoch: epoch, identity: identity)
        let producer = HeldStep<BridgeProductProducerLease>("unrelated native content producer")
        let registration = await session.registerContentProducer(
            request: request,
            productAdmission: admission,
            operation: { lease in try? await producer.arrive(lease) }
        )
        let lease = try bridgeProductAcceptedLease(registration)
        let pump = BridgeProductSchemeFramePump(
            session: session, producerLease: lease, productAdmission: admission, acknowledgeLifecycle: { _ in true })
        do {
            let opening = try await session.enqueueRequiredProducerOpeningFrame(
                for: lease, productAdmission: admission,
                build: { _ in producerRegistryContentOpeningFrame(for: request) })
            guard case .enqueued = opening else {
                throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(
                    "unrelated native content opening was not enqueued: \(opening)")
            }
            guard case .frame(let delivery) = await pump.nextFrame() else {
                throw BridgeProductWebKitTwoPaneJourneyTestSupport.JourneyError.conditionFailed(
                    "unrelated native content frame was not claimed")
            }
            let snapshot = await session.producerSnapshot()
            try #require(snapshot.queuedFrameCount > 0)
            try #require(snapshot.inFlightFrameReceiptCount > 0)
            print("CI oracle interleaving: real native frame claimed; its receipt remains unacknowledged")
            return Self(pump: pump, receipt: delivery.receipt, producer: producer)
        } catch {
            producer.release()
            _ = await pump.cancel()
            throw error
        }
    }

    func finish() async throws {
        let consumed = await pump.acknowledgeFrameConsumed(receipt)
        producer.release()
        let cancelled = await pump.cancel()
        try #require(consumed)
        try #require(cancelled)
    }

    private static func makeRequest(
        installation: BridgeProductSessionInstallation, epoch: Int, identity: String
    ) throws -> BridgeProductContentRequest {
        let request: [String: Any] = [
            "kind": "content.open", "wireVersion": 2,
            "paneSessionId": installation.bootstrap.paneSessionId,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
            "workerDerivationEpoch": epoch, "contentRequestId": "request-\(identity)",
            "leaseId": "lease-\(identity)", "operationCorrelationId": NSNull(), "contentKind": "file.content",
            "descriptor": [
                "contentKind": "file.content", "declaredByteLength": 3, "descriptorId": "descriptor-\(identity)",
                "encoding": "utf-8", "maximumBytes": 3, "fileId": "file-\(identity)",
                "expectedSha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "source": [
                    "repoId": UUIDv7.generate().uuidString, "worktreeId": UUIDv7.generate().uuidString,
                    "rootRevisionToken": NSNull(), "sourceCursor": "cursor-\(identity)",
                    "sourceId": "source-\(identity)", "subscriptionGeneration": 1,
                ],
                "window": ["kind": "prefix", "maximumBytes": 3, "maximumLines": 1, "startByte": 0],
            ],
        ]
        return try BridgeProductStrictJSON.decode(
            BridgeProductContentRequest.self, from: JSONSerialization.data(withJSONObject: request))
    }
}
