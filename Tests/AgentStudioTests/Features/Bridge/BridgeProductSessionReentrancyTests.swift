import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session reentrancy")
struct BridgeProductSessionReentrancyTests {
    @Test("pending subscription completion cannot resurrect an older surface epoch")
    func pendingSubscriptionCompletionCannotCommitAfterFloorAdvance() async throws {
        // Arrange
        let harness = try await ReentrancySessionHarness.opened()
        let openRequest = try fileSubscriptionOpenRequest(
            requestSequence: 2,
            workerDerivationEpoch: 2
        )
        let openToken = try #require(
            try await harness.begin(openRequest).executionToken
        )
        let newerRegistration = await harness.session.registerContentProducer(
            request: try fileContentRequest(
                identitySuffix: "pending-completion-newer",
                workerDerivationEpoch: 3
            ),
            productAdmission: harness.productAdmission.context
        ) { _ in }
        let newerLease = try #require(newerRegistration.lease)
        let openResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest,
            worktreeId: nil
        )

        // Act
        _ = try await harness.session.completeAdmittedControl(
            token: openToken,
            exactResponseBytes: try JSONEncoder().encode(openResponse)
        )

        // Assert
        let completedSnapshot = await harness.session.snapshot
        #expect(completedSnapshot.workerDerivationEpochBySurface[.file] == 3)
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: ReentrancySessionHarness.fileSubscriptionId
            ) == nil
        )
        try await closeProducer(newerLease, in: harness.session)
    }

    @Test("serial registrations cannot be overtaken while older cancellation drains")
    func registrationsRemainAtomicWhileOlderCancellationDrains() async throws {
        // Arrange
        let harness = try await ReentrancySessionHarness.opened()
        let heldProducer = HeldProducerOperation()
        let oldRegistration = await harness.session.registerContentProducer(
            request: try fileContentRequest(
                identitySuffix: "register-old",
                workerDerivationEpoch: 2
            ),
            productAdmission: harness.productAdmission.context
        ) { lease in
            await heldProducer.run(lease)
        }
        let oldLease = try #require(oldRegistration.lease)
        _ = await heldProducer.waitUntilStarted()

        // Act
        let epochThreeRequest = try fileContentRequest(
            identitySuffix: "register-epoch-3",
            workerDerivationEpoch: 3
        )
        let epochThreeRegistration = await harness.session.registerContentProducer(
            request: epochThreeRequest,
            productAdmission: harness.productAdmission.context
        ) { _ in }
        await heldProducer.waitUntilCancellationObserved()
        #expect((await harness.session.snapshot).workerDerivationEpochBySurface[.file] == 3)

        let epochFourRequest = try fileContentRequest(
            identitySuffix: "register-epoch-4",
            workerDerivationEpoch: 4
        )
        let epochFourRegistration = await harness.session.registerContentProducer(
            request: epochFourRequest,
            productAdmission: harness.productAdmission.context
        ) { _ in }

        // Assert
        let epochThreeLease = try #require(epochThreeRegistration.lease)
        let epochFourLease = try #require(epochFourRegistration.lease)
        #expect((await harness.session.snapshot).workerDerivationEpochBySurface[.file] == 4)

        await heldProducer.release()
        try await closeProducer(oldLease, in: harness.session)
        try await closeProducer(epochThreeLease, in: harness.session)
        try await closeProducer(epochFourLease, in: harness.session)
    }

    @Test("a later epoch advance cannot regress a completed resync floor")
    func laterEpochAdvanceCannotRegressCompletedResyncFloor() async throws {
        // Arrange
        let harness = try await ReentrancySessionHarness.opened()
        let metadataProducer = HeldProducerOperation()
        let metadataRequest = try metadataStreamRequest()
        let metadataRegistration = await harness.session.registerMetadataProducer(
            request: metadataRequest,
            productAdmission: harness.productAdmission.context
        ) { lease in
            await metadataProducer.run(lease)
        }
        let metadataLease = try #require(metadataRegistration.lease)
        _ = await metadataProducer.waitUntilStarted()
        let metadataOpening = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: metadataLease,
            productAdmission: harness.productAdmission.context,
            build: { sequence in
                .metadata(
                    .metadataStreamAccepted(
                        try .init(
                            stream: metadataRequest.correlation,
                            streamSequence: sequence,
                            resumeDisposition: .snapshotRequired
                        )
                    )
                )
            }
        )
        #expect(metadataOpening.admittedFrame?.sequence == 0)
        #expect(
            await consumeNextBridgeProductProducerFrame(
                for: metadataLease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )?.sequence == 0
        )
        try await harness.openFileSubscription(
            requestSequence: 2,
            workerDerivationEpoch: 2
        )

        let heldProducer = HeldProducerOperation()
        let oldRegistration = await harness.session.registerContentProducer(
            request: try fileContentRequest(
                identitySuffix: "resync-old",
                workerDerivationEpoch: 2
            ),
            productAdmission: harness.productAdmission.context
        ) { lease in
            await heldProducer.run(lease)
        }
        let oldLease = try #require(oldRegistration.lease)
        _ = await heldProducer.waitUntilStarted()

        let resyncRequest = try fileResyncRequest(
            requestSequence: 3,
            lastAcceptedRequestSequence: 2,
            lastAcceptedStreamSequence: 0,
            workerDerivationEpoch: 3
        )
        let resyncToken = try #require(
            try await harness.begin(resyncRequest).executionToken
        )
        _ = try await harness.session.admitControlOperation(token: resyncToken, execute: { _ in })
        let providerResyncResponse = try BridgeProductControlResponse.resyncAccepted(
            correlating: resyncRequest,
            metadataStreamSequenceBarrier: 0,
            nextExpectedRequestSequence: 4,
            reconciliation: []
        )
        let resyncResponse = try await harness.session.authoritativeControlResponse(
            token: resyncToken,
            providerResponse: providerResyncResponse
        )

        // Act
        let completionEffects = try await harness.session.completeAdmittedControl(
            token: resyncToken,
            exactResponseBytes: try JSONEncoder().encode(resyncResponse)
        )
        await heldProducer.waitUntilCancellationObserved()
        #expect((await harness.session.snapshot).workerDerivationEpochBySurface[.file] == 3)

        let epochFourRequest = try fileContentRequest(
            identitySuffix: "resync-epoch-4",
            workerDerivationEpoch: 4
        )
        let epochFourRegistration = await harness.session.registerContentProducer(
            request: epochFourRequest,
            productAdmission: harness.productAdmission.context
        ) { _ in }

        // Assert
        guard case .resynced = completionEffects else {
            Issue.record("Expected a committed session-resync effect")
            return
        }
        #expect((await harness.session.snapshot).workerDerivationEpochBySurface[.file] == 4)
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: ReentrancySessionHarness.fileSubscriptionId
            ) == nil
        )

        let epochFourLease = try #require(epochFourRegistration.lease)
        await heldProducer.release()
        await metadataProducer.release()
        try await closeProducer(metadataLease, in: harness.session)
        try await closeProducer(oldLease, in: harness.session)
        try await closeProducer(epochFourLease, in: harness.session)
    }

    @Test("surface-floor advance does not await a cancelled producer operation")
    func newerAdmissionDoesNotWaitForCancelledProducerTask() async throws {
        // Arrange
        let harness = try await ReentrancySessionHarness.opened()
        let heldProducer = HeldProducerOperation()
        let oldRegistration = await harness.session.registerContentProducer(
            request: try fileContentRequest(
                identitySuffix: "nonblocking-old",
                workerDerivationEpoch: 2
            ),
            productAdmission: harness.productAdmission.context
        ) { lease in
            await heldProducer.run(lease)
        }
        let oldLease = try #require(oldRegistration.lease)
        _ = await heldProducer.waitUntilStarted()

        // Act
        let newerRequest = try fileContentRequest(
            identitySuffix: "nonblocking-newer",
            workerDerivationEpoch: 3
        )
        let newerRegistration = await harness.session.registerContentProducer(
            request: newerRequest,
            productAdmission: harness.productAdmission.context
        ) { _ in }
        await heldProducer.waitUntilCancellationObserved()
        #expect((await harness.session.snapshot).workerDerivationEpochBySurface[.file] == 3)

        let producerSnapshot = await harness.session.producerSnapshot()

        // Assert
        #expect(producerSnapshot.activeProducerCount >= 2)
        await heldProducer.release()
        let newerLease = try #require(newerRegistration.lease)
        try await closeProducer(oldLease, in: harness.session)
        try await closeProducer(newerLease, in: harness.session)
    }
}

