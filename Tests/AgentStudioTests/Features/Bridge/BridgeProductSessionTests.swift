import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session core")
struct BridgeProductSessionTests {
    @Test("session byte configuration can tighten but never raise the wire ceiling")
    func sessionByteConfigurationCannotExceedWireContract() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let smallerTestCap = 128
        let aboveWireCap = BridgeProductWireContract.maximumRequestBodyBytes + 1

        // Act
        let tightenedSession = try BridgeProductSession(
            paneSessionId: "pane-session-tightened-cap",
            workerInstanceId: "worker-instance-tightened-cap",
            capabilityBytes: capabilityBytes,
            maximumRequestOrResponseBytes: smallerTestCap
        )
        let tightenedProductAdmission = try BridgeProductAdmissionTestContext.make()
        let tightenedAdmission = await tightenedProductAdmission.beginControl(
            in: tightenedSession,
            exactRequestBytes: Data(repeating: 0x61, count: smallerTestCap + 1),
            presentedCapability: capabilityHeader
        )
        let aboveWireConfiguration = {
            try BridgeProductSession(
                paneSessionId: "pane-session-raised-cap",
                workerInstanceId: "worker-instance-raised-cap",
                capabilityBytes: capabilityBytes,
                maximumRequestOrResponseBytes: aboveWireCap
            )
        }
        let zeroConfiguration = {
            try BridgeProductSession(
                paneSessionId: "pane-session-zero-cap",
                workerInstanceId: "worker-instance-zero-cap",
                capabilityBytes: capabilityBytes,
                maximumRequestOrResponseBytes: 0
            )
        }
        let contractSession = try BridgeProductSession(
            paneSessionId: "pane-session-contract-cap",
            workerInstanceId: "worker-instance-contract-cap",
            capabilityBytes: capabilityBytes
        )
        let contractProductAdmission = try BridgeProductAdmissionTestContext.make()
        let aboveWireAdmission = await contractProductAdmission.beginControl(
            in: contractSession,
            exactRequestBytes: Data(repeating: 0x61, count: aboveWireCap),
            presentedCapability: capabilityHeader
        )

