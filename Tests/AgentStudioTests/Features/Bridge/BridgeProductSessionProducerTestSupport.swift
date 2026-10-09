import Foundation
import Testing

@testable import AgentStudioBridge

func bridgeProductOpeningContentAcknowledgement(
    for request: BridgeProductContentRequest
) throws -> BridgeProductContentFrameAcknowledgement {
    let admission = request.admission
    let body = try JSONSerialization.data(
        withJSONObject: [
            "contentRequestId": admission.contentRequestId,
            "receivedThroughContentSequence": 0,
            "kind": "content.acknowledge",
            "leaseId": admission.leaseId,
            "paneSessionId": admission.paneSessionId,
            "wireVersion": admission.wireVersion,
            "workerInstanceId": admission.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentFrameAcknowledgement.self,
        from: body
    )
}

actor BridgeProductProducerRegistryTestHarness {
    private var registry: BridgeProductProducerRegistry
    private var zeroResidueWaiters: [CheckedContinuation<Bool, Never>] = []

    init(limits: BridgeProductProducerQueueLimits = .productContract) {
        self.registry = BridgeProductProducerRegistry(limits: limits)
    }

    func registerMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        operation: @escaping BridgeProductProducerRegistry.ProducerOperation
    ) -> BridgeProductProducerRegistration {
        registry.registerMetadataProducer(
            request: request,
            operation: operation,
            completion: { [weak self] lease in
                await self?.producerOperationFinished(lease)
            }
        )
    }

    func registerContentProducer(
        request: BridgeProductContentRequest,
        operation: @escaping BridgeProductProducerRegistry.ProducerOperation
    ) -> BridgeProductProducerRegistration {
        registry.registerContentProducer(
            request: request,
            operation: operation,
            completion: { [weak self] lease in
                await self?.producerOperationFinished(lease)
            }
        )
    }

    func enqueueRequiredOpeningFrame(
        for lease: BridgeProductProducerLease,
        build: BridgeProductProducerRegistry.FrameBuilder
    ) throws -> BridgeProductProducerEnqueueResult {
        try registry.enqueueRequiredOpeningFrame(for: lease, build: build)
    }

    func enqueueNonterminalFrame(
        for lease: BridgeProductProducerLease,
        build: BridgeProductProducerRegistry.FrameBuilder,
        overflowReset: BridgeProductProducerRegistry.FrameBuilder
    ) throws -> BridgeProductProducerEnqueueResult {
        try registry.enqueueNonterminalFrame(
            for: lease,
            build: build,
            overflowReset: overflowReset
        )
    }

    func enqueueTerminalFrame(
        for lease: BridgeProductProducerLease,
        build: BridgeProductProducerRegistry.FrameBuilder
    ) throws -> BridgeProductProducerEnqueueResult {
        try registry.enqueueTerminalFrame(for: lease, build: build)
    }

    func consumeNextFrame(
        for lease: BridgeProductProducerLease
    ) -> BridgeProductQueuedProducerFrame? {
        let waiterToken = UUID()
        guard
            case .frame(let delivery) = registry.prepareFramePull(
                for: lease,
                waiterToken: waiterToken
            )
        else {
            Issue.record("Expected a queued producer frame")
            return nil
        }
        guard registry.acknowledgeFrameConsumed(delivery.receipt) else {
            Issue.record("Expected the exact producer frame receipt to be accepted")
            return nil
        }
        return delivery.frame
    }

    func openingFrameState(
        for lease: BridgeProductProducerLease
    ) -> BridgeProductProducerOpeningFrameState? {
        registry.openingFrameState(for: lease)
    }

    func snapshot() -> BridgeProductProducerRegistrySnapshot {
        registry.snapshot()
    }

    func stop(_ lease: BridgeProductProducerLease) async -> Bool {
        await stop([lease]) == [lease]
    }

    func stop(_ leases: [BridgeProductProducerLease]) async -> [BridgeProductProducerLease] {
        let requests = registry.requestStop(leases)
        return await waitForStops(requests)
    }

    func cancelAll() async -> [BridgeProductProducerLease] {
        let requests = registry.requestStopEveryProducer(revoking: false)
        let stoppedLeases = await waitForStops(requests)
        registry.finishClosing()
        return stoppedLeases
    }

    func revoke() async -> [BridgeProductProducerLease] {
        let requests = registry.requestStopEveryProducer(revoking: true)
        let stoppedLeases = await waitForStops(requests)
        registry.finishClosing()
        return stoppedLeases
    }

    func unregister(
        _ lease: BridgeProductProducerLease
    ) -> BridgeProductProducerLifecycleAcknowledgement? {
        registry.unregister(lease)
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) -> Bool {
        let acknowledged = registry.acknowledgeLifecycle(acknowledgement)
        resumeZeroResidueWaitersIfNeeded()
        return acknowledged
    }

    func waitUntilZeroProducerResidue() async -> Bool {
        if registry.snapshot().hasZeroResidue { return true }
        return await withCheckedContinuation { continuation in
            zeroResidueWaiters.append(continuation)
        }
    }

    private func producerOperationFinished(_ lease: BridgeProductProducerLease) {
        registry.producerOperationFinished(lease)
        resumeZeroResidueWaitersIfNeeded()
    }

    private func waitForStops(
        _ requests: [BridgeProductProducerRegistry.StopRequest]
    ) async -> [BridgeProductProducerLease] {
        for request in requests {
            await request.task?.value
        }
        return requests.compactMap { request in
            registry.producerIsStopped(request.lease) ? request.lease : nil
        }
    }

    private func resumeZeroResidueWaitersIfNeeded() {
        guard registry.snapshot().hasZeroResidue else { return }
        let waiters = zeroResidueWaiters
        zeroResidueWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }
}

