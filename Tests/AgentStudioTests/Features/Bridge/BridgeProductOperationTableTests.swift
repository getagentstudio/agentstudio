import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

private typealias OperationRead = BridgeProductOperationResultResponse?

@Suite("Bridge product operation result table")
struct BridgeProductOperationTableTests {
    @Test("revocation observes an execution registered with its admission")
    func revocationTracksExecutionFromAdmission() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: bridgeProductSchemeReviewCallBody(requestSequence: 2)
        )
        guard case .execute(let token, _) = try await harness.begin(request) else {
            Issue.record("Expected a product call admission")
            return
        }
        let heldExecution = HeldStep<Void>(
            "operationExecutionAfterRevocation",
            cancellation: .holdThroughCancellation
        )
        let admitted = try await harness.session.admitControlOperation(token: token) { _ in
            try? await heldExecution.arrive(())
        }
        _ = try await heldExecution.firstArrival()
        #expect((await harness.session.diagnosticSnapshot).activeOperationExecutionCount == 1)

        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
        try await heldExecution.cancellationObserved()
        #expect((await harness.session.diagnosticSnapshot).activeOperationExecutionCount == 1)

        heldExecution.release()
        await harness.session.waitForOperationExecution(operationId: admitted.operationId)
        #expect((await harness.session.diagnosticSnapshot).activeOperationExecutionCount == 0)
    }

    @Test("cancelled result reader releases its waiter without consuming the eventual settlement")
    func cancellingResultReaderPreservesSettlement() async throws {
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: bridgeProductSchemeReviewCallBody(requestSequence: 3)
        )
        let token = BridgeProductControlAdmissionToken(identifier: 1, requestSequence: 3)
        let operationId = UUIDv7.generate().uuidString.lowercased()
        var table = BridgeProductOperationTable()
        table.admit(
            operationId: operationId,
            waitKind: .ordinary,
            admission: .init(
                deferredResyncEpochs: [:],
                productAdmission: try BridgeProductAdmissionTestContext.make().context,
                request: request,
                token: token
            )
        )

        let cancelledWaiterId = UUIDv7.generate()
        let cancelledReadResults = Mutex<[OperationRead]>([])
        table.observeResult(
            operationId: operationId,
            waiterId: cancelledWaiterId,
            resume: { result in cancelledReadResults.withLock { $0.append(result) } }
        )
        table.cancelResultWaiter(operationId: operationId, waiterId: cancelledWaiterId)
        #expect(cancelledReadResults.withLock { $0.count } == 1)
        let cancelledRead = try #require(cancelledReadResults.withLock { $0.first })
        #expect(cancelledRead == nil)
        #expect(table.entriesById[operationId]?.resultWaiters.isEmpty == true)

        let settlement = BridgeProductOperationResultResponse(
            operationId: operationId,
            outcome: .failed
        )
        let didSettle = table.settle(settlement)
        #expect(didSettle)
        let repeatedReadResults = Mutex<[OperationRead]>([])
        table.observeResult(
            operationId: operationId,
            waiterId: UUIDv7.generate(),
            resume: { result in repeatedReadResults.withLock { $0.append(result) } }
        )
        #expect(repeatedReadResults.withLock { $0.count } == 1)
        let repeatedRead = try #require(repeatedReadResults.withLock { $0.first })
        #expect(repeatedRead == settlement)
        let didAcknowledge = table.acknowledge(operationId: operationId)
        #expect(didAcknowledge)
        #expect(table.entriesById.isEmpty)
    }

    @Test("session end sends cancelled to a pending reader and forgets every retained result")
    func sessionEndSettlesReaderAndClearsStore() async throws {
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: bridgeProductSchemeReviewCallBody(requestSequence: 3)
        )
        let operationId = UUIDv7.generate().uuidString.lowercased()
        var table = BridgeProductOperationTable()
        table.admit(
            operationId: operationId,
            waitKind: .ordinary,
            admission: .init(
                deferredResyncEpochs: [:],
                productAdmission: try BridgeProductAdmissionTestContext.make().context,
                request: request,
                token: BridgeProductControlAdmissionToken(identifier: 2, requestSequence: 3)
            )
        )

        let observedResults = Mutex<[OperationRead]>([])
        table.observeResult(
            operationId: operationId,
            waiterId: UUIDv7.generate(),
            resume: { result in observedResults.withLock { $0.append(result) } }
        )
        table.cancelAndForgetAllOperations()
        #expect(observedResults.withLock { $0.count } == 1)
        let observed = try #require(observedResults.withLock { $0.first })
        #expect(observed?.outcome == .cancelled)
        #expect(table.entriesById.isEmpty)
        #expect(table.executionTasksById.isEmpty)
    }

    @Test("acknowledging unknown revision one preserves late revision two evidence")
    func lateMutationEvidenceSurvivesUnknownAcknowledgement() async throws {
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: bridgeProductSchemeReviewCallBody(requestSequence: 3)
        )
        let operationId = UUIDv7.generate().uuidString.lowercased()
        var table = BridgeProductOperationTable(maximumMutationWatches: 1)
        table.admit(
            operationId: operationId,
            waitKind: .ordinary,
            isMutation: true,
            admission: .init(
                deferredResyncEpochs: [:],
                productAdmission: try BridgeProductAdmissionTestContext.make().context,
                request: request,
                token: .init(identifier: 3, requestSequence: 3)
            )
        )
        #expect(!table.hasMutationWatchCapacity)
        let unknown = table.settle(.init(operationId: operationId, outcome: .outcomeUnknown))
        let late = table.recordLateOutcome(
            operationId: operationId,
            outcome: .succeeded,
            result: .object(["committed": .boolean(true)])
        )
        let acknowledgedUnknown = table.acknowledge(operationId: operationId)
        let observedResults = Mutex<[BridgeProductOperationObservationResponse?]>([])
        table.observeAfter(
            operationId: operationId,
            revision: 1,
            waiterId: UUIDv7.generate(),
            resume: { result in observedResults.withLock { $0.append(result) } }
        )
        #expect(observedResults.withLock { $0.count } == 1)
        let observed = try #require(observedResults.withLock { $0.first })
        #expect(unknown && late && acknowledgedUnknown)
        guard case .lateOutcome(let evidence) = observed else {
            Issue.record("Revision two was lost after revision one acknowledgement")
            return
        }
        #expect(evidence.revision == 2)
        #expect(evidence.outcome == .succeeded)
        let acknowledgedLate = table.acknowledgeLateOutcome(operationId: operationId, revision: 2)
        #expect(acknowledgedLate)
        #expect(table.hasMutationWatchCapacity)
    }

    @Test("a full mutation-watch pool refuses another mutation while a read still admits")
    func fullWatchPoolLeavesReadsAvailable() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened(maximumMutationWatches: 1)
        let firstMutation = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: bridgeProductSchemeReviewCallBody(requestSequence: 2)
        )
        guard case .execute(let firstToken, _) = try await harness.begin(firstMutation) else {
            Issue.record("Expected the first mutation admission")
            return
        }
        _ = try await harness.session.admitControlOperation(token: firstToken, execute: { _ in })
        let secondMutation = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: bridgeProductSchemeReviewCallBody(requestSequence: 3)
        )
        guard case .rejected(let rejection) = try await harness.begin(secondMutation) else {
            Issue.record("Expected mutation watch capacity refusal")
            return
        }
        #expect(rejection.reason == .mutationWatchCapacityExhausted)

        let readBytes = try JSONSerialization.data(withJSONObject: [
            "call": ["method": "file.source.current", "request": [:]],
            "kind": "product.call",
            "paneSessionId": "pane-session-1",
            "requestId": "read-with-full-watch-pool",
            "requestSequence": 3,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": 1,
            "workerInstanceId": "worker-instance-1",
        ])
        let read = try BridgeProductStrictJSON.decode(BridgeProductControlRequest.self, from: readBytes)
        guard case .execute(let readToken, _) = try await harness.begin(read) else {
            Issue.record("Expected the independent read to admit")
            return
        }
        try await harness.session.abandonControl(token: readToken)
        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
    }
}
