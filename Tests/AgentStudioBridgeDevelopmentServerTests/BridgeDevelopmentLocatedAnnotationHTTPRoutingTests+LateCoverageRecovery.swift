import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer
@testable import AgentStudioCore

extension BridgeDevelopmentLocatedAnnotationHTTPRoutingTests {
    @MainActor
    @Test("HTTP resnapshot replaces late incomplete File coverage without acknowledging its parts")
    func lateIncompleteFileCoverageRecoversThroughHTTP() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "tq53-late-file-coverage")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let paneID = PaneId.generateUUIDv7().uuid
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "tq53-late-file-coverage-\(paneID.uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot, paneID: paneID, worktreeRoot: repositoryURL)
        do {
            try await exerciseLateFileCoverageHTTPRecovery(runtime: runtime)
            try await runtime.composition.shutdown()
        } catch {
            _ = await runtime.host.shutdown()
            try await runtime.composition.shutdown()
            throw error
        }
    }

    @MainActor
    @Test("shared HTTP File helper resnapshots late coverage and continues the control journey")
    func sharedFileHelperRecoversLateCoverage() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "tq53-shared-file-helper")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let paneID = PaneId.generateUUIDv7().uuid
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "tq53-shared-file-helper-\(paneID.uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot, paneID: paneID, worktreeRoot: repositoryURL)
        do {
            try await exerciseLateFileCoverageHTTPRecovery(runtime: runtime, usesSharedHelper: true)
            try await runtime.composition.shutdown()
        } catch {
            _ = await runtime.host.shutdown()
            try await runtime.composition.shutdown()
            throw error
        }
    }

}

@MainActor
private func exerciseLateFileCoverageHTTPRecovery(
    runtime: HTTPDevelopmentProductRuntime, usesSharedHelper: Bool = false
) async throws {
    let coordinator = await runtime.host.productProvider.metadataCoordinator
    let source = try #require(
        await coordinator.fileMetadataSource as? BridgePaneProductFileMetadataSource)
    let priorObserver = await source.sourceAcceptedObserver
    let subscriptionID = "tq53-late-file"
    let beforeEnumeration = HeldStep<BridgeWorktreeFileKeyedSnapshot>("File inventory before enumeration")
    let beforeSeal = HeldStep<BridgeWorktreeFileKeyedSnapshot>("Older File capture before session sealing")
    await source.setSourceAcceptedObserver { identity in
        await priorObserver(identity)
        guard let context = await source.contextBySubscriptionId[subscriptionID],
            context.productSource == identity
        else {
            beforeEnumeration.fail(HTTPAnnotationIntegrationError.incompleteFileBatch)
            return
        }
        let snapshot = await context.manifestIndex.captureKeyedSnapshot()
        _ = try? await beforeEnumeration.arrive(snapshot)
    }
    do {
        try await withBridgeDevelopmentHTTPRouterTestClient(host: runtime.host) { client in
            let connection = try await openHTTPProductConnection(client: client)
            let metadataStream = try await startHTTPMetadataStream(
                host: runtime.host, connection: connection, streamID: "tq53-late-file-stream")
            var delayedCapture: Task<Bool, any Error>?
            do {
                let _: BridgeProductMetadataStreamAcceptedFrame = try await waitForAcknowledgedMetadataFrame(
                    client: client, connection: connection, recorder: metadataStream.recorder
                ) { frame in
                    guard case .metadataStreamAccepted(let accepted) = frame else { return nil }
                    return accepted
                }
                let fileSource = try await queryHTTPFileSource(
                    client: client, connection: connection)
                _ = try await openHTTPSubscription(
                    client: client, connection: connection,
                    subscription: ["source": try jsonObject(fileSource), "subscriptionKind": "file.metadata"],
                    subscriptionID: subscriptionID)
                _ = try await waitForAcknowledgedSubscription(
                    client: client, connection: connection, recorder: metadataStream.recorder,
                    subscriptionID: subscriptionID)
                let olderCapture = try await beforeEnumeration.firstArrival()
                try #require(!olderCapture.isEnumerationComplete)
                try await acceptHTTPFileViewScope(
                    path: usesSharedHelper ? "tracked.txt" : nil, client: client, connection: connection,
                    subscriptionID: subscriptionID)
                let activeStream = try #require(await coordinator.activeStream)
                let scope = try #require(
                    await activeStream.session.acceptedViewScope(subscriptionId: subscriptionID))
                // The immutable capture is real host inventory. Hold its delivery at
                // the existing session boundary; the coordinator itself is not replaced.
                delayedCapture = Task {
                    try await beforeSeal.arrive(olderCapture)
                    return try await activeStream.session.sealFileCapture(
                        subscriptionId: subscriptionID, snapshot: olderCapture,
                        scope: scope, productAdmission: activeStream.productAdmission)
                }
                _ = try await beforeSeal.firstArrival()
                await source.setSourceAcceptedObserver(priorObserver)
                beforeEnumeration.release()
                let certificate = try await readTQ53HTTPFileBatch(
                    client: client, connection: connection, recorder: metadataStream.recorder,
                    subscriptionID: subscriptionID, matchingMode: .snapshot)
                try #require(certificate.begin.targetRevision > olderCapture.targetRevision)

                beforeSeal.release()
                try #require(try await delayedCapture?.value == true)
                if usesSharedHelper {
                    try await verifyTQ53SharedHelperRecovery(
                        client: client, connection: connection, recorder: metadataStream.recorder,
                        activeStream: activeStream, certificate: certificate)
                } else {
                    try await recoverTQ53LateHTTPFileCoverage(
                        client: client, connection: connection, recorder: metadataStream.recorder,
                        olderCapture: olderCapture, certificate: certificate)
                }
                try await shutdownHTTPHostAndDrainMetadataStream(host: runtime.host, drain: metadataStream.drain)
            } catch {
                beforeEnumeration.release()
                beforeSeal.release()
                if let delayedCapture { _ = await delayedCapture.result }
                try await shutdownHTTPHostAndDrainMetadataStream(host: runtime.host, drain: metadataStream.drain)
                throw error
            }
        }
    } catch {
        beforeEnumeration.release()
        beforeSeal.release()
        await source.setSourceAcceptedObserver(priorObserver)
        throw error
    }
}

