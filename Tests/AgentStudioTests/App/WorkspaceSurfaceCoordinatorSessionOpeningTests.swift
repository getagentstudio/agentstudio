import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

private enum WorkspaceSessionOpeningFact: Equatable, Sendable {
    case resultWaitRegistered
    case openingHelperReturned
    case deadlineFinished
}

extension WebKitSerializedTests.WorkspaceSurfaceCoordinatorViewFactoryTests {
    @Test("session opening helper waits for the committed result before metadata startup")
    func openingHelperWaitsForCommittedSessionBeforeMetadata() async throws {
        let facts = LocalFactSource<String, WorkspaceSessionOpeningFact>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { String(describing: $0) }, isClosing: { _, _ in false }))
        let recorder = try facts.attach()
        let sink = facts.sink
        let responseHeld = HeldStep<Void>(
            "workerSession.open provider response before commitment", cancellation: .holdThroughCancellation)
        defer { responseHeld.release() }
        let provider = BridgePaneProductSessionProviderGate(workerOpenResponse: responseHeld)
        let productGate = BridgeProductAdmissionGate()
        let installationGate = BridgeProductAdmissionGate()
        let paneSessionId = UUIDv7.generate().uuidString
        let workerInstanceId = UUIDv7.generate().uuidString
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let session = try BridgeProductSession(
            paneSessionId: paneSessionId, workerInstanceId: workerInstanceId, capabilityBytes: capabilityBytes,
            resultWaiterRegistrationObserver: { _ in sink("opening", .resultWaitRegistered) })
        let adapter = BridgeProductSchemeAdapter(
            session: session, provider: provider, productAdmissionGate: productGate,
            installationAdmissionGate: installationGate)
        let installation = BridgeProductSessionInstallation(
            bootstrap: .init(paneSessionId: paneSessionId, workerInstanceId: workerInstanceId),
            capabilityBytes: capabilityBytes, productAdmissionGate: productGate,
            installationAdmissionGate: installationGate, productAdapter: adapter, session: session)
        let opening = Task {
            try await openBridgePaneProductSession(installation)
            sink("opening", .openingHelperReturned)
        }
        _ = try await responseHeld.firstArrival()
        let first = try await recorder.expectNext(
            in: "opening", where: { _ in true }, "result wait before helper return")
        #expect(
            first == .resultWaitRegistered, "An admission reply cannot establish the active session needed by metadata")
        let deadlineTasks = await session.operationTable.entriesById.values.compactMap(\.deadlineTask)
        #expect(deadlineTasks.count == 1)
        #expect(await session.operationTable.executionTasksById.count == 1)
        #expect(deadlineTasks.allSatisfy { !$0.isCancelled })
        if first == .openingHelperReturned {
            let reply = try await collectBridgeProductSchemeReply(
                adapter: adapter,
                request: bridgeProductSchemeRequest(
                    route: BridgeProductWireContract.streamRoute,
                    capability: BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes),
                    body: JSONSerialization.data(withJSONObject: [
                        "kind": "metadataStream.open", "metadataStreamId": "metadata-opening-discriminator",
                        "paneSessionId": paneSessionId, "workerInstanceId": workerInstanceId,
                        "resumeFromStreamSequence": NSNull(), "wireVersion": BridgeProductWireContract.version,
                    ])))
            #expect(reply.response?.statusCode == 409)
            #expect(await session.producerSnapshot().activeProducerTaskCount == 0)
        }
        responseHeld.release()
        try await opening.value
        if first == .resultWaitRegistered { try await recorder.expectNext(in: "opening", .openingHelperReturned) }
        await session.waitForOutstandingOperationExecutions()
        #expect(await session.lifecycle == .active)
        for deadline in deadlineTasks { await deadline.value }
        let deadlinesWereCancelled = deadlineTasks.allSatisfy(\.isCancelled)
        #expect(deadlinesWereCancelled)
        sink("opening", .deadlineFinished)
        try await recorder.expectNext(in: "opening", .deadlineFinished)
        let revoked = await session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revoked.wait())
        facts.end()
        try await recorder.finish()
        #expect(await session.producerSnapshot().hasZeroResidue)
    }
}