struct BridgeProductSessionProducerHarness {
    private let productAdmissionTestContext: BridgeProductAdmissionTestContext
    let productAdmission: BridgeProductAdmissionContext
    let session: BridgeProductSession

    static func opened() async throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let request = try bridgeProductControlRequest([
            "kind": "workerSession.open",
            "paneSessionId": bridgeProductTestPaneSessionId,
            "request": NSNull(),
            "requestId": "request-open-producer-harness",
            "requestSequence": 1,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": bridgeProductTestWorkerInstanceId,
        ])
        let requestBytes = try JSONEncoder().encode(request)
        let admission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: requestBytes,
            presentedCapability: capabilityHeader
        )
        let token = try bridgeProductExecutionToken(admission)
        let response = try BridgeProductControlResponse.workerSessionAccepted(correlating: request)
        _ = try await session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
        return Self(
            productAdmissionTestContext: productAdmission,
            productAdmission: productAdmission.context,
            session: session
        )
    }

    func closeProductAdmission() {
        productAdmissionTestContext.close()
    }
}

actor BridgeProductSessionProducerInvocationProbe {
    private(set) var wasInvoked = false

    func recordInvocation() {
        wasInvoked = true
    }
}

let bridgeProductTestPaneSessionId = "pane-session-1"
let bridgeProductTestWorkerInstanceId = "worker-instance-1"

func bridgeProductMetadataStreamRequest(
    metadataStreamId: String,
    resumeFromStreamSequence: Int?
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": metadataStreamId,
            "paneSessionId": bridgeProductTestPaneSessionId,
            "resumeFromStreamSequence": resumeFromStreamSequence.map { $0 as Any } ?? NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": bridgeProductTestWorkerInstanceId,
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}

func bridgeProductMetadataAcceptedFrame(
    request: BridgeProductMetadataStreamRequest,
    streamSequence: Int,
    resumeDisposition: BridgeProductMetadataStreamResumeDisposition
) throws -> BridgeProductProducerFrame {
    .metadata(
        .metadataStreamAccepted(
            try BridgeProductMetadataStreamAcceptedFrame(
                stream: request.correlation,
                streamSequence: streamSequence,
                resumeDisposition: resumeDisposition
            )
        )
    )
}

func bridgeProductMetadataProgressFrame(
    request: BridgeProductMetadataStreamRequest,
    streamSequence: Int,
    identitySuffix: String
) throws -> BridgeProductProducerFrame {
    let subscription = try BridgeProductSubscriptionFrameCorrelation(
        subscriptionId: "subscription-\(identitySuffix)",
        subscriptionKind: .fileMetadata,
        workerDerivationEpoch: 1
    )
    return .metadata(
        try .subscriptionAccepted(
            stream: request.correlation,
            streamSequence: streamSequence,
            subscription: subscription
        )
    )
}

func bridgeProductMetadataTerminalFrame(
    request: BridgeProductMetadataStreamRequest,
    streamSequence: Int
) throws -> BridgeProductProducerFrame {
    .metadata(
        try .metadataStreamError(
            stream: request.correlation,
            streamSequence: streamSequence,
            code: .internal,
            retryable: false,
            safeMessage: nil
        )
    )
}

