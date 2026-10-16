import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product snapshot cause")
struct BridgeProductSnapshotCauseTests {
    @Test(
        "snapshot emissions consume exactly their owed cause",
        arguments: [
            BridgeProductSnapshotCause.open, .requested, .recovery, .newerInput,
        ])
    func sealedEmissionConsumesCause(cause: BridgeProductSnapshotCause) throws {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 2, creditParts: 4, creditBytes: 100_000)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        sender.open(view, handle: "handle-1", scanGeneration: 1)
        if cause != .open {
            try sender.seal(makeBatch(view: view))
            _ = try sender.nextFrame(stream: stream, streamSequence: 1)
            _ = try sender.nextFrame(stream: stream, streamSequence: 2)
            sender.resnapshot(view, cause: cause)
        }
        try sender.seal(makeBatch(view: view))
        let frame = try sender.nextFrame(stream: stream, streamSequence: 3)
        guard case .batch(.begin(let begin)) = frame else {
            Issue.record("Expected a snapshot begin")
            return
        }
        #expect(begin.snapshotCause == cause)
        #expect(sender.pending(for: view) == .keys([:]))
        _ = try sender.nextFrame(stream: stream, streamSequence: 4)
        try sender.seal(makeBatch(view: view))
        let following = try sender.nextFrame(stream: stream, streamSequence: 5)
        guard case .batch(.begin(let nextBegin)) = following else {
            Issue.record("Expected the following newer-input begin")
            return
        }
        #expect(nextBegin.snapshotCause == .newerInput)
    }

    @Test("coverage preserves the open obligation and omits the cause")
    func coverageDoesNotConsumeCause() throws {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 2, creditParts: 4, creditBytes: 100_000)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        sender.open(view, handle: "handle-1", scanGeneration: 1)
        try sender.seal(makeBatch(view: view, mode: .coverage))
        let frame = try sender.nextFrame(stream: stream, streamSequence: 1)
        guard case .batch(.begin(let begin)) = frame else {
            Issue.record("Expected coverage begin")
            return
        }
        #expect(begin.snapshotCause == nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(begin)) as? [String: Any]
        #expect(encoded?["snapshotCause"] == nil)
        #expect(sender.pending(for: view) == .snapshotRequired(.open))
        _ = try sender.nextFrame(stream: stream, streamSequence: 2)
        try sender.seal(makeBatch(view: view))
        let snapshot = try sender.nextFrame(stream: stream, streamSequence: 3)
        guard case .batch(.begin(let certified)) = snapshot else {
            Issue.record("Expected certifying snapshot")
            return
        }
        #expect(certified.snapshotCause == .open)
    }

    @Test("pending restoration and input restart preserve stronger obligations")
    func strongestCauseSurvivesRestoration() {
        var pending = BridgeProductViewDirtyKeyAccumulator(maximumDirtyKeysPerViewDomain: 1)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        pending.open(view, scanGeneration: 1)
        pending.requireSnapshot(for: view, cause: .requested)
        pending.requireSnapshot(for: view, cause: .recovery)
        #expect(pending.pending(for: view) == .snapshotRequired(.open))
        _ = pending.takePending(for: view)
        pending.requireSnapshot(for: view, cause: .recovery)
        pending.restore(.snapshotRequired(.requested), for: view)
        let advancedRequestedGeneration = pending.advanceScanGeneration(for: view, to: 2)
        #expect(advancedRequestedGeneration)
        #expect(pending.pending(for: view) == .snapshotRequired(.requested))
        pending.restore(.snapshotRequired(.open), for: view)
        #expect(pending.pending(for: view) == .snapshotRequired(.open))
    }

    @Test("dirty overflow and a producer generation restart owe newer input")
    func changedInputClassification() {
        var pending = BridgeProductViewDirtyKeyAccumulator(maximumDirtyKeysPerViewDomain: 1)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        pending.open(view, scanGeneration: 1)
        _ = pending.takePending(for: view)
        let recordedFirstChange = pending.recordChange(for: view, scanGeneration: 1, recordKey: "one", revision: 1)
        #expect(recordedFirstChange)
        let recordedOverflowingChange = pending.recordChange(
            for: view, scanGeneration: 1, recordKey: "two", revision: 1)
        #expect(recordedOverflowingChange)
        #expect(pending.pending(for: view) == .snapshotRequired(.newerInput))
        _ = pending.takePending(for: view)
        let advancedFreshGeneration = pending.advanceScanGeneration(for: view, to: 2)
        #expect(advancedFreshGeneration)
        #expect(pending.pending(for: view) == .snapshotRequired(.newerInput))
    }

    @Test("a same-filter generation relabel creates no open obligation")
    func sameFilterRelabelPreservesPending() {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 2, creditParts: 4, creditBytes: 100_000)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        sender.open(view, handle: "handle-1", scanGeneration: 1)
        _ = sender.takePending(for: view)
        let relabeledDemandGeneration = sender.relabelScanGenerationPreservingEmission(for: view, to: 2)
        #expect(relabeledDemandGeneration)
        #expect(sender.pending(for: view) == .keys([:]))
    }

    @Test("the first sealed snapshot carries the open obligation")
    func firstSnapshotCarriesOpen() throws {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 2, creditParts: 4, creditBytes: 100_000)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        sender.open(view, handle: "handle-1", scanGeneration: 1)
        try sender.seal(makeBatch(view: view))
        let nextFrame = try sender.nextFrame(stream: stream, streamSequence: 1)
        let frame = try #require(nextFrame)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
        #expect(object["snapshotCause"] as? String == "open")
    }

    private var stream: BridgeProductMetadataStreamCorrelation {
        .init(metadataStreamId: "stream-1", paneSessionId: "pane-1", wireVersion: 2, workerInstanceId: "worker-1")
    }

    private func makeBatch(
        view: BridgeProductViewDomainKey, mode: BridgeProductBatchMode = .snapshot
    ) throws -> BridgeProductSealedViewBatch {
        let scope: BridgeProductJSONValue = .object([
            "kind": .string("file"),
            "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([]),
            "pathScope": .array([]),
        ])
        return try .init(
            viewDomain: view, producerScanGeneration: 1, handle: "handle-1", subscriptionKind: .fileMetadata,
            scopeRevision: 1, baseRevision: 0, targetRevision: 1, mode: mode,
            scope: scope, coveredScope: scope, requiresCollection: nil, firstDeliverySequence: 1, parts: []
        )
    }
}
