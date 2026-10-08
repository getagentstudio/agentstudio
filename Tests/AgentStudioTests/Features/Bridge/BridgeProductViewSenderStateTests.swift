import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product view sender state")
struct BridgeProductViewSenderStateTests {
    @Test("resnapshot skips reserved unissued delivery sequences and emits the replacement part")
    func resnapshotAfterBeginReleasesReservedSequenceGap() throws {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 4, creditParts: 1, creditBytes: 100_000)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        sender.open(view, handle: "handle-1", scanGeneration: 1)
        let scope: BridgeProductJSONValue = .object([
            "kind": .string("file"),
            "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([]),
            "pathScope": .array([]),
        ])
        func batch(firstDeliverySequence: Int, partCount: Int) throws -> BridgeProductSealedViewBatch {
            try BridgeProductSealedViewBatch(
                viewDomain: view,
                producerScanGeneration: 1,
                handle: "handle-1",
                subscriptionKind: .fileMetadata,
                scopeRevision: 1,
                baseRevision: 0,
                targetRevision: 1,
                mode: .snapshot,
                scope: scope,
                coveredScope: scope,
                requiresCollection: nil,
                firstDeliverySequence: firstDeliverySequence,
                parts: (0..<partCount).map { ordinal in
                    .put(
                        key: "row-\(ordinal)",
                        revision: 1,
                        value: .object(["id": .string("row-\(ordinal)")])
                    )
                }
            )
        }
        let stream = BridgeProductMetadataStreamCorrelation(
            metadataStreamId: "stream-1",
            paneSessionId: "pane-1",
            wireVersion: BridgeProductWireContract.version,
            workerInstanceId: "worker-1"
        )
        try sender.seal(batch(firstDeliverySequence: 1, partCount: 3))
        let firstBegin = try sender.nextFrame(stream: stream, streamSequence: 1)
        #expect(firstBegin?.kind == "subscription.batchBegin")
        sender.resnapshot(view, cause: .requested)
        try sender.seal(batch(firstDeliverySequence: 4, partCount: 1))
        let replacementBegin = try sender.nextFrame(stream: stream, streamSequence: 2)
        #expect(replacementBegin?.kind == "subscription.batchBegin")
        guard
            case .batch(.part(let replacementPart)) = try sender.nextFrame(
                stream: stream, streamSequence: 3
            )
        else {
            Issue.record("Expected the replacement part after the reserved sequence gap")
            return
        }
        #expect(replacementPart.deliverySequence == 4)
        #expect(sender.outstandingPartCount(for: view) == 1)
        let lateReceiptReturnedCredit = sender.acknowledge(for: view, handle: "handle-1", through: 3)
        #expect(!lateReceiptReturnedCredit)
        #expect(sender.outstandingPartCount(for: view) == 1)
        let replacementReceiptReturnedCredit = sender.acknowledge(for: view, handle: "handle-1", through: 4)
        #expect(replacementReceiptReturnedCredit)
    }

    @Test("a credit-starved domain yields to its sibling and resumes on receipt")
    func domainsShareCreditsWithoutStarvation() throws {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 2, creditParts: 1, creditBytes: 100_000)
        let first = BridgeProductViewDomainKey(
            viewId: "file-view",
            domain: .singleDomain,
            incarnation: "first"
        )
        let second = BridgeProductViewDomainKey(
            viewId: "file-view",
            domain: .init(rawValue: "member-b"),
            incarnation: "first"
        )
        sender.open(first, handle: "handle-1", scanGeneration: 1)
        sender.open(second, handle: "handle-1", scanGeneration: 1)
        let scope: BridgeProductJSONValue = .object([
            "kind": .string("file"),
            "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([]),
            "pathScope": .array([]),
        ])
        for (key, recordKey) in [(first, "a"), (second, "b")] {
            let batch = try BridgeProductSealedViewBatch(
                viewDomain: key,
                producerScanGeneration: 1,
                handle: "handle-1",
                subscriptionKind: .fileMetadata,
                scopeRevision: 1,
                baseRevision: 0,
                targetRevision: 1,
                mode: .snapshot,
                scope: scope,
                coveredScope: scope,
                requiresCollection: nil,
                firstDeliverySequence: 1,
                parts: [.put(key: recordKey, revision: 1, value: .object(["id": .string(recordKey)]))]
            )
            try sender.seal(batch)
        }
        let stream = BridgeProductMetadataStreamCorrelation(
            metadataStreamId: "stream-1",
            paneSessionId: "pane-1",
            wireVersion: BridgeProductWireContract.version,
            workerInstanceId: "worker-1"
        )
        let firstBegin = try sender.nextFrame(stream: stream, streamSequence: 1)
        let secondBegin = try sender.nextFrame(stream: stream, streamSequence: 2)
        let firstPart = try sender.nextFrame(stream: stream, streamSequence: 3)
        let firstComplete = try sender.nextFrame(stream: stream, streamSequence: 4)
        let blocked = try sender.nextFrame(stream: stream, streamSequence: 5)

        #expect(firstBegin?.kind == "subscription.batchBegin")
        #expect(secondBegin?.kind == "subscription.batchBegin")
        #expect(firstPart?.kind == "subscription.batchPart")
        #expect(firstComplete?.kind == "subscription.batchComplete")
        #expect(blocked == nil)
        #expect(sender.outstandingPartCount(for: first) == 1)
        #expect(sender.outstandingPartCount(for: second) == 0)

        let received = sender.acknowledge(for: first, handle: "handle-1", through: 1)
        let secondPart = try sender.nextFrame(stream: stream, streamSequence: 5)
        #expect(received)
        #expect(secondPart?.kind == "subscription.batchPart")
        #expect(sender.outstandingPartCount(for: second) == 1)
    }

    @Test("a batch larger than the credit window advances only through cumulative part receipts")
    func multiPartBatchUsesPartCreditsWithoutFrameObservation() throws {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 4, creditParts: 1, creditBytes: 100_000)
        let view = BridgeProductViewDomainKey(
            viewId: "file-view",
            domain: .singleDomain,
            incarnation: "first"
        )
        sender.open(view, handle: "handle-1", scanGeneration: 1)
        let scope: BridgeProductJSONValue = .object([
            "kind": .string("file"),
            "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([]),
            "pathScope": .array([]),
        ])
        try sender.seal(
            BridgeProductSealedViewBatch(
                viewDomain: view,
                producerScanGeneration: 1,
                handle: "handle-1",
                subscriptionKind: .fileMetadata,
                scopeRevision: 1,
                baseRevision: 0,
                targetRevision: 1,
                mode: .snapshot,
                scope: scope,
                coveredScope: scope,
                requiresCollection: nil,
                firstDeliverySequence: 1,
                parts: (1...3).map { ordinal in
                    .put(
                        key: "row-\(ordinal)",
                        revision: 1,
                        value: .object(["id": .string("row-\(ordinal)")])
                    )
                }
            )
        )
        let stream = BridgeProductMetadataStreamCorrelation(
            metadataStreamId: "stream-1",
            paneSessionId: "pane-1",
            wireVersion: BridgeProductWireContract.version,
            workerInstanceId: "worker-1"
        )

        let begin = try sender.nextFrame(stream: stream, streamSequence: 1)
        let firstPart = try sender.nextFrame(stream: stream, streamSequence: 2)
        let firstStall = try sender.nextFrame(stream: stream, streamSequence: 3)
        let firstAcknowledged = sender.acknowledge(for: view, handle: "handle-1", through: 1)
        let secondPart = try sender.nextFrame(stream: stream, streamSequence: 3)
        let secondStall = try sender.nextFrame(stream: stream, streamSequence: 4)
        let secondAcknowledged = sender.acknowledge(for: view, handle: "handle-1", through: 2)
        let thirdPart = try sender.nextFrame(stream: stream, streamSequence: 4)
        let complete = try sender.nextFrame(stream: stream, streamSequence: 5)
        let thirdAcknowledged = sender.acknowledge(for: view, handle: "handle-1", through: 3)

        #expect(begin?.kind == "subscription.batchBegin")
        #expect(firstPart?.kind == "subscription.batchPart")
        #expect(firstStall == nil)
        #expect(firstAcknowledged)
        #expect(secondPart?.kind == "subscription.batchPart")
        #expect(secondStall == nil)
        #expect(secondAcknowledged)
        #expect(thirdPart?.kind == "subscription.batchPart")
        #expect(complete?.kind == "subscription.batchComplete")
        #expect(thirdAcknowledged)
        #expect(sender.outstandingPartCount(for: view) == 0)
    }

    @Test("a stale scan cannot seal and an ack failure resnapshots only its domain")
    func staleProducerAndScopedResnapshot() throws {
        var sender = BridgeProductViewSenderState(maximumDirtyKeys: 1, creditParts: 1, creditBytes: 100_000)
        let first = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        let sibling = BridgeProductViewDomainKey(
            viewId: "file-view",
            domain: .init(rawValue: "member-b"),
            incarnation: "first"
        )
        sender.open(first, handle: "handle-1", scanGeneration: 2)
        sender.open(sibling, handle: "handle-1", scanGeneration: 1)
        _ = sender.takePending(for: first)
        _ = sender.takePending(for: sibling)
        let staleInput = sender.recordChange(for: first, scanGeneration: 1, recordKey: "old", revision: 1)
        let siblingInput = sender.recordChange(for: sibling, scanGeneration: 1, recordKey: "new", revision: 2)
        sender.resnapshot(first, cause: .requested)
        #expect(!staleInput && siblingInput)
        #expect(sender.pending(for: first) == .snapshotRequired(.requested))
        #expect(sender.pending(for: sibling) == .keys(["new": 2]))
    }
}