private func verifyTQ53SharedHelperRecovery(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    activeStream: BridgePaneProductMetadataCoordinator.ActiveStream,
    certificate: TQ53HTTPFileBatch
) async throws {
    let beforeRecovery = HeldStep<(BridgeProductBatchBeginFrame, Int?)>("stale File PART before HTTP resnapshot")
    let reading = Task {
        var retainedState = HTTPFileBatchRetainedState()
        _ = try applyTQ53CompleteFileBatch(certificate, retainedState: &retainedState)
        while true {
            let snapshot = try await nextHTTPFileBatchSnapshot(
                client: client, connection: connection, recorder: recorder, retainedState: &retainedState,
                beforeResnapshot: { begin, delivery in try await beforeRecovery.arrive((begin, delivery)) })
            if !beforeRecovery.recordedArrivals.isEmpty { return (snapshot, retainedState) }
        }
    }
    do {
        let (stale, rejectedDelivery) = try await beforeRecovery.firstArrival()
        let rejectedSequence = try #require(rejectedDelivery)
        let domain = BridgeProductViewDomainKey(
            viewId: stale.identity.subscriptionId, domain: .singleDomain,
            incarnation: stale.identity.incarnation)
        #expect(stale.targetRevision < certificate.begin.targetRevision)
        #expect(await activeStream.session.viewSenderState.outstandingPartCount(for: domain) >= 1)
        let replayByDomain = await activeStream.session.viewAcknowledgementReplayByDomain
        let receipt = try #require(replayByDomain[domain]?.requestBytes)
        let acknowledgement = try BridgeProductStrictJSON.decode(
            BridgeProductViewAcknowledgementRequest.self, from: receipt)
        #expect(acknowledgement.receivedThroughDeliverySequence == rejectedSequence - 1)
        #expect(await activeStream.session.controlReplay.snapshot.nextExpectedRequestSequence == 5)
        beforeRecovery.release()
        let recoveryResult = try await reading.value
        let recovered = recoveryResult.0
        var retainedState = recoveryResult.1
        #expect(recovered.targetRevision >= certificate.begin.targetRevision)
        #expect(recovered.memberStatus.status == .ready)
        #expect(recovered.memberStatus.branchName == "main")
        #expect(recovered.certificatePartCount == certificate.begin.partCount)
        #expect(beforeRecovery.recordedArrivals.count == 1)
        #expect(await activeStream.session.controlReplay.snapshot.nextExpectedRequestSequence == 6)
        // A real subsequent control proves recovery did not steal a caller's sequence.
        _ = try await queryHTTPFileSource(client: client, connection: connection)
        #expect(await activeStream.session.controlReplay.snapshot.nextExpectedRequestSequence == 7)
        try await continueTQ53HTTPAnnotationJourney(
            client: client, connection: connection, recorder: recorder, retainedState: &retainedState,
            initialSnapshot: recovered)
        print(
            "TQ53-R3 helper recovery: stale target=\(stale.targetRevision), no stale receipt, one resnapshot, replacement=\(recovered.targetRevision), following control completed"
        )
    } catch {
        beforeRecovery.release()
        reading.cancel()
        _ = await reading.result
        throw error
    }
}

