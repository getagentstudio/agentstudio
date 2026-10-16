import Foundation
import Testing

@testable import AgentStudioBridge

struct BridgeProductSubscriptionRollingReplayTests {
    @Test("result acknowledgement distinguishes exact replay, sequence conflict, and unknown operation")
    func resultAcknowledgementRefusalBranches() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let metadataLease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        do {
            #expect(
                await consumeNextBridgeProductProducerFrame(
                    for: metadataLease,
                    from: harness.session,
                    productAdmission: harness.productAdmission.context
                )?.sequence == 1
            )
            let request = try makeRequest(revision: 1)
            #expect(
                try await acceptAndReplayScope(
                    request,
                    requestBytes: encode(request),
                    revision: 1,
                    harness: harness,
                    verifyAckRefusals: true
                )
            )
        } catch {
            try await harness.closeProducer(metadataLease)
            await close(harness)
            throw error
        }
        try await harness.closeProducer(metadataLease)
        await close(harness)
    }

    @Test("many typed E4 scopes preserve exact replay and stale sequence rejection through the session")
    func typedScopeReplayOutlivesRecentOperations() async throws {
        // Arrange: real native session, control replay, and subscription transitions.
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let metadataLease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        #expect(
            await consumeNextBridgeProductProducerFrame(
                for: metadataLease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )?.sequence == 1
        )
        var firstRequestBytes: Data?

        do {
            // Act: each admitted view scope is retried exactly before the next.
            for revision in 1...1100 {
                let request = try makeRequest(revision: revision)
                let requestBytes = try encode(request)
                if firstRequestBytes == nil { firstRequestBytes = requestBytes }
                guard
                    try await acceptAndReplayScope(
                        request, requestBytes: requestBytes, revision: revision,
                        harness: harness
                    )
                else { break }
            }
            let oldRequest = try #require(firstRequestBytes)
            let stale = await harness.session.beginControl(
                exactRequestBytes: oldRequest,
                presentedCapability: harness.capabilityHeader,
                productAdmission: harness.productAdmission.context
            )
            guard case .rejected(let rejection) = stale else {
                Issue.record("An old scope request must not replay past the control window")
                try await harness.closeProducer(metadataLease)
                await close(harness)
                return
            }
            #expect(rejection.reason == .sequenceConflict(nextExpectedRequestSequence: 2203))
            #expect(
                await harness.session.subscriptionSnapshot(subscriptionId: "review-subscription-1")?
                    .workerDerivationEpoch
                    == 1)
        } catch {
            try await harness.closeProducer(metadataLease)
            await close(harness)
            throw error
        }
        try await harness.closeProducer(metadataLease)
        await close(harness)
    }

    private func acceptAndReplayScope(
        _ request: BridgeProductControlRequest,
        requestBytes: Data,
        revision: Int,
        harness: BridgeProductSessionLifecycleHarness,
        verifyAckRefusals: Bool = false
    ) async throws -> Bool {
        let admission = await harness.session.beginControl(
            exactRequestBytes: requestBytes,
            presentedCapability: harness.capabilityHeader,
            productAdmission: harness.productAdmission.context
        )
        guard case .execute(let token, _) = admission else {
            Issue.record("Expected a fresh control admission")
            return false
        }
        let response = try BridgeProductControlResponse.viewAccepted(correlating: request)
        let responseBytes = try encode(response)
        let effect = try await harness.session.completeAdmittedControl(
            token: token, exactResponseBytes: responseBytes)
        guard case .viewScopeAccepted(let scope) = effect else {
            Issue.record("Expected an accepted typed view scope")
            return false
        }
        #expect(scope.scopeRevision == revision)
        #expect(await harness.session.acceptViewScope(scope, productAdmission: harness.productAdmission.context) == nil)
        let after = await harness.session.subscriptionSnapshot(subscriptionId: "review-subscription-1")
        let replay = await harness.session.beginControl(
            exactRequestBytes: requestBytes,
            presentedCapability: harness.capabilityHeader,
            productAdmission: harness.productAdmission.context
        )

        // Assert: replay returns identical bytes and performs no second mutation.
        #expect(after?.workerDerivationEpoch == 1)
        guard case .replay(let admittedBytes) = replay else {
            Issue.record("Expected exact replay of the stored operation admission")
            return false
        }
        let admitted = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: admittedBytes
        )
        #expect(admitted.correlation == request.correlation)
        let resultRequest = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultRequest.self,
            from: JSONSerialization.data(withJSONObject: [
                "kind": "operation.result",
                "operationId": admitted.operationId,
                "paneSessionId": request.paneSessionId,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": request.workerInstanceId,
            ])
        )
        let result = try #require(
            await harness.session.readOperationResult(
                resultRequest,
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(result.outcome == .succeeded)
        #expect(
            result.result
                == (try JSONDecoder().decode(BridgeProductJSONValue.self, from: responseBytes))
        )
        let acknowledgement = BridgeProductOperationResultAcknowledgement(
            correlation: try .init(
                paneSessionId: request.paneSessionId,
                requestId: "rolling-result-ack-\(revision)",
                requestSequence: revision * 2 + 2,
                workerInstanceId: request.workerInstanceId
            ),
            operationId: admitted.operationId
        )
        let ackResult = await harness.session.acknowledgeOperationResult(
            acknowledgement,
            exactRequestBytes: try encode(acknowledgement),
            productAdmission: harness.productAdmission.context
        )
        guard case .success = ackResult else {
            Issue.record("Expected result acknowledgement success, got \(ackResult)")
            return false
        }
        if verifyAckRefusals {
            guard
                try await verifyAckRefusalBranches(
                    acknowledgement: acknowledgement,
                    harness: harness,
                    revision: revision
                )
            else { return false }
        }
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: "review-subscription-1") == after)
        return true
    }

    private func verifyAckRefusalBranches(
        acknowledgement: BridgeProductOperationResultAcknowledgement,
        harness: BridgeProductSessionLifecycleHarness,
        revision: Int
    ) async throws -> Bool {
        let exactReplay = await harness.session.acknowledgeOperationResult(
            acknowledgement,
            exactRequestBytes: try encode(acknowledgement),
            productAdmission: harness.productAdmission.context
        )
        guard case .success = exactReplay else {
            Issue.record("Expected an exact acknowledgement replay, got \(exactReplay)")
            return false
        }
        let conflictingAcknowledgement = BridgeProductOperationResultAcknowledgement(
            correlation: try .init(
                paneSessionId: acknowledgement.correlation.paneSessionId,
                requestId: "rolling-result-ack-conflict-\(revision)",
                requestSequence: acknowledgement.correlation.requestSequence,
                workerInstanceId: acknowledgement.correlation.workerInstanceId
            ),
            operationId: acknowledgement.operationId
        )
        let sequenceConflict = await harness.session.acknowledgeOperationResult(
            conflictingAcknowledgement,
            exactRequestBytes: try encode(conflictingAcknowledgement),
            productAdmission: harness.productAdmission.context
        )
        guard case .failure(let sequenceRefusal) = sequenceConflict,
            sequenceRefusal.kind == .requestSequenceRejected,
            sequenceRefusal.replayRejectionKind == .sequenceConflict,
            sequenceRefusal.nextExpectedRequestSequence == acknowledgement.correlation.requestSequence + 1
        else {
            Issue.record("Expected a typed request-sequence refusal, got \(sequenceConflict)")
            return false
        }
        let unknownAcknowledgement = BridgeProductOperationResultAcknowledgement(
            correlation: try .init(
                paneSessionId: acknowledgement.correlation.paneSessionId,
                requestId: "rolling-result-ack-unknown-\(revision)",
                requestSequence: acknowledgement.correlation.requestSequence + 1,
                workerInstanceId: acknowledgement.correlation.workerInstanceId
            ),
            operationId: acknowledgement.operationId
        )
        let unknownOperation = await harness.session.acknowledgeOperationResult(
            unknownAcknowledgement,
            exactRequestBytes: try encode(unknownAcknowledgement),
            productAdmission: harness.productAdmission.context
        )
        guard case .failure(let unknownRefusal) = unknownOperation,
            unknownRefusal.kind == .unknownOperation
        else {
            Issue.record("Expected a typed unknown-operation refusal, got \(unknownOperation)")
            return false
        }
        return true
    }

    private func makeRequest(revision: Int) throws -> BridgeProductControlRequest {
        let lane: BridgeProductDemandLane = revision.isMultiple(of: 2) ? .visible : .foreground
        return try bridgeProductLifecycleControlRequest([
            "kind": "subscription.setScope",
            "paneSessionId": "pane-session-1",
            "workerInstanceId": "worker-instance-1",
            "wireVersion": BridgeProductWireContract.version,
            "requestId": "rolling-control-\(revision)",
            "requestSequence": revision * 2 + 1,
            "subscriptionId": "review-subscription-1",
            "subscriptionKind": "review.metadata",
            "domain": "default",
            "handle": "rolling-review-handle",
            "incarnation": "rolling-review-incarnation",
            "scopeRevision": revision,
            "scope": [
                "kind": "review",
                "interests": [["itemIds": ["rolling-item"], "lane": lane.rawValue]],
            ],
        ])
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func close(_ harness: BridgeProductSessionLifecycleHarness) async {
        let barrier = await harness.session.revoke { _ in true }
        #expect(await barrier.wait())
    }
}
