import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge

@Suite("Bridge development File replacement diagnostics")
struct BridgeDevelopmentHTTPFileReplacementWaitTests {
    @Test("pending replacement follows admitted stage across stale requested snapshots", arguments: [2, 3])
    func replacementDiagnosticFollowsAdmission(finalTarget: Int) async throws {
        let logURL = FileManager.default.temporaryDirectory.appending(
            path: "tq53-r5-\(UUIDv7.generate()).held-steps.log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let fixture = try ReplacementDiagnosticFixture()
        let recorder = try HTTPMetadataFrameRecorder()
        let router = Router()
        // Only control replies are a stand-in. The shared reader, frame codec,
        // target admission, retained installation and harness writer stay real.
        router.post("/__bridge-product/command") { request, _ -> Response in
            let bytes = Data(try await request.body.collect(upTo: 65_536).readableBytesView)
            let responseBytes: Data
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            switch object["kind"] as? String {
            case "subscription.resnapshot":
                let control = try BridgeProductStrictJSON.decode(BridgeProductViewResnapshotRequest.self, from: bytes)
                responseBytes = try JSONEncoder().encode(
                    BridgeProductOperationAdmittedResponse(
                        correlation: control.correlation, operationId: "replacement", waitKind: .ordinary))
            case "operation.result":
                let accepted = try BridgeProductStrictJSON.decode(
                    BridgeProductJSONValue.self, from: JSONEncoder().encode(fixture.accepted))
                responseBytes = try JSONEncoder().encode(
                    BridgeProductOperationResultResponse(
                        operationId: "replacement", outcome: .succeeded, result: accepted))
            case "subscription.acknowledge":
                let control = try BridgeProductStrictJSON.decode(
                    BridgeProductViewAcknowledgementRequest.self, from: bytes)
                #expect(control.receivedThroughDeliverySequence >= 40)
                responseBytes = try JSONEncoder().encode(BridgeProductViewAcknowledgedResponse(correlating: control))
            default:
                throw HTTPAnnotationIntegrationError.invalidDirectControl
            }
            return Response(
                status: .ok, headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: responseBytes)))
        }
        let application = Application(responder: router.buildResponder())
        try await application.test(.router) { client in
            let connection = HTTPProductConnection(
                bootstrap: .init(paneSessionId: "pane-session", workerInstanceId: "worker-instance"),
                capability: "test-capability")
            let reading = Task {
                do {
                    var retained = HTTPFileBatchRetainedState()
                    let certificate = try fixture.frames(target: 2, delivery: 1)
                    guard case .batch(.begin(let begin)) = certificate[0] else {
                        throw HTTPAnnotationIntegrationError.incompleteFileBatch
                    }
                    try retained.beginApplying(begin)
                    for frame in certificate {
                        if case .batch(.part(let part)) = frame { try retained.apply(part.part, begin: begin) }
                    }
                    _ = try retained.finishApplying(begin)
                    return try await nextHTTPFileBatchSnapshot(
                        client: client, connection: connection, recorder: recorder, retainedState: &retained,
                        replacementWaitLog: .init(path: logURL.path))
                } catch {
                    await recorder.fail(error)
                    throw error
                }
            }
            do {
                // A full stale requested replacement, including COMPLETE, cannot
                // establish a stage even though its correlation matches.
                try await fixture.send(target: 1, delivery: 10, to: recorder)
                await recorder.waitUntilNextFrameSuspends()
                try assertReplacementPending(logURL, side: "BEGIN", checkpoint: "recovery requested")

                // Now recovery is pending: another correlated requested snapshot
                // is stale, and its COMPLETE actually arrives before we inspect.
                try await fixture.send(target: 1, delivery: 15, to: recorder)
                await recorder.waitUntilNextFrameSuspends()
                try assertReplacementPending(logURL, side: "BEGIN", checkpoint: "stale requested replacement complete")

                let admitted = try fixture.frames(target: 2, delivery: 20)
                try await recorder.write(.init(data: BridgeProductMetadataFrameCodec.encode(admitted[0])))
                await recorder.waitUntilNextFrameSuspends()
                try assertReplacementPending(logURL, side: "COMPLETE", checkpoint: "admitted BEGIN")

                // A second correlated stale BEGIN clears that stage. Its full
                // remainder must leave BEGIN pending, not an obsolete COMPLETE.
                try await fixture.send(target: 1, delivery: 30, to: recorder)
                await recorder.waitUntilNextFrameSuspends()
                try assertReplacementPending(
                    logURL, side: "BEGIN", checkpoint: "stale replacement displaced active stage")

                let finalFrames = try fixture.frames(target: finalTarget, delivery: 40)
                try await recorder.write(.init(data: BridgeProductMetadataFrameCodec.encode(finalFrames[0])))
                await recorder.waitUntilNextFrameSuspends()
                try assertReplacementPending(logURL, side: "COMPLETE", checkpoint: "final admitted BEGIN")
                for frame in finalFrames.dropFirst() {
                    try await recorder.write(.init(data: BridgeProductMetadataFrameCodec.encode(frame)))
                }
                let installed = try await reading.value
                #expect(installed.targetRevision == finalTarget)
                #expect(installed.certificatePartCount == finalFrames.count - 2)
                #expect(await connection.controlSequence.takeNextRequestSequence() == 2)
                try assertReplacementPending(logURL, side: nil, checkpoint: "installed target=\(finalTarget)")
            } catch {
                await recorder.fail(error)
                _ = await reading.result
                throw error
            }
        }
    }
}

