import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session control mutation boundary")
struct BridgeProductSessionControlMutationTests {
    @Test("scope for an unknown subscription is refused before execution")
    func unknownSubscriptionScopeIsTypedRefusal() async throws {
        let harness = try await RawControlSessionHarness.opened()
        defer { harness.metadataProducer.release() }
        let requestBytes = try jsonData(reviewViewScopeObject(requestSequence: 2))

        let admission = await harness.begin(requestBytes)

        guard case .rejected(let rejection) = admission else {
            Issue.record("Unknown subscription scope was admitted")
            return
        }
        #expect(rejection.reason == .unknownSubscription)
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: reviewSubscriptionId) == nil)
    }

    @Test("one accepted scope settles once and exact replay leaves subscription state unchanged")
    func acceptedScopeSettlesOnceAndReplays() async throws {
        let harness = try await RawControlSessionHarness.opened()
        defer { harness.metadataProducer.release() }
        _ = try await openReviewSubscription(harness)
        let openedSnapshot = try #require(
            await harness.session.subscriptionSnapshot(subscriptionId: reviewSubscriptionId)
        )
        let requestBytes = try jsonData(reviewViewScopeObject(requestSequence: 3))
        let request = try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: requestBytes)
        let acceptedResponse = try BridgeProductControlResponse.viewAccepted(correlating: request)
        let responseBytes = try JSONEncoder().encode(acceptedResponse)

        let effect = try await harness.execute(requestBytes: requestBytes, responseBytes: responseBytes)
        guard case .viewScopeAccepted(let acceptedScope) = effect else {
            Issue.record("Expected accepted typed view scope")
            return
        }
        #expect(acceptedScope.subscriptionId == reviewSubscriptionId)
        #expect(acceptedScope.scopeRevision == 1)
        let completedSession = await harness.session.snapshot
        let replay = try admittedReplay(await harness.begin(requestBytes))
        #expect(replay.correlation.requestSequence == 3)
        #expect((await harness.session.snapshot) == completedSession)
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: reviewSubscriptionId) == openedSnapshot)
    }

    @Test("mismatched typed scope response cannot commit a pending control")
    func scopeResponseMismatchesLeavePendingStateUnchanged() async throws {
        let harness = try await RawControlSessionHarness.opened()
        defer { harness.metadataProducer.release() }
        _ = try await openReviewSubscription(harness)
        let requestBytes = try jsonData(reviewViewScopeObject(requestSequence: 3))
        let request = try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: requestBytes)
        let response = try BridgeProductControlResponse.viewAccepted(correlating: request)
        let responseObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        let token = try await harness.beginExecution(requestBytes)
        let pendingSession = await harness.session.snapshot
        let pendingSubscription = await harness.session.subscriptionSnapshot(subscriptionId: reviewSubscriptionId)
        let mismatches = try [
            responseMismatch("handle", responseObject, key: "handle", value: "other-handle"),
            responseMismatch("incarnation", responseObject, key: "incarnation", value: "other-incarnation"),
            responseMismatch("scopeRevision", responseObject, key: "scopeRevision", value: 2),
            responseMismatch("subscriptionId", responseObject, key: "subscriptionId", value: "other-subscription"),
            responseMismatch("subscriptionKind", responseObject, key: "subscriptionKind", value: "file.metadata"),
            responseMismatch("requestId", responseObject, key: "requestId", value: "other-request"),
        ]
        for mismatch in mismatches {
            await expectCompletionError(
                .mismatchedControlResponse,
                context: mismatch.name,
                session: harness.session,
                token: token,
                responseBytes: mismatch.bytes
            )
            #expect((await harness.session.snapshot) == pendingSession)
            #expect(
                await harness.session.subscriptionSnapshot(subscriptionId: reviewSubscriptionId)
                    == pendingSubscription
            )
        }
        let effect = try await harness.session.completeControl(
            token: token,
            exactResponseBytes: JSONEncoder().encode(response)
        )
        guard case .viewScopeAccepted(let acceptedScope) = effect else {
            Issue.record("Expected a typed scope effect after a matching response")
            return
        }
        #expect(acceptedScope.scopeRevision == 1)
        #expect((await harness.session.snapshot).controlReplay.nextExpectedRequestSequence == 4)
    }

    @Test("request error completes replay without applying the candidate open")
    func requestErrorDoesNotApplyCandidateMutation() async throws {
        // Arrange
        let harness = try await RawControlSessionHarness.opened()
        defer { harness.metadataProducer.release() }
        let requestBytes = try jsonData(reviewSubscriptionOpenObject(requestSequence: 2))
        let responseBytes = try jsonData(
            requestErrorObject(
                requestId: reviewSubscriptionOpenRequestId(requestSequence: 2),
                requestSequence: 2
            ))
        let token = try await harness.beginExecution(requestBytes)

        // Act
        let effects = try await harness.session.completeControl(
            token: token,
            exactResponseBytes: responseBytes
        )
        let subscriptionAfterError = await harness.session.subscriptionSnapshot(
            subscriptionId: reviewSubscriptionId
        )
        let completedSnapshot = await harness.session.snapshot
        let retryAdmission = await harness.begin(requestBytes)

        // Assert
        #expect(effects == .noEffect)
        #expect(subscriptionAfterError == nil)
        #expect(completedSnapshot.pendingRequestKind == nil)
        #expect(completedSnapshot.controlReplay.nextExpectedRequestSequence == 3)
        #expect(completedSnapshot.controlReplay.replayableRequestSequence == 2)
        let replay = try admittedReplay(retryAdmission)
        #expect(replay.correlation.requestSequence == 2)
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: reviewSubscriptionId) == nil
        )
    }

    @Test("invalid bytes and cross-wired responses never become replay entries")
    func invalidAndCrossWiredBytesCannotEnterReplay() async throws {
        // Arrange
        let harness = try await RawControlSessionHarness.opened()
        defer { harness.metadataProducer.release() }
        let initialSnapshot = await harness.session.snapshot
        let invalidRequests = [
            Data("{".utf8),
            Data([0xFF]),
            Data(#"{"kind":"workerSession.open","kind":"product.call"}"#.utf8),
        ]

        // Act / Assert
        for invalidRequest in invalidRequests {
            #expect(
                await harness.begin(invalidRequest) == .rejected(.invalidRequest)
            )
            #expect((await harness.session.snapshot) == initialSnapshot)
        }

        let requestBytes = try jsonData(reviewSubscriptionOpenObject(requestSequence: 2))
        let token = try await harness.beginExecution(requestBytes)
        let pendingSnapshot = await harness.session.snapshot
        let invalidResponseBytes = [
            Data("{".utf8),
            try jsonData(
                reviewSubscriptionOpenAcceptedObject(requestSequence: 2).merging(["unexpected": true]) { _, newValue in
                    newValue
                }
            ),
        ]

        for responseBytes in invalidResponseBytes {
            await expectCompletionError(
                .invalidControlResponse,
                context: "invalid response bytes",
                session: harness.session,
                token: token,
                responseBytes: responseBytes
            )
            #expect((await harness.session.snapshot) == pendingSnapshot)
            #expect(
                await harness.session.subscriptionSnapshot(subscriptionId: reviewSubscriptionId)
                    == nil
            )
        }

        let crossWiredResponseBytes = try jsonData(
            controlIdentity(
                kind: "workerSession.accepted",
                requestId: reviewSubscriptionOpenRequestId(requestSequence: 2),
                requestSequence: 2
            ).merging(["result": NSNull()]) { _, newValue in newValue }
        )
        await expectCompletionError(
            .mismatchedControlResponse,
            context: "cross-wired response kind",
            session: harness.session,
            token: token,
            responseBytes: crossWiredResponseBytes
        )

        #expect((await harness.session.snapshot) == pendingSnapshot)
        #expect(pendingSnapshot.controlReplay.inFlightRequestSequence == nil)
        #expect(pendingSnapshot.controlReplay.replayableRequestSequence == 2)

        let correctResponseBytes = try jsonData(
            reviewSubscriptionOpenAcceptedObject(requestSequence: 2))
        _ = try await harness.session.completeControl(
            token: token,
            exactResponseBytes: correctResponseBytes
        )
        let retryAdmission = await harness.begin(requestBytes)

        let replay = try admittedReplay(retryAdmission)
        #expect(replay.correlation.requestSequence == 2)
    }
}

