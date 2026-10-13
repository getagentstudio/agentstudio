import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeDevelopmentLocatedAnnotationHTTPRoutingTests {
    @MainActor
    @Test("a delayed complete coverage batch cannot invalidate a newer File certificate")
    func delayedFileCoveragePreservesNewerCertificate() async throws {
        let gate = BridgeProductAdmissionGate()
        defer { gate.close() }
        let admission = try #require(gate.acquire())
        let refresh = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        defer { refresh.close() }
        let foreground = try #require(refresh.acquireForegroundWork())
        let source = try BridgeProductFileSourceIdentity(
            repoId: UUIDv7.generate().uuidString, rootRevisionToken: nil,
            sourceCursor: "file-cursor", sourceId: "file-source", subscriptionGeneration: 1,
            worktreeId: UUIDv7.generate().uuidString)
        let index = BridgeWorktreeFileManifestIndex(
            generation: 1, rootURL: FileManager.default.temporaryDirectory,
            productAdmission: admission, source: source)
        let beforeSeal = HeldStep<BridgeWorktreeFileKeyedSnapshot>("older File capture before sealing")
        let delayedCapture = Task {
            let captured = await index.captureKeyedSnapshot()
            try await beforeSeal.arrive(captured)
            return try sealLocatedAnnotationFileCapture(captured)
        }
        do {
            let older = try await beforeSeal.firstArrival()
            #expect(!older.isEnumerationComplete)
            #expect(
                await index.markEnumerationComplete(
                    productAdmission: admission, foregroundWorkAdmission: foreground))
            #expect(
                try await index.updateMemberStatus(
                    state: .ready, branchName: "main", ahead: 0, behind: 0,
                    staged: 0, unstaged: 0, untracked: 0, productAdmission: admission))
            let newer = await index.captureKeyedSnapshot()
            #expect(newer.targetRevision > older.targetRevision)
            let certificate = try sealLocatedAnnotationFileCapture(newer)
            var retained = HTTPFileBatchRetainedState()
            _ = try applyLocatedAnnotationFileBatch(certificate, to: &retained)
            beforeSeal.release()
            let lateCoverage = try await delayedCapture.value

            // Both are actual sealed, complete producer records. Only their
            // capture-to-seal ordering changes; no partial frame is installed.
            let observed = try applyLocatedAnnotationFileBatch(lateCoverage, to: &retained)
            #expect(observed.targetRevision == newer.targetRevision)
            #expect(observed.memberStatus.status == .ready)
            #expect(observed.memberStatus.branchName == "main")
            #expect(observed.certificatePartCount == certificate.parts.count)
        } catch {
            beforeSeal.release()
            delayedCapture.cancel()
            _ = await delayedCapture.result
            throw error
        }
    }

    @Test("an applicable File batch still rejects a record ahead of its declared target")
    func applicableFileBatchRejectsInvalidRevision() throws {
        let source = try BridgeProductFileSourceIdentity(
            repoId: UUIDv7.generate().uuidString, rootRevisionToken: nil,
            sourceCursor: "file-cursor", sourceId: "file-source", subscriptionGeneration: 1,
            worktreeId: UUIDv7.generate().uuidString)
        let malformed = BridgeWorktreeFileKeyedSnapshot(
            isEnumerationComplete: false,
            memberStatus: .init(record: .init(source: source), revision: 3),
            records: [], targetRevision: 2, tombstoneRevisionByKey: [:], absenceFloorRevisionByRange: [:])
        let batch = try sealLocatedAnnotationFileCapture(malformed)
        var retained = HTTPFileBatchRetainedState()
        #expect {
            try applyLocatedAnnotationFileBatch(batch, to: &retained)
        } throws: { error in
            if case HTTPAnnotationIntegrationError.invalidFileBatchRecord = error { true } else { false }
        }
    }
}

private func sealLocatedAnnotationFileCapture(
    _ snapshot: BridgeWorktreeFileKeyedSnapshot
) throws -> BridgeProductSealedViewBatch {
    try BridgeProductFileViewBatchFactory.sealSnapshot(
        .init(
            viewDomain: .init(viewId: "file-metadata-located-restore", domain: .singleDomain, incarnation: "default"),
            handle: "located-file-handle", scopeRevision: 1,
            scope: .object([
                "kind": .string("file"), "changeFilter": .object(["kind": .string("none")]),
                "interests": .array([]), "pathScope": .array([]),
            ]),
            firstDeliverySequence: 1, snapshot: snapshot))
}

private func applyLocatedAnnotationFileBatch(
    _ batch: BridgeProductSealedViewBatch, to retained: inout HTTPFileBatchRetainedState
) throws -> HTTPFileBatchSnapshot {
    let stream = BridgeProductMetadataStreamCorrelation(
        metadataStreamId: "metadata-stream", paneSessionId: "pane-session",
        wireVersion: BridgeProductWireContract.version, workerInstanceId: "worker-instance")
    guard
        case .batch(.begin(let begin)) = try batch.frame(
            atOrdinal: 0, stream: stream, streamSequence: batch.mode == .snapshot ? 1 : 100,
            snapshotCause: batch.mode == .snapshot ? .open : nil)
    else { throw HTTPAnnotationIntegrationError.incompleteFileBatch }
    try retained.beginApplying(begin)
    for part in batch.parts { try retained.apply(part, begin: begin) }
    return try retained.finishApplying(begin)
}