private func assertReplacementPending(_ logURL: URL, side: String?, checkpoint: String) throws {
    let raw = try String(contentsOf: logURL, encoding: .utf8)
    let records = raw.split(separator: "\n").map {
        $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }
    let settledIDs = Set(records.filter { $0[0] == "settled" }.map { $0[1] })
    let pending = records.filter { $0[0] == "expecting" && !settledIDs.contains($0[1]) }
    #expect(pending.count == (side == nil ? 0 : 1))
    if let side { #expect(pending.first?[2].contains("File recovery replacement \(side) ") == true) }
    if side == nil {
        #expect(records.filter { $0[0] == "settled" }.map { $0[2] } == ["matched", "ended", "matched", "matched"])
    }
    print(
        "TQ53-R5 checkpoint=\(checkpoint) expected=\(side ?? "none") actual=\(pending.map { $0[2] }) raw-log-start\n\(raw)TQ53-R5 raw-log-end"
    )
}

private struct ReplacementDiagnosticFixture: Sendable {
    let source: BridgeProductFileSourceIdentity
    let accepted: BridgeProductViewAcceptedResponse

    init() throws {
        source = try .init(
            repoId: UUIDv7.generate().uuidString, rootRevisionToken: nil, sourceCursor: "cursor",
            sourceId: "source", subscriptionGeneration: 1, worktreeId: UUIDv7.generate().uuidString)
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductViewResnapshotRequest.self,
            from: Data(
                """
                {"kind":"subscription.resnapshot","wireVersion":\(BridgeProductWireContract.version),
                "paneSessionId":"pane-session","workerInstanceId":"worker-instance","requestId":"replacement","requestSequence":1,
                "subscriptionId":"diagnostic-file","subscriptionKind":"file.metadata","domain":"default",
                "handle":"file-handle","incarnation":"default","scopeRevision":1}
                """.utf8))
        accepted = .init(correlating: request)
    }

    func frames(target: Int, delivery: Int) throws -> [BridgeProductMetadataFrame] {
        let batch = try BridgeProductFileViewBatchFactory.sealSnapshot(
            .init(
                viewDomain: .init(viewId: "diagnostic-file", domain: .singleDomain, incarnation: "default"),
                handle: "file-handle", scopeRevision: 1,
                scope: .object([
                    "kind": .string("file"), "changeFilter": .object(["kind": .string("none")]),
                    "interests": .array([]), "pathScope": .array([]),
                ]),
                firstDeliverySequence: delivery,
                snapshot: .init(
                    isEnumerationComplete: true, memberStatus: .init(record: .init(source: source), revision: target),
                    records: [], targetRevision: target, tombstoneRevisionByKey: [:], absenceFloorRevisionByRange: [:]))
        )
        let stream = BridgeProductMetadataStreamCorrelation(
            metadataStreamId: "metadata-stream", paneSessionId: "pane-session",
            wireVersion: BridgeProductWireContract.version, workerInstanceId: "worker-instance")
        return try (0..<(batch.parts.count + 2)).map { ordinal in
            try batch.frame(
                atOrdinal: ordinal, stream: stream, streamSequence: delivery + ordinal, snapshotCause: .requested)
        }
    }

    func send(target: Int, delivery: Int, to recorder: HTTPMetadataFrameRecorder) async throws {
        var bytes = Data()
        for frame in try frames(target: target, delivery: delivery) {
            bytes.append(try BridgeProductMetadataFrameCodec.encode(frame))
        }
        try await recorder.write(.init(data: bytes))
    }
}