        // Assert
        #expect(tightenedAdmission == .rejected(.payloadTooLarge))
        #expect(throws: BridgeProductSessionError.invalidRequestOrResponseByteLimit) {
            _ = try aboveWireConfiguration()
        }
        #expect(throws: BridgeProductSessionError.invalidRequestOrResponseByteLimit) {
            _ = try zeroConfiguration()
        }
        #expect(aboveWireAdmission == .rejected(.payloadTooLarge))
        #expect((await tightenedSession.snapshot).lifecycle == .awaitingOpen)
        #expect((await contractSession.snapshot).lifecycle == .awaitingOpen)
    }

    @Test("capability and worker identity reject before session mutation")
    func authenticationAndIdentityRejectionAreMutationFree() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: "pane-session-1",
            workerInstanceId: "worker-instance-1",
            capabilityBytes: capabilityBytes
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let openRequestBytes = try controlRequestData(workerSessionOpenObject())
        let foreignRequestBytes = try controlRequestData(
            workerSessionOpenObject(workerInstanceId: "worker-instance-foreign")
        )
        let foreignRequest = try decodeControlRequest(foreignRequestBytes)
        let initialSnapshot = await session.snapshot

        // Act
        let unauthorizedAdmission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: openRequestBytes,
            presentedCapability: "wrong-capability"
        )
        let afterUnauthorizedSnapshot = await session.snapshot
        let foreignAdmission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: foreignRequestBytes,
            presentedCapability: capabilityHeader
        )
        let afterForeignSnapshot = await session.snapshot

        // Assert
        #expect(unauthorizedAdmission == .rejected(.unauthorized))
        #expect(
            foreignAdmission
                == .rejected(
                    .init(
                        reason: .staleWorker,
                        request: foreignRequest
                    )
                )
        )
        #expect(afterUnauthorizedSnapshot == initialSnapshot)
        #expect(afterForeignSnapshot == initialSnapshot)
    }

    @Test("session open, exact replay, and independent surface epochs remain serialized")
    func sessionLifecycleReplayAndSurfaceEpochs() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: "pane-session-1",
            workerInstanceId: "worker-instance-1",
            capabilityBytes: capabilityBytes
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make()

        // Act: open the worker lifetime.
        let openRequestBytes = try controlRequestData(workerSessionOpenObject())
        let openRequest = try decodeControlRequest(openRequestBytes)
        let openAdmission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: openRequestBytes,
            presentedCapability: capabilityHeader
        )
        let openToken = try #require(openAdmission.executionToken)
        let openResponse = try BridgeProductControlResponse.workerSessionAccepted(correlating: openRequest)
        let openResponseBytes = try JSONEncoder().encode(openResponse)
        let openOperation = try await session.admitControlOperation(token: openToken, execute: { _ in })
        _ = try await session.completeControl(
            token: openToken,
            exactResponseBytes: openResponseBytes
        )
        await session.settleOperation(operationId: openOperation.operationId, response: openResponse)
        let openResult = await session.operationTable.entriesById[openOperation.operationId]?.settlement
        let openReplay = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: openRequestBytes,
            presentedCapability: capabilityHeader
        )

        // Act: advance Review and File independently.
        let reviewRequestBytes = try controlRequestData(reviewCallObject(requestSequence: 2, epoch: 7))
        let reviewRequest = try decodeControlRequest(reviewRequestBytes)
        let reviewAdmission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: reviewRequestBytes,
            presentedCapability: capabilityHeader
        )
        let reviewToken = try #require(reviewAdmission.executionToken)
        let reviewResponse = try BridgeProductControlResponse.callCompleted(
            correlating: reviewRequest,
            result: .reviewMarkFileViewed
        )
        let reviewOperation = try await session.admitControlOperation(token: reviewToken, execute: { _ in })
        _ = try await session.completeControl(
            token: reviewToken,
            exactResponseBytes: try JSONEncoder().encode(reviewResponse)
        )
        await session.settleOperation(operationId: reviewOperation.operationId, response: reviewResponse)

        let heldProducer = try await installSessionEpochMetadataProducer(
            session: session,
            productAdmission: productAdmission.context
        )
        defer { heldProducer.release() }

        try await openFileSessionEpochSubscription(
            session: session,
            productAdmission: productAdmission,
            capabilityHeader: capabilityHeader
        )

        let staleReviewBytes = try controlRequestData(reviewCallObject(requestSequence: 4, epoch: 6))
        let staleReviewRequest = try decodeControlRequest(staleReviewBytes)
        let staleReviewAdmission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: staleReviewBytes,
            presentedCapability: capabilityHeader
        )
        let finalSnapshot = await session.snapshot

        // Assert
        #expect(openReplay == .replay(exactResponseBytes: openOperation.responseBytes))
        #expect(openResult?.outcome == .succeeded)
        #expect(
            staleReviewAdmission
                == .rejected(
                    .init(
                        reason: .staleDerivationEpoch(
                            currentWorkerDerivationEpoch: 7,
                            surface: .review
                        ),
                        request: staleReviewRequest
                    )
                )
        )
        #expect(finalSnapshot.lifecycle == .active)
        #expect(finalSnapshot.workerDerivationEpochBySurface[.review] == 7)
        #expect(finalSnapshot.workerDerivationEpochBySurface[.file] == 2)
        #expect(finalSnapshot.controlReplay.nextExpectedRequestSequence == 4)
        #expect(finalSnapshot.pendingRequestKind == nil)
    }

    @Test("control replay cache admits one request and replays only exact completed bytes")
    func controlReplayRequiresExactCompletedRequestBytes() throws {
        // Arrange
        var replayCache = BridgeProductControlReplayCache()
        let requestBytes = Data(#"{"kind":"workerSession.open","requestSequence":1}"#.utf8)
        let changedRequestBytes = Data(#"{"kind":"workerSession.open","requestSequence":1,"changed":true}"#.utf8)
        let responseBytes = Data(#"{"kind":"workerSession.accepted","requestSequence":1}"#.utf8)

        // Act
        let firstAdmission = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: requestBytes
        )
        let token = try #require(firstAdmission.executionToken)
        let concurrentAdmission = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: requestBytes
        )
        try replayCache.complete(token: token, exactResponseBytes: responseBytes)
        let exactRetry = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: requestBytes
        )
        let changedRetry = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: changedRequestBytes
        )

        // Assert
        #expect(concurrentAdmission == .rejected(.requestInFlight(nextExpectedRequestSequence: 1)))
        #expect(exactRetry == .replay(exactResponseBytes: responseBytes))
        #expect(changedRetry == .rejected(.sequenceConflict(nextExpectedRequestSequence: 2)))
        #expect(
            replayCache.snapshot
                == BridgeProductControlReplaySnapshot(
                    inFlightRequestSequence: nil,
                    nextExpectedRequestSequence: 2,
                    replayableRequestSequence: 1
                )
        )
    }

    @Test("abandon releases the admission without advancing request sequence")
    func abandonAllowsTheExpectedRequestToRetry() throws {
        // Arrange
        var replayCache = BridgeProductControlReplayCache()
        let requestBytes = Data("request-one".utf8)
        let firstAdmission = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: requestBytes
        )
        let firstToken = try #require(firstAdmission.executionToken)

        // Act
        try replayCache.abandon(token: firstToken)
        let retryAdmission = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: requestBytes
        )

        // Assert
        #expect(retryAdmission.executionToken != nil)
        #expect(replayCache.snapshot.nextExpectedRequestSequence == 1)
        #expect(replayCache.snapshot.replayableRequestSequence == nil)
    }

    @Test("future sequence and invalid completion token leave cache unchanged")
    func conflictsDoNotMutateReplayState() throws {
        // Arrange
        var replayCache = BridgeProductControlReplayCache()
        let requestBytes = Data("request-one".utf8)
        let initialSnapshot = replayCache.snapshot

        // Act
        let futureAdmission = replayCache.begin(
            requestSequence: 2,
            exactRequestBytes: requestBytes
        )

        // Assert
        #expect(futureAdmission == .rejected(.sequenceConflict(nextExpectedRequestSequence: 1)))
        #expect(replayCache.snapshot == initialSnapshot)
        #expect(throws: BridgeProductControlReplayCacheError.invalidAdmissionToken) {
            try replayCache.complete(
                token: BridgeProductControlAdmissionToken(
                    identifier: .max,
                    requestSequence: 1
                ),
                exactResponseBytes: Data("response".utf8)
            )
        }
        #expect(replayCache.snapshot == initialSnapshot)
    }

    @Test("oversized request and response bytes never become replay state")
    func replayCacheEnforcesItsByteCeilings() throws {
        // Arrange
        var replayCache = BridgeProductControlReplayCache(maximumRequestOrResponseBytes: 8)
        let oversizedBytes = Data(repeating: 0x61, count: 9)

        // Act
        let oversizedAdmission = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: oversizedBytes
        )
        let acceptedAdmission = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: Data("request".utf8)
        )
        let token = try #require(acceptedAdmission.executionToken)

        // Assert
        #expect(oversizedAdmission == .rejected(.payloadTooLarge))
        #expect(throws: BridgeProductControlReplayCacheError.responsePayloadTooLarge) {
            try replayCache.complete(token: token, exactResponseBytes: oversizedBytes)
        }
        #expect(replayCache.snapshot.inFlightRequestSequence == 1)
        #expect(replayCache.snapshot.replayableRequestSequence == nil)
    }
}