private func continueTQ53HTTPAnnotationJourney(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    retainedState: inout HTTPFileBatchRetainedState,
    initialSnapshot: HTTPFileBatchSnapshot
) async throws {
    var descriptor = initialSnapshot.descriptorByPath["tracked.txt"]
    while descriptor == nil {
        let snapshot = try await nextHTTPFileBatchSnapshot(
            client: client, connection: connection, recorder: recorder, retainedState: &retainedState)
        descriptor = snapshot.descriptorByPath["tracked.txt"]
    }
    let readyDescriptor = try #require(descriptor)
    let commentOpen = try await openHTTPSubscription(
        client: client, connection: connection,
        subscription: ["subscriptionKind": "file.annotations"], subscriptionID: "tq53-recovered-annotations")
    _ = try await waitForAcknowledgedSubscription(
        client: client, connection: connection, recorder: recorder,
        subscriptionID: "tq53-recovered-annotations")
    try await acceptHTTPCommentViewScope(client: client, connection: connection, openResponse: commentOpen)
    _ = try await waitForHTTPAnnotationCatalogCommit(client: client, connection: connection, recorder: recorder)
    let created = try await executeHTTPAnnotationCommand(
        client: client, connection: connection,
        operation: [
            "admission": ["kind": "implicitOrSingle"], "body": "Annotation after File recovery",
            "editToken": "tq53-recovered-editor", "kind": "root.create",
            "origin": [
                "diffSide": NSNull(), "endLine": 2, "kind": "located", "path": "tracked.txt",
                "sourceIdentity": readyDescriptor.descriptorId, "sourceRole": "file", "startLine": 2,
            ],
        ], requestID: "tq53-annotation-after-recovery")
    #expect(created.status == .committed)
    let receipt = try requireHTTPAnnotationMessage(created)
    #expect(receipt.draft?.body == "Annotation after File recovery")
}

private func recoverTQ53LateHTTPFileCoverage(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    olderCapture: BridgeWorktreeFileKeyedSnapshot,
    certificate: TQ53HTTPFileBatch
) async throws {
    let lateBeginFrame = try await nextTQ53HTTPFileFrame(
        recorder: recorder, subscriptionID: certificate.begin.identity.subscriptionId)
    guard case .batch(.begin(let lateBegin)) = lateBeginFrame else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "late coverage BEGIN", receivedKind: lateBeginFrame.kind)
    }
    #expect(lateBegin.mode == .coverage)
    #expect(lateBegin.targetRevision == olderCapture.targetRevision)
    #expect(lateBegin.targetRevision < certificate.begin.targetRevision)
    #expect(lateBegin.identity.frame.streamSequence > certificate.complete.identity.frame.streamSequence)
    #expect(lateBegin.identity.handle == certificate.begin.identity.handle)
    #expect(lateBegin.identity.incarnation == certificate.begin.identity.incarnation)
    #expect(lateBegin.identity.scopeRevision == certificate.begin.identity.scopeRevision)
    #expect(lateBegin.identity.subscriptionId == certificate.begin.identity.subscriptionId)
    let latePartFrame = try await nextTQ53HTTPFileFrame(
        recorder: recorder, subscriptionID: certificate.begin.identity.subscriptionId)
    guard case .batch(.part(let latePart)) = latePartFrame else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "late coverage PART", receivedKind: latePartFrame.kind)
    }
    #expect(latePart.identity.batchId == lateBegin.identity.batchId)
    // The actual receiver requests recovery on this missing-stage part.
    // Send its control through real HTTP, withholding the rejected receipt.
    let response = try await executeHTTPControl(
        client: client, connection: connection,
        object: [
            "kind": "subscription.resnapshot", "wireVersion": BridgeProductWireContract.version,
            "paneSessionId": connection.bootstrap.paneSessionId,
            "workerInstanceId": connection.bootstrap.workerInstanceId,
            "requestId": "tq53-late-file-resnapshot",
            "subscriptionId": certificate.begin.identity.subscriptionId, "subscriptionKind": "file.metadata",
            "domain": "default", "handle": certificate.begin.identity.handle,
            "incarnation": certificate.begin.identity.incarnation,
            "scopeRevision": certificate.begin.identity.scopeRevision,
        ])
    guard case .viewAccepted(let accepted) = response else {
        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
            callSite: "late File resnapshot", receivedKind: response.kind)
    }
    #expect(accepted.kind == .resnapshot)
    let recovery = try await readTQ53HTTPFileBatch(
        client: client, connection: connection, recorder: recorder,
        subscriptionID: certificate.begin.identity.subscriptionId, matchingMode: .snapshot)
    #expect(recovery.begin.snapshotCause == .requested)
    #expect(recovery.begin.baseRevision == 0)
    #expect(recovery.begin.targetRevision >= certificate.begin.targetRevision)
    #expect(recovery.begin.identity.handle == certificate.begin.identity.handle)
    #expect(recovery.begin.identity.scopeRevision == certificate.begin.identity.scopeRevision)
    #expect(recovery.begin.identity.incarnation == certificate.begin.identity.incarnation)
    #expect(recovery.begin.identity.subscriptionKind == .fileMetadata)
    #expect(recovery.parts.count == recovery.begin.partCount)
    #expect(recovery.parts.first?.deliverySequence ?? 0 > latePart.deliverySequence)
    #expect(!recovery.parts.isEmpty)
    var retainedState = HTTPFileBatchRetainedState()
    let installedCertificate = try applyTQ53CompleteFileBatch(certificate, retainedState: &retainedState)
    let installedRecovery = try applyTQ53CompleteFileBatch(recovery, retainedState: &retainedState)
    #expect(installedRecovery.targetRevision >= installedCertificate.targetRevision)
    #expect(installedRecovery.source == installedCertificate.source)
    #expect(installedRecovery.memberStatus == installedCertificate.memberStatus)
    #expect(installedRecovery.memberStatus.status == .ready)
    #expect(installedRecovery.descriptorByPath == installedCertificate.descriptorByPath)
    #expect(recovery.parts.map(\.part) == certificate.parts.map(\.part))
    let transcript = certificate.frames + [lateBeginFrame, latePartFrame] + recovery.frames
    let encoded = try JSONEncoder().encode(transcript)
    print("TQ53-R2 HTTP frame transcript \(try #require(String(bytes: encoded, encoding: .utf8)))")
}