private let paneSessionId = "pane-session-1"
private let workerInstanceId = "worker-instance-1"
private let reviewSubscriptionId = "review-subscription-1"
private let reviewEpoch = 7

private struct RawControlSessionHarness {
    let capabilityHeader: String
    let metadataProducer: HeldStep<BridgeProductProducerLease>
    let productAdmission: BridgeProductAdmissionTestContext
    let session: BridgeProductSession

    static func opened() async throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let metadataProducer = HeldStep<BridgeProductProducerLease>("rawControlMetadataProducer")
        let harness = try Self(
            capabilityHeader: BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes),
            metadataProducer: metadataProducer,
            productAdmission: .make(),
            session: BridgeProductSession(
                paneSessionId: paneSessionId,
                workerInstanceId: workerInstanceId,
                capabilityBytes: capabilityBytes
            )
        )
        let requestBytes = try jsonData(workerSessionOpenObject())
        let responseBytes = try jsonData(
            controlIdentity(
                kind: "workerSession.accepted",
                requestId: "request-open-1",
                requestSequence: 1
            ).merging(["result": NSNull()]) { _, newValue in newValue }
        )
        _ = try await harness.execute(requestBytes: requestBytes, responseBytes: responseBytes)
        let metadataRequest = try bridgeProductMetadataStreamRequest(
            metadataStreamId: "metadata-control-mutation-\(UUIDv7.generate().uuidString)",
            resumeFromStreamSequence: nil
        )
        let registration = await harness.session.registerMetadataProducer(
            request: metadataRequest,
            productAdmission: harness.productAdmission.context
        ) { lease in
            try? await metadataProducer.arrive(lease)
        }
        guard case .accepted(let lease) = registration else {
            throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
        }
        #expect(try await metadataProducer.firstArrival() == lease)
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission.context,
            build: { sequence in
                try producerRegistryMetadataOpeningFrame(for: metadataRequest, sequence: sequence)
            }
        )
        return harness
    }

    func begin(_ requestBytes: Data) async -> BridgeProductSessionControlAdmission {
        await productAdmission.beginControl(
            in: session,
            exactRequestBytes: requestBytes,
            presentedCapability: capabilityHeader
        )
    }

    func beginExecution(_ requestBytes: Data) async throws -> BridgeProductControlAdmissionToken {
        let admission = await begin(requestBytes)
        guard case .execute(let token, _) = admission else {
            Issue.record("Expected execution admission, received \(admission)")
            throw RawControlSessionHarnessError.expectedExecution
        }
        _ = try await session.admitControlOperation(token: token, execute: { _ in })
        return token
    }

    func execute(
        requestBytes: Data,
        responseBytes: Data
    ) async throws -> BridgeProductSessionCompletionEffect {
        let token = try await beginExecution(requestBytes)
        let effect = try await session.completeControl(
            token: token,
            exactResponseBytes: responseBytes
        )
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: responseBytes
        )
        if let operationId = await session.operationTable.entry(for: token)?.operationId {
            await session.settleOperation(operationId: operationId, response: response)
        }
        return effect
    }
}

