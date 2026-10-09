import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session request error boundary")
struct BridgeProductSessionRequestErrorTests {
    @Test("request error sequence mismatch is atomic and preserves exact retry")
    func requestErrorSequenceMismatchLeavesPendingMutationUnchanged() async throws {
        // Arrange
        let harness = try await RequestErrorSessionHarness.opened()
        let requestBytes = try requestErrorJSONData(reviewSubscriptionOpenObject())
        let token = try await harness.beginExecution(requestBytes)
        let admitted = try await harness.session.admitControlOperation(token: token, execute: { _ in })
        let pendingSnapshot = await harness.session.snapshot
        let pendingSubscription = await harness.session.subscriptionSnapshot(
            subscriptionId: requestErrorReviewSubscriptionId
        )
        let baseResponseObject = requestErrorObject()
        let invalidNextExpectedSequences: [Any] = [4, NSNull()]

        // Act / Assert
        for invalidNextExpectedSequence in invalidNextExpectedSequences {
            var mismatchedResponseObject = baseResponseObject
            mismatchedResponseObject["nextExpectedRequestSequence"] = invalidNextExpectedSequence
            await expectRequestErrorCompletionFailure(
                session: harness.session,
                token: token,
                responseBytes: try requestErrorJSONData(mismatchedResponseObject)
            )
            #expect((await harness.session.snapshot) == pendingSnapshot)
            #expect(
                await harness.session.subscriptionSnapshot(
                    subscriptionId: requestErrorReviewSubscriptionId
                ) == pendingSubscription
            )
        }
        #expect(pendingSnapshot.lifecycle == .active)
        #expect(pendingSnapshot.pendingRequestKind == nil)
        #expect(pendingSnapshot.controlReplay.inFlightRequestSequence == nil)
        #expect(pendingSnapshot.controlReplay.nextExpectedRequestSequence == 3)

        let correctResponseBytes = try requestErrorJSONData(baseResponseObject)
        let completionEffects = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: correctResponseBytes
        )
        let completedSnapshot = await harness.session.snapshot
        let retryAdmission = await harness.begin(requestBytes)

        #expect(completionEffects == .noEffect)
        #expect(completedSnapshot.lifecycle == .active)
        #expect(completedSnapshot.pendingRequestKind == nil)
        #expect(completedSnapshot.controlReplay.inFlightRequestSequence == nil)
        #expect(completedSnapshot.controlReplay.nextExpectedRequestSequence == 3)
        #expect(completedSnapshot.controlReplay.replayableRequestSequence == 2)
        #expect(retryAdmission == .replay(exactResponseBytes: admitted.responseBytes))
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: requestErrorReviewSubscriptionId
            ) == nil
        )
    }
}

private let requestErrorPaneSessionId = "pane-session-request-error"
private let requestErrorWorkerInstanceId = "worker-instance-request-error"
private let requestErrorReviewSubscriptionId = "review-subscription-request-error"

private struct RequestErrorSessionHarness {
    let capabilityHeader: String
    let productAdmission: BridgeProductAdmissionTestContext
    let session: BridgeProductSession

    static func opened() async throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let harness = try Self(
            capabilityHeader: BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes),
            productAdmission: .make(),
            session: BridgeProductSession(
                paneSessionId: requestErrorPaneSessionId,
                workerInstanceId: requestErrorWorkerInstanceId,
                capabilityBytes: capabilityBytes
            )
        )
        let requestBytes = try requestErrorJSONData(workerSessionOpenObject())
        let responseBytes = try requestErrorJSONData(
            requestErrorControlIdentity(
                kind: "workerSession.accepted",
                requestId: "request-open-request-error",
                requestSequence: 1
            ).merging(["result": NSNull()]) { _, newValue in newValue }
        )
        let token = try await harness.beginExecution(requestBytes)
        _ = try await harness.session.completeAdmittedControl(
            token: token,
            exactResponseBytes: responseBytes
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

    func beginExecution(_ requestBytes: Data) async throws
        -> BridgeProductControlAdmissionToken
    {
        guard case .execute(let token, _) = await begin(requestBytes) else {
            throw RequestErrorSessionHarnessError.expectedExecution
        }
        return token
    }
}

private enum RequestErrorSessionHarnessError: Error {
    case expectedExecution
}

private func expectRequestErrorCompletionFailure(
    session: BridgeProductSession,
    token: BridgeProductControlAdmissionToken,
    responseBytes: Data
) async {
    do {
        _ = try await session.completeAdmittedControl(
            token: token,
            exactResponseBytes: responseBytes
        )
        Issue.record("Expected mismatched request.error response")
    } catch let error as BridgeProductSessionError {
        #expect(error == .mismatchedControlResponse)
    } catch {
        Issue.record("Unexpected request.error completion failure: \(error)")
    }
}

private func workerSessionOpenObject() -> [String: Any] {
    requestErrorControlIdentity(
        kind: "workerSession.open",
        requestId: "request-open-request-error",
        requestSequence: 1
    ).merging(["request": NSNull()]) { _, newValue in newValue }
}

private func reviewSubscriptionOpenObject() -> [String: Any] {
    requestErrorControlIdentity(
        kind: "subscription.open",
        requestId: "request-review-open-2",
        requestSequence: 2
    ).merging([
        "subscription": ["subscriptionKind": "review.metadata"],
        "subscriptionId": requestErrorReviewSubscriptionId,
        "workerDerivationEpoch": 7,
    ]) { _, newValue in newValue }
}

private func requestErrorObject() -> [String: Any] {
    requestErrorControlIdentity(
        kind: "request.error",
        requestId: "request-review-open-2",
        requestSequence: 2
    ).merging([
        "code": "unsupported_subscription",
        "nextExpectedRequestSequence": 3,
        "retryAfterMilliseconds": NSNull(),
        "retryable": false,
        "safeMessage": "Unsupported subscription",
    ]) { _, newValue in newValue }
}

private func requestErrorControlIdentity(
    kind: String,
    requestId: String,
    requestSequence: Int
) -> [String: Any] {
    [
        "kind": kind,
        "paneSessionId": requestErrorPaneSessionId,
        "requestId": requestId,
        "requestSequence": requestSequence,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": requestErrorWorkerInstanceId,
    ]
}

private func requestErrorJSONData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
