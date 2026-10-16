import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Native Comment projection overlapping capture")
struct WorktreeAnnotationProjectionOverlapTests {
    @Test(
        "late A capture cannot overwrite B's page or multi-page continuation",
        arguments: [false, true], [false, true])
    func lateCapturePreservesCurrentQuery(claimCurrentPageBeforeOldCompletion: Bool, cancelOlderCaller: Bool)
        async throws
    {
        let harness = try await makeProjectionSourceHarness(messageCount: 136, additionalSession: true)
        let additionalSessionID = try #require(harness.additionalDetail?.session.id)
        let heldCapture = HeldStep<[WorktreeAnnotationSessionID]>(
            "superseded query A service capture",
            cancellation: .holdThroughCancellation)
        await harness.repositoryAccess.holdNextCapture(heldCapture)
        let issuing = try projectionControlRequest(surface: .file)
        let provider = await makeProjectionQueryProvider(source: harness.source)
        let olderQuery = try projectionQuery(
            sessionID: harness.detail.session.id,
            sourceGeneration: harness.sourceGeneration, surface: .file)
        let older = Task {
            try await provider.annotationProjectionQueryResponse(
                queryRequest: olderQuery,
                request: issuing,
                productAdmission: harness.productAdmission)
        }
        #expect(try await heldCapture.firstArrival() == [harness.detail.session.id])
        let currentCorrelation = String(repeating: "b", count: 64)
        var descriptor = try await harness.source.descriptor(
            for: projectionQuery(
                sessionID: harness.detail.session.id,
                sourceGeneration: harness.sourceGeneration, surface: .file, operationCorrelationID: currentCorrelation,
                additionalSessionID: additionalSessionID), issuing: issuing, productAdmission: harness.productAdmission)
        #expect(descriptor.page.expectedSessionCount == 2)
        #expect(descriptor.page.expectedMessageCount == 137)
        #expect(descriptor.page.expectedPageCount > 1)
        let currentSnapshotID = descriptor.page.snapshotID
        var records: [BridgeProductAnnotationProjectionRecord] = []
        if claimCurrentPageBeforeOldCompletion {
            var page = try await harness.source.claim(
                projectionContentRequest(
                    descriptor: descriptor,
                    paneSessionID: issuing.paneSessionId, workerInstanceID: issuing.workerInstanceId))
            records += try collectProjectionRecords(cursor: &page.cursor)
        }
        // Local caller cancellation cannot prevent an already-running native service capture from returning.
        if cancelOlderCaller { older.cancel() }
        heldCapture.release()
        let olderResponse = try await older.value
        if case .requestError(let error) = olderResponse {
            #expect(error.code == .superseded)
            #expect(error.retryable)
        } else {
            Issue.record("Superseded A must settle its own caller with a typed superseded response")
        }
        if !claimCurrentPageBeforeOldCompletion {
            var page = try await harness.source.claim(
                projectionContentRequest(
                    descriptor: descriptor,
                    paneSessionID: issuing.paneSessionId, workerInstanceID: issuing.workerInstanceId))
            records += try collectProjectionRecords(cursor: &page.cursor)
        }
        while let cursor = descriptor.page.nextCursor {
            // Continuations are causally ordered by the exact previous page claim, never by time.
            descriptor = try await harness.source.descriptor(
                for: projectionQuery(
                    sessionID: harness.detail.session.id,
                    sourceGeneration: harness.sourceGeneration, surface: .file, cursor: cursor,
                    operationCorrelationID: currentCorrelation, additionalSessionID: additionalSessionID),
                issuing: issuing, productAdmission: harness.productAdmission)
            #expect(descriptor.page.snapshotID == currentSnapshotID)
            #expect(descriptor.page.operationCorrelationID == currentCorrelation)
            var page = try await harness.source.claim(
                projectionContentRequest(
                    descriptor: descriptor,
                    paneSessionID: issuing.paneSessionId, workerInstanceID: issuing.workerInstanceId))
            records += try collectProjectionRecords(cursor: &page.cursor)
        }
        let messages = records.compactMap { record -> BridgeProductAnnotationProjectionMessageRecord? in
            guard case .message(let message) = record else { return nil }
            return message
        }
        #expect(messages.count == 137)
        #expect(
            Set(messages.map { $0.message.sessionId })
                == Set([harness.detail.session.id.rawValue, additionalSessionID.rawValue]))
        await provider.closeAndDrain()
    }

    @Test("close invalidates a suspended native capture instead of allowing it to repopulate reservations")
    func closeInvalidatesSuspendedCapture() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 1)
        let heldCapture = HeldStep<[WorktreeAnnotationSessionID]>("capture suspended across close")
        await harness.repositoryAccess.holdNextCapture(heldCapture)
        let provider = await makeProjectionQueryProvider(source: harness.source)
        let older = Task {
            try await provider.annotationProjectionQueryResponse(
                queryRequest: projectionQuery(
                    sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration, surface: .file),
                request: projectionControlRequest(surface: .file), productAdmission: harness.productAdmission)
        }
        _ = try await heldCapture.firstArrival()
        await harness.source.close()
        heldCapture.release()
        let response = try await older.value
        if case .requestError(let error) = response {
            #expect(error.code == .superseded)
            #expect(error.retryable)
        } else {
            Issue.record("Closed capture must settle as superseded without issuing a descriptor")
        }
        await provider.closeAndDrain()
    }
}