private enum RawControlSessionHarnessError: Error {
    case expectedExecution
}

private func admittedReplay(
    _ admission: BridgeProductSessionControlAdmission
) throws -> BridgeProductOperationAdmittedResponse {
    guard case .replay(let exactResponseBytes) = admission else {
        Issue.record("Expected exact replay of the operation admission")
        throw RawControlSessionHarnessError.expectedExecution
    }
    return try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: exactResponseBytes
    )
}

private struct ResponseMismatchFixture: Sendable {
    let name: String
    let bytes: Data
}

private func openReviewSubscription(
    _ harness: RawControlSessionHarness
) async throws -> BridgeProductSessionCompletionEffect {
    try await harness.execute(
        requestBytes: jsonData(reviewSubscriptionOpenObject(requestSequence: 2)),
        responseBytes: jsonData(reviewSubscriptionOpenAcceptedObject(requestSequence: 2))
    )
}

private func expectCompletionError(
    _ expectedError: BridgeProductSessionError,
    context: String,
    session: BridgeProductSession,
    token: BridgeProductControlAdmissionToken,
    responseBytes: Data
) async {
    do {
        _ = try await session.completeControl(
            token: token,
            exactResponseBytes: responseBytes
        )
        Issue.record("Expected \(expectedError) for \(context)")
    } catch let error as BridgeProductSessionError {
        #expect(error == expectedError, "Unexpected error for \(context)")
    } catch {
        Issue.record("Unexpected non-session error for \(context): \(error)")
    }
}