extension BridgeProductSessionControlAdmission {
    fileprivate var executionToken: BridgeProductControlAdmissionToken? {
        guard case .execute(let token, _) = self else { return nil }
        return token
    }
}

extension BridgeProductControlReplayAdmission {
    fileprivate var executionToken: BridgeProductControlAdmissionToken? {
        guard case .execute(let token) = self else { return nil }
        return token
    }
}

private func decodeControlRequest(_ data: Data) throws -> BridgeProductControlRequest {
    try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: data)
}

private func controlRequestData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func workerSessionOpenObject(
    workerInstanceId: String = "worker-instance-1"
) -> [String: Any] {
    [
        "kind": "workerSession.open",
        "paneSessionId": "pane-session-1",
        "request": NSNull(),
        "requestId": "request-open-1",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": workerInstanceId,
    ]
}

private func reviewCallObject(requestSequence: Int, epoch: Int) -> [String: Any] {
    [
        "call": [
            "method": "review.markFileViewed",
            "request": ["itemId": "review-item-1"],
        ],
        "kind": "product.call",
        "paneSessionId": "pane-session-1",
        "requestId": "request-review-\(requestSequence)",
        "requestSequence": requestSequence,
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": epoch,
        "workerInstanceId": "worker-instance-1",
    ]
}

