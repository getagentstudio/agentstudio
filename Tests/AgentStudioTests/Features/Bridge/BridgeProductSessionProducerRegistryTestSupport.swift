import Foundation
import Testing

@testable import AgentStudioBridge

func producerRegistryMetadataStreamRequest(
    metadataStreamId: String = "metadata-stream-1",
    resumeFromStreamSequence: Int? = nil
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": metadataStreamId,
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": resumeFromStreamSequence.map { $0 as Any } ?? NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}

func producerRegistryContentRequest(workerDerivationEpoch: Int) throws -> BridgeProductContentRequest {
    let requestJSON = """
        {
          "kind": "content.open",
          "wireVersion": 2,
          "paneSessionId": "pane-session-1",
          "workerDerivationEpoch": \(workerDerivationEpoch),
          "workerInstanceId": "worker-instance-1",
          "contentRequestId": "content-request-1",
          "leaseId": "lease-1",
          "operationCorrelationId": null,
          "contentKind": "file.content",
          "descriptor": {
            "contentKind": "file.content",
            "declaredByteLength": 3,
            "descriptorId": "file-descriptor-1",
            "encoding": "utf-8",
            "expectedSha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "fileId": "file-1",
            "maximumBytes": 3,
            "source": {
              "repoId": "00000000-0000-4000-8000-000000000001",
              "rootRevisionToken": null,
              "sourceCursor": "source-cursor-1",
              "sourceId": "source-1",
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

func closeAllProducerRegistryProducers(
    in registry: BridgeProductProducerRegistryTestHarness
) async throws {
    let stoppedLeases = await registry.cancelAll()
    for lease in stoppedLeases {
        let acknowledgement = try #require(await registry.unregister(lease))
        #expect(await registry.acknowledgeLifecycle(acknowledgement))
    }
}
func producerRegistryMetadataOpeningFrame(
    for request: BridgeProductMetadataStreamRequest,
    sequence: Int
) throws -> BridgeProductProducerFrame {
    .metadata(
        .metadataStreamAccepted(
            try .init(
                stream: request.correlation,
                streamSequence: sequence,
                resumeDisposition: request.resumeFromStreamSequence == nil ? .snapshotRequired : .resumed
            )
        )
    )
}

func producerRegistryMetadataProgressFrame(
    for request: BridgeProductMetadataStreamRequest,
    sequence: Int,
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
            streamSequence: sequence,
            subscription: subscription
        )
    )
}

func producerRegistryMetadataTerminalFrame(
    for request: BridgeProductMetadataStreamRequest,
    sequence: Int,
    safeMessage: String? = nil
) throws -> BridgeProductProducerFrame {
    .metadata(
        try .metadataStreamError(
            stream: request.correlation,
            streamSequence: sequence,
            code: .internal,
            retryable: false,
            safeMessage: safeMessage
        )
    )
}

func producerRegistryContentOpeningFrame(
    for request: BridgeProductContentRequest
) -> BridgeProductProducerFrame {
    .content(
        BridgeProductContentFrame(
            header: .accepted(for: request.admission),
            payload: Data()
        )
    )
}

func producerRegistryContentTerminalFrame(sequence: Int) throws -> BridgeProductProducerFrame {
    .content(
        BridgeProductContentFrame(
            header: try .reset(contentSequence: sequence, reason: .producerOverflow),
            payload: Data()
        )
    )
}

actor BridgeProductProducerInvocationCounter {
    private(set) var wasInvoked = false

    func recordInvocation() {
        wasInvoked = true
    }
}

actor BridgeProductProducerLifecycleAcknowledgementGate {
    private var invocationWaiters: [CheckedContinuation<BridgeProductProducerLifecycleAcknowledgement, Never>] = []
    private var recordedAcknowledgement: BridgeProductProducerLifecycleAcknowledgement?
    private var releaseResult: Bool?
    private var releaseWaiter: CheckedContinuation<Bool, Never>?

    func acknowledge(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        recordedAcknowledgement = acknowledgement
        let waiters = invocationWaiters
        invocationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: acknowledgement)
        }
        if let releaseResult { return releaseResult }
        return await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilInvoked() async -> BridgeProductProducerLifecycleAcknowledgement {
        if let recordedAcknowledgement { return recordedAcknowledgement }
        return await withCheckedContinuation { continuation in
            invocationWaiters.append(continuation)
        }
    }

    func release(result: Bool) {
        releaseResult = result
        releaseWaiter?.resume(returning: result)
        releaseWaiter = nil
    }
}