private func applyTQ53CompleteFileBatch(
    _ batch: TQ53HTTPFileBatch, retainedState: inout HTTPFileBatchRetainedState
) throws -> HTTPFileBatchSnapshot {
    try retainedState.beginApplying(batch.begin)
    for part in batch.parts { try retainedState.apply(part.part, begin: batch.begin) }
    return try retainedState.finishApplying(batch.begin)
}

private struct TQ53HTTPFileBatch {
    let begin: BridgeProductBatchBeginFrame
    let parts: [BridgeProductBatchPartFrame]
    let complete: BridgeProductBatchCompleteFrame
    let frames: [BridgeProductMetadataFrame]
}

// Consume actual declared protocol batches, acknowledging their parts. A stale
// remainder whose BEGIN was already consumed has no local stage and gets no credit.
private func readTQ53HTTPFileBatch(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    subscriptionID: String,
    matchingMode: BridgeProductBatchMode
) async throws -> TQ53HTTPFileBatch {
    var frames: [BridgeProductMetadataFrame] = []
    var begin: BridgeProductBatchBeginFrame?
    var parts: [BridgeProductBatchPartFrame] = []
    while true {
        let frame = try await recorder.nextFrame()
        frames.append(frame)
        switch frame {
        case .batch(.begin(let received)) where received.identity.subscriptionId == subscriptionID:
            begin = received
            parts = []
        case .batch(.part(let part)):
            guard let begin, part.identity.batchId == begin.identity.batchId else { continue }
            #expect(part.partIndex == parts.count)
            parts.append(part)
            // Initial coverage must finish to let its queued certificate emit.
            try await acknowledgeHTTPViewPart(client: client, connection: connection, part: part)
        case .batch(.complete(let complete)):
            guard let begin, complete.identity.batchId == begin.identity.batchId else { continue }
            #expect(parts.count == begin.partCount)
            #expect(complete.coveredScope == begin.scope)
            #expect(complete.identity.frame.streamSequence > begin.identity.frame.streamSequence)
            if begin.mode == matchingMode {
                return .init(begin: begin, parts: parts, complete: complete, frames: frames)
            }
        default: continue
        }
    }
}

private func nextTQ53HTTPFileFrame(
    recorder: HTTPMetadataFrameRecorder, subscriptionID: String
) async throws -> BridgeProductMetadataFrame {
    while true {
        let frame = try await recorder.nextFrame()
        if case .batch(let batch) = frame, batch.identity.subscriptionId == subscriptionID {
            return frame
        }
        if case .metadataStreamError = frame {
            throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
                callSite: "await late File batch", receivedKind: frame.kind)
        }
    }
}
