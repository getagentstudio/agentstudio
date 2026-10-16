import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeProductSealedViewBatchTests {
    @Test("sealed File parts retain the real metadata frame byte ceiling")
    func sealedFileFrameRejectsOversizedPart() throws {
        let scope: BridgeProductJSONValue = .object([
            "kind": .string("file"), "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([]), "pathScope": .array([]),
        ])
        let stream = BridgeProductMetadataStreamCorrelation(
            metadataStreamId: "file-limits-stream", paneSessionId: "pane-session-1",
            wireVersion: 2, workerInstanceId: "worker-instance-1")
        let small = try fileLimitsBatch(scope: scope, value: .string("bounded"))
        #expect(
            try BridgeProductMetadataFrameCodec.encode(
                small.frame(atOrdinal: 1, stream: stream, streamSequence: 1, snapshotCause: nil)
            ).count
                <= BridgeProductWireContract.maximumMetadataFrameBytes + 4)
        let oversized = try fileLimitsBatch(
            scope: scope,
            value: .string(String(repeating: "x", count: BridgeProductWireContract.maximumMetadataFrameBytes)))
        #expect(throws: BridgeProductFrameCodecError.self) {
            _ = try BridgeProductMetadataFrameCodec.encode(
                oversized.frame(atOrdinal: 1, stream: stream, streamSequence: 1, snapshotCause: nil))
        }
    }
}

private func fileLimitsBatch(
    scope: BridgeProductJSONValue, value: BridgeProductJSONValue
) throws -> BridgeProductSealedViewBatch {
    try .init(
        viewDomain: .init(viewId: "file-limits", domain: .singleDomain, incarnation: "default"),
        producerScanGeneration: 1, handle: "file-handle-1", subscriptionKind: .fileMetadata,
        scopeRevision: 1, baseRevision: 0, targetRevision: 1, mode: .snapshot,
        scope: scope, coveredScope: scope, requiresCollection: nil, firstDeliverySequence: 1,
        parts: [.put(key: "file-key", revision: 1, value: value)])
}