func bridgeProductFileContentRequest(
    identitySuffix: String,
    workerDerivationEpoch: Int = 1
) throws -> BridgeProductContentRequest {
    let requestJSON = """
        {
          "kind": "content.open",
          "wireVersion": 2,
          "paneSessionId": "pane-session-1",
          "workerDerivationEpoch": \(workerDerivationEpoch),
          "workerInstanceId": "worker-instance-1",
          "contentRequestId": "content-request-\(identitySuffix)",
          "leaseId": "lease-\(identitySuffix)",
          "operationCorrelationId": null,
          "contentKind": "file.content",
          "descriptor": {
            "contentKind": "file.content",
            "declaredByteLength": 3,
            "descriptorId": "file-descriptor-\(identitySuffix)",
            "encoding": "utf-8",
            "expectedSha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "fileId": "file-\(identitySuffix)",
            "maximumBytes": 3,
            "source": {
              "repoId": "00000000-0000-4000-8000-000000000001",
              "rootRevisionToken": null,
              "sourceCursor": "source-cursor-\(identitySuffix)",
              "sourceId": "source-\(identitySuffix)",
              "subscriptionGeneration": 11,
              "worktreeId": "00000000-0000-4000-8000-000000000002"
            },
            "window": {
              "kind": "prefix",
              "maximumBytes": 3,
              "maximumLines": 10000,
              "startByte": 0
            }
          }
        }
        """
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentRequest.self,
        from: Data(requestJSON.utf8)
    )
}

func consumeNextBridgeProductProducerFrame(
    for lease: BridgeProductProducerLease,
    from session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionContext
) async -> BridgeProductQueuedProducerFrame? {
    guard
        case .frame(let delivery) = await session.pullProducerFrame(
            for: lease,
            productAdmission: productAdmission
        )
    else {
        Issue.record("Expected a queued producer frame")
        return nil
    }
    guard
        await session.acknowledgeProducerFrameConsumed(
            delivery.receipt,
            productAdmission: productAdmission
        )
    else {
        Issue.record("Expected the exact producer frame receipt to be accepted")
        return nil
    }
    return delivery.frame
}

func closeBridgeProductSessionProducer(
    _ lease: BridgeProductProducerLease,
    in session: BridgeProductSession
) async throws {
    guard await session.stopProducer(lease) else {
        throw BridgeProductSessionProducerTestSupportError.stopRejected
    }
    let acknowledgement = try bridgeProductLifecycleAcknowledgement(
        await session.unregisterProducer(lease)
    )
    guard await session.acknowledgeProducerLifecycle(acknowledgement) else {
        throw BridgeProductSessionProducerTestSupportError.acknowledgementRejected
    }
}

func bridgeProductAcceptedLease(
    _ registration: BridgeProductProducerRegistration
) throws -> BridgeProductProducerLease {
    guard case .accepted(let lease) = registration else {
        throw BridgeProductSessionProducerTestSupportError.expectedAcceptedRegistration
    }
    return lease
}

func bridgeProductEnqueuedFrame(
    _ result: BridgeProductProducerEnqueueResult
) -> BridgeProductQueuedProducerFrame? {
    switch result {
    case .enqueued(let frame), .queueReset(let frame, _, _): frame
    case .rejected: nil
    }
}

private enum BridgeProductSessionProducerTestSupportError: Error {
    case acknowledgementRejected
    case expectedAcceptedRegistration
    case expectedExecutionAdmission
    case expectedLifecycleAcknowledgement
    case stopRejected
}

private func bridgeProductControlRequest(
    _ object: [String: Any]
) throws -> BridgeProductControlRequest {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: data)
}

private func bridgeProductExecutionToken(
    _ admission: BridgeProductSessionControlAdmission
) throws -> BridgeProductControlAdmissionToken {
    guard case .execute(let token, _) = admission else {
        throw BridgeProductSessionProducerTestSupportError.expectedExecutionAdmission
    }
    return token
}

private func bridgeProductLifecycleAcknowledgement(
    _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement?
) throws -> BridgeProductProducerLifecycleAcknowledgement {
    guard let acknowledgement else {
        throw BridgeProductSessionProducerTestSupportError.expectedLifecycleAcknowledgement
    }
    return acknowledgement
}