private struct ReentrancySessionHarness {
    static let fileSubscriptionId = "file-subscription-reentrancy"

    let capabilityHeader: String
    let productAdmission: BridgeProductAdmissionTestContext
    let session: BridgeProductSession

    static func opened() async throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let harness = try Self(
            capabilityHeader: BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes),
            productAdmission: .make(),
            session: BridgeProductSession(
                paneSessionId: "pane-session-1",
                workerInstanceId: "worker-instance-1",
                capabilityBytes: capabilityBytes
            )
        )
        let openRequest = try controlRequest(
            controlIdentity(
                kind: "workerSession.open",
                requestId: "request-open-1",
                requestSequence: 1
            ).merging(["request": NSNull()]) { _, newValue in newValue }
        )
        let openToken = try #require(
            try await harness.begin(openRequest).executionToken
        )
        let openResponse = try BridgeProductControlResponse.workerSessionAccepted(
            correlating: openRequest
        )
        _ = try await harness.session.completeAdmittedControl(
            token: openToken,
            exactResponseBytes: try JSONEncoder().encode(openResponse)
        )
        return harness
    }

    func begin(
        _ request: BridgeProductControlRequest
    ) async throws -> BridgeProductSessionControlAdmission {
        await productAdmission.beginControl(
            in: session,
            exactRequestBytes: try JSONEncoder().encode(request),
            presentedCapability: capabilityHeader
        )
    }

    func openFileSubscription(
        requestSequence: Int,
        workerDerivationEpoch: Int
    ) async throws {
        let request = try fileSubscriptionOpenRequest(
            requestSequence: requestSequence,
            workerDerivationEpoch: workerDerivationEpoch
        )
        let token = try #require(try await begin(request).executionToken)
        let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: request,
            worktreeId: nil
        )
        _ = try await session.completeAdmittedControl(
            token: token,
            exactResponseBytes: try JSONEncoder().encode(response)
        )
    }
}