private func installSessionEpochMetadataProducer(
    session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionContext
) async throws -> HeldStep<BridgeProductProducerLease> {
    let heldProducer = HeldStep<BridgeProductProducerLease>("sessionEpochMetadataProducer")
    let metadataRequest = try bridgeProductMetadataStreamRequest(
        metadataStreamId: "metadata-epoch-\(UUIDv7.generate().uuidString)",
        resumeFromStreamSequence: nil
    )
    let registration = await session.registerMetadataProducer(
        request: metadataRequest,
        productAdmission: productAdmission
    ) { lease in
        try? await heldProducer.arrive(lease)
    }
    guard case .accepted(let lease) = registration else {
        throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
    }
    #expect(try await heldProducer.firstArrival() == lease)
    _ = try await session.enqueueRequiredProducerOpeningFrame(
        for: lease,
        productAdmission: productAdmission,
        build: { sequence in
            try producerRegistryMetadataOpeningFrame(for: metadataRequest, sequence: sequence)
        }
    )
    return heldProducer
}

private func openFileSessionEpochSubscription(
    session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionTestContext,
    capabilityHeader: String
) async throws {
    let requestBytes = try controlRequestData(fileSubscriptionOpenObject(requestSequence: 3, epoch: 2))
    let request = try decodeControlRequest(requestBytes)
    let admission = await productAdmission.beginControl(
        in: session,
        exactRequestBytes: requestBytes,
        presentedCapability: capabilityHeader
    )
    let token = try #require(admission.executionToken)
    let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
        correlating: request,
        worktreeId: nil
    )
    let operation = try await session.admitControlOperation(token: token, execute: { _ in })
    _ = try await session.completeControl(
        token: token,
        exactResponseBytes: try JSONEncoder().encode(response)
    )
    await session.settleOperation(operationId: operation.operationId, response: response)
}

private func fileSubscriptionOpenObject(requestSequence: Int, epoch: Int) -> [String: Any] {
    [
        "kind": "subscription.open",
        "paneSessionId": "pane-session-1",
        "requestId": "request-file-subscription-\(requestSequence)",
        "requestSequence": requestSequence,
        "subscription": [
            "source": [
                "cwdScope": NSNull(),
                "freshness": "live",
                "includeStatuses": true,
                "repoId": "00000000-0000-4000-8000-000000000001",
                "rootPathToken": "root-token-1",
                "worktreeId": "00000000-0000-4000-8000-000000000002",
            ],
            "subscriptionKind": "file.metadata",
        ],
        "subscriptionId": "file-subscription-1",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": epoch,
        "workerInstanceId": "worker-instance-1",
    ]
}