private func responseMismatch(
    _ name: String,
    _ correctResponse: [String: Any],
    key: String,
    value: Any
) throws -> ResponseMismatchFixture {
    var mismatchResponse = correctResponse
    mismatchResponse[key] = value
    return try ResponseMismatchFixture(name: name, bytes: jsonData(mismatchResponse))
}

private func workerSessionOpenObject() -> [String: Any] {
    controlIdentity(
        kind: "workerSession.open",
        requestId: "request-open-1",
        requestSequence: 1
    ).merging(["request": NSNull()]) { _, newValue in newValue }
}

private func reviewSubscriptionOpenObject(requestSequence: Int) -> [String: Any] {
    surfaceControlRequestIdentity(
        kind: "subscription.open",
        requestId: reviewSubscriptionOpenRequestId(requestSequence: requestSequence),
        requestSequence: requestSequence
    ).merging([
        "subscription": ["subscriptionKind": "review.metadata"],
        "subscriptionId": reviewSubscriptionId,
    ]) { _, newValue in newValue }
}

private func reviewSubscriptionOpenAcceptedObject(
    requestSequence: Int
) -> [String: Any] {
    controlIdentity(
        kind: "subscription.openAccepted",
        requestId: reviewSubscriptionOpenRequestId(requestSequence: requestSequence),
        requestSequence: requestSequence
    ).merging([
        "subscriptionId": reviewSubscriptionId,
        "subscriptionKind": "review.metadata",
    ]) { _, newValue in newValue }
}

private func reviewViewScopeObject(requestSequence: Int) -> [String: Any] {
    controlIdentity(
        kind: "subscription.setScope",
        requestId: "request-review-scope-\(requestSequence)",
        requestSequence: requestSequence
    ).merging([
        "domain": "default",
        "handle": "review-handle-1",
        "incarnation": "review-incarnation-1",
        "scope": ["kind": "review", "interests": []],
        "scopeRevision": 1,
        "subscriptionId": reviewSubscriptionId,
        "subscriptionKind": "review.metadata",
    ]) { _, newValue in newValue }
}

private func requestErrorObject(
    requestId: String,
    requestSequence: Int
) -> [String: Any] {
    controlIdentity(
        kind: "request.error",
        requestId: requestId,
        requestSequence: requestSequence
    ).merging([
        "code": "unsupported_subscription",
        "nextExpectedRequestSequence": requestSequence + 1,
        "retryAfterMilliseconds": NSNull(),
        "retryable": false,
        "safeMessage": "Unsupported subscription",
    ]) { _, newValue in newValue }
}

private func surfaceControlRequestIdentity(
    kind: String,
    requestId: String,
    requestSequence: Int
) -> [String: Any] {
    controlIdentity(
        kind: kind,
        requestId: requestId,
        requestSequence: requestSequence
    ).merging(["workerDerivationEpoch": reviewEpoch]) { _, newValue in newValue }
}

private func controlIdentity(
    kind: String,
    requestId: String,
    requestSequence: Int
) -> [String: Any] {
    [
        "kind": kind,
        "paneSessionId": paneSessionId,
        "requestId": requestId,
        "requestSequence": requestSequence,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": workerInstanceId,
    ]
}

private func reviewSubscriptionOpenRequestId(requestSequence: Int) -> String {
    "request-review-open-\(requestSequence)"
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
