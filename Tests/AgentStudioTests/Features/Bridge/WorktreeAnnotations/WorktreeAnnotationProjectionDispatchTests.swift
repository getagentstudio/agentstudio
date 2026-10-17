import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Native Comment query admission ordering")
struct WorktreeAnnotationProjectionDispatchTests {
    @Test("older admitted A arriving after B settles superseded through N2 and preserves B's complete paging")
    func nativeAdmissionOrderWinsBeforeSourceEntry() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 136, additionalSession: true)
        let recorder = ProjectionDispatchTraceRecorder()
        let provider = await makeProjectionDispatchProvider(source: harness.source, recorder: recorder)
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: "pane-session-1", provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            operationDeadlineClock: TestPushClock())
        let client = try await ProjectionDispatchClient.open(in: owner, provider: provider)
        let queryA = try projectionQuery(
            sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration, surface: .file)
        let admissionA = try await client.query(queryA, sequence: 2)
        #expect(try await recorder.heldStart.firstArrival().operationCorrelationID == queryA.operationCorrelationID)
        let queryB = try projectionQuery(
            sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration,
            surface: .file, operationCorrelationID: String(repeating: "b", count: 64),
            additionalSessionID: harness.additionalDetail?.session.id)
        let descriptorB = try await client.descriptor(for: client.query(queryB, sequence: 3))
        #expect(descriptorB.page.expectedMessageCount == 137)
        #expect(descriptorB.page.expectedPageCount > 1)
        var page = try await harness.source.claim(client.contentRequest(descriptorB))
        let firstRecords = try collectProjectionRecords(cursor: &page.cursor)
        recorder.heldStart.release()
        let resultA = try await client.result(for: admissionA)
        #expect(resultA.outcome == .refused)
        #expect(resultA.failureCode == .superseded)
        await client.installation.session.waitForOperationExecution(operationId: admissionA.operationId)
        let records = try await collectDispatchedProjection(
            descriptorB, client: client, harness: harness,
            firstRecords: firstRecords, nextSequence: 4)
        #expect(projectionDispatchMessageCount(records) == 137)
        #expect(await recorder.terminal(for: queryA.operationCorrelationID)?.result == .cancelled)
        _ = await owner.retire(reason: .paneDisposal)
        await provider.closeAndDrain()
    }

    @Test("ended A released before source entry cannot supersede B's live installation capture")
    func endedInstallationCannotChangeLiveRevision() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 136, additionalSession: true)
        let recorder = ProjectionDispatchTraceRecorder()
        let provider = await makeProjectionDispatchProvider(source: harness.source, recorder: recorder)
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: "pane-session-1", provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            operationDeadlineClock: TestPushClock())
        let clientA = try await ProjectionDispatchClient.open(in: owner, provider: provider)
        let queryA = try projectionQuery(
            sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration, surface: .file)
        let admissionA = try await clientA.query(queryA, sequence: 2)
        _ = try await recorder.heldStart.firstArrival()
        _ = owner.closeActiveInstallation()
        #expect(clientA.productAdmission.withValidAdmission { true } == nil)
        let clientB = try await ProjectionDispatchClient.open(in: owner, provider: provider)
        #expect(clientB.productAdmission.withValidAdmission { true } == true)
        let heldCapture = HeldStep<[WorktreeAnnotationSessionID]>("B's live E1 capture before ended A resumes")
        await harness.repositoryAccess.holdNextCapture(heldCapture)
        let queryB = try projectionQuery(
            sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration,
            surface: .file, operationCorrelationID: String(repeating: "b", count: 64),
            additionalSessionID: harness.additionalDetail?.session.id)
        let admissionB = try await clientB.query(queryB, sequence: 2)
        #expect(try await heldCapture.firstArrival().count == 2)
        recorder.heldStart.release()
        await clientA.installation.session.waitForOperationExecution(operationId: admissionA.operationId)
        #expect(await recorder.terminal(for: queryA.operationCorrelationID)?.result == .cancelled)
        heldCapture.release()
        let descriptorB = try await clientB.descriptor(for: admissionB)
        #expect(descriptorB.page.expectedMessageCount == 137)
        var page = try await harness.source.claim(clientB.contentRequest(descriptorB))
        let firstRecords = try collectProjectionRecords(cursor: &page.cursor)
        let records = try await collectDispatchedProjection(
            descriptorB, client: clientB, harness: harness,
            firstRecords: firstRecords, nextSequence: 3)
        #expect(projectionDispatchMessageCount(records) == 137)
        _ = await owner.retire(reason: .paneDisposal)
        await provider.closeAndDrain()
    }

    @Test("new E1 with lower request sequence replaces an ended E1 reservation")
    func installationReplacementMayRestartSequence() async throws {
        let harness = try await makeProjectionSourceHarness(messageCount: 136, additionalSession: true)
        let recorder = ProjectionDispatchTraceRecorder()
        recorder.heldStart.release()
        let provider = await makeProjectionDispatchProvider(source: harness.source, recorder: recorder)
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: "pane-session-1", provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            operationDeadlineClock: TestPushClock())
        let clientA = try await ProjectionDispatchClient.open(in: owner, provider: provider)
        let queryA = try projectionQuery(
            sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration, surface: .file)
        _ = try await clientA.descriptor(for: clientA.query(queryA, sequence: 2))
        let oldDescriptor = try await clientA.descriptor(for: clientA.query(queryA, sequence: 3))
        _ = owner.closeActiveInstallation()
        let clientB = try await ProjectionDispatchClient.open(in: owner, provider: provider)
        let queryB = try projectionQuery(
            sessionID: harness.detail.session.id, sourceGeneration: harness.sourceGeneration,
            surface: .file, operationCorrelationID: String(repeating: "b", count: 64),
            additionalSessionID: harness.additionalDetail?.session.id)
        let descriptor = try await clientB.descriptor(for: clientB.query(queryB, sequence: 2))
        #expect(descriptor.page.snapshotID != oldDescriptor.page.snapshotID)
        #expect(descriptor.page.expectedMessageCount == 137)
        var page = try await harness.source.claim(clientB.contentRequest(descriptor))
        let firstRecords = try collectProjectionRecords(cursor: &page.cursor)
        let records = try await collectDispatchedProjection(
            descriptor, client: clientB, harness: harness,
            firstRecords: firstRecords, nextSequence: 3)
        #expect(projectionDispatchMessageCount(records) == 137)
        _ = await owner.retire(reason: .paneDisposal)
        await provider.closeAndDrain()
    }
}

private func projectionDispatchMessageCount(_ records: [BridgeProductAnnotationProjectionRecord]) -> Int {
    records.filter {
        if case .message = $0 { return true }
        return false
    }.count
}