private actor HeldProducerOperation {
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationObserved = false
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var startedLease: BridgeProductProducerLease?
    private var startWaiters: [CheckedContinuation<BridgeProductProducerLease, Never>] = []

    func run(_ lease: BridgeProductProducerLease) async {
        startedLease = lease
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: lease)
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if releaseRequested {
                    continuation.resume()
                } else {
                    operationContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilStarted() async -> BridgeProductProducerLease {
        if let startedLease { return startedLease }
        return await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        if cancellationObserved { return }
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
        }
    }

    func release() {
        releaseRequested = true
        operationContinuation?.resume()
        operationContinuation = nil
    }

    private func recordCancellation() {
        cancellationObserved = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}

private func closeProducer(
    _ lease: BridgeProductProducerLease,
    in session: BridgeProductSession
) async throws {
    #expect(await session.stopProducer(lease))
    let acknowledgement = try #require(await session.unregisterProducer(lease))
    #expect(await session.acknowledgeProducerLifecycle(acknowledgement))
}

private func controlRequest(_ object: [String: Any]) throws -> BridgeProductControlRequest {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: data)
}

private func controlIdentity(
    kind: String,
    requestId: String,
    requestSequence: Int
) -> [String: Any] {
    [
        "kind": kind,
        "paneSessionId": "pane-session-1",
        "requestId": requestId,
        "requestSequence": requestSequence,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": "worker-instance-1",
    ]
}

private func fileSubscriptionOpenRequest(
    requestSequence: Int,
    workerDerivationEpoch: Int
) throws -> BridgeProductControlRequest {
    try controlRequest(
        controlIdentity(
            kind: "subscription.open",
            requestId: "request-file-open-\(requestSequence)",
            requestSequence: requestSequence
        ).merging([
            "subscription": [
                "source": fileSourceIdentity(),
                "subscriptionKind": "file.metadata",
            ],
            "subscriptionId": ReentrancySessionHarness.fileSubscriptionId,
            "workerDerivationEpoch": workerDerivationEpoch,
        ]) { _, newValue in newValue }
    )
}

private func fileResyncRequest(
    requestSequence: Int,
    lastAcceptedRequestSequence: Int,
    lastAcceptedStreamSequence: Int,
    workerDerivationEpoch: Int
) throws -> BridgeProductControlRequest {
    try controlRequest(
        controlIdentity(
            kind: "workerSession.resync",
            requestId: "request-resync-\(requestSequence)",
            requestSequence: requestSequence
        ).merging([
            "activeSubscriptions": [
                [
                    "subscriptionId": ReentrancySessionHarness.fileSubscriptionId,
                    "subscriptionKind": "file.metadata",
                    "workerDerivationEpoch": workerDerivationEpoch,
                ]
            ],
            "lastAcceptedRequestSequence": lastAcceptedRequestSequence,
            "lastAcceptedStreamSequence": lastAcceptedStreamSequence,
        ]) { _, newValue in newValue }
    )
}

private func metadataStreamRequest() throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-stream-reentrancy",
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}

private func fileSourceIdentity() -> [String: Any] {
    [
        "cwdScope": NSNull(),
        "freshness": "live",
        "includeStatuses": true,
        "repoId": "00000000-0000-4000-8000-000000000001",
        "rootPathToken": "root-token-1",
        "worktreeId": "00000000-0000-4000-8000-000000000002",
    ]
}

private func fileContentRequest(
    identitySuffix: String,
    workerDerivationEpoch: Int
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

extension BridgeProductSessionControlAdmission {
    fileprivate var executionToken: BridgeProductControlAdmissionToken? {
        guard case .execute(let token, _) = self else { return nil }
        return token
    }
}

extension BridgeProductProducerRegistration {
    fileprivate var lease: BridgeProductProducerLease? {
        guard case .accepted(let lease) = self else { return nil }
        return lease
    }
}

extension BridgeProductProducerEnqueueResult {
    fileprivate var admittedFrame: BridgeProductQueuedProducerFrame? {
        switch self {
        case .enqueued(let frame), .queueReset(let frame, _, _):
            frame
        case .rejected:
            nil
        }
    }
}
