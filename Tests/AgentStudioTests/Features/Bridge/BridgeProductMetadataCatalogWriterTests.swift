import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product metadata catalog writer")
struct BridgeProductMetadataCatalogWriterTests {
    @Test("empty catalog emits observed begin then commit")
    func emptyCatalogEmitsBeginThenCommit() async throws {
        // Arrange
        let recorder = CatalogWriterRecorder<CatalogWriterFixtureEntry>()
        let writer = BridgeProductMetadataCatalogWriter<CatalogWriterFixtureEntry>()

        // Act
        let result = try await writer.write(
            entries: [],
            catalogRevision: 4,
            transferID: UUIDv7.generate().uuidString.lowercased(),
            makeProspectiveMetadataFrame: CatalogWriterFixtureFrame.init(phase:),
            enqueue: { phase in await recorder.enqueue(phase) },
            waitUntilObserved: { sequence in await recorder.waitUntilObserved(sequence) }
        )

        // Assert
        #expect(result.entryCount == 0)
        #expect(result.windowCount == 0)
        #expect(result.frameCount == 2)
        let snapshot = await recorder.snapshot()
        #expect(snapshot.phases.count == 2)
        #expect(snapshot.phases[0].expectedEntryCount == 0)
        #expect(snapshot.phases[1].windowCount == 0)
        #expect(snapshot.observedSequences == [1, 2])
    }

    @Test("complete entries pack into bounded full metadata frames")
    func completeEntriesPackIntoBoundedFrames() async throws {
        // Arrange
        let entries = (0..<5).map {
            CatalogWriterFixtureEntry(identifier: "entry-\($0)", payload: String(repeating: "x", count: 40_000))
        }
        let recorder = CatalogWriterRecorder<CatalogWriterFixtureEntry>()
        let writer = BridgeProductMetadataCatalogWriter<CatalogWriterFixtureEntry>()

        // Act
        let result = try await writer.write(
            entries: entries,
            catalogRevision: 9,
            transferID: UUIDv7.generate().uuidString.lowercased(),
            makeProspectiveMetadataFrame: CatalogWriterFixtureFrame.init(phase:),
            enqueue: { phase in await recorder.enqueue(phase) },
            waitUntilObserved: { sequence in await recorder.waitUntilObserved(sequence) }
        )

        // Assert
        let snapshot = await recorder.snapshot()
        let windows = snapshot.phases.compactMap(\.entries)
        #expect(result.windowCount == windows.count)
        #expect(windows.flatMap { $0 } == entries)
        #expect(windows.allSatisfy { !$0.isEmpty })
        for phase in snapshot.phases {
            let body = try BridgeProductMetadataFrameCodec.encodeJSONBody(
                CatalogWriterFixtureFrame(phase: phase)
            )
            #expect(body.count <= BridgeProductWireContract.maximumMetadataFrameBytes)
        }
        #expect(snapshot.observedSequences == Array(1...result.frameCount))
    }

    @Test("indivisible oversized entry emits no begin")
    func indivisibleOversizedEntryEmitsNoBegin() async throws {
        // Arrange
        let recorder = CatalogWriterRecorder<CatalogWriterFixtureEntry>()
        let writer = BridgeProductMetadataCatalogWriter<CatalogWriterFixtureEntry>()
        let entry = CatalogWriterFixtureEntry(
            identifier: "oversized",
            payload: String(
                repeating: "x",
                count: BridgeProductWireContract.maximumMetadataFrameBytes
            )
        )

        // Act / Assert
        await #expect(throws: BridgeProductMetadataCatalogWriterError.entryDoesNotFitMetadataFrame) {
            _ = try await writer.write(
                entries: [entry],
                catalogRevision: 1,
                transferID: UUIDv7.generate().uuidString.lowercased(),
                makeProspectiveMetadataFrame: CatalogWriterFixtureFrame.init(phase:),
                enqueue: { phase in await recorder.enqueue(phase) },
                waitUntilObserved: { sequence in await recorder.waitUntilObserved(sequence) }
            )
        }
        #expect((await recorder.snapshot()).phases.isEmpty)
    }

    @Test("exact metadata-frame ceiling fits and one byte over emits no begin")
    func exactMetadataFrameCeilingFitsAndOneByteOverDoesNot() async throws {
        // Arrange
        let transferID = UUIDv7.generate().uuidString.lowercased()
        let exactPayloadLength = try maximumFittingCatalogWriterPayloadLength(
            transferID: transferID
        )
        let exactEntry = CatalogWriterFixtureEntry(
            identifier: "exact",
            payload: String(repeating: "x", count: exactPayloadLength)
        )
        let oversizedEntry = CatalogWriterFixtureEntry(
            identifier: "exact",
            payload: String(repeating: "x", count: exactPayloadLength + 1)
        )
        let exactRecorder = CatalogWriterRecorder<CatalogWriterFixtureEntry>()
        let oversizedRecorder = CatalogWriterRecorder<CatalogWriterFixtureEntry>()
        let writer = BridgeProductMetadataCatalogWriter<CatalogWriterFixtureEntry>()

        // Act
        let exactResult = try await writer.write(
            entries: [exactEntry],
            catalogRevision: 1,
            transferID: transferID,
            makeProspectiveMetadataFrame: CatalogWriterFixtureFrame.init(phase:),
            enqueue: { phase in await exactRecorder.enqueue(phase) },
            waitUntilObserved: { sequence in await exactRecorder.waitUntilObserved(sequence) }
        )

        // Assert
        #expect(exactResult.windowCount == 1)
        await #expect(throws: BridgeProductMetadataCatalogWriterError.entryDoesNotFitMetadataFrame) {
            _ = try await writer.write(
                entries: [oversizedEntry],
                catalogRevision: 1,
                transferID: transferID,
                makeProspectiveMetadataFrame: CatalogWriterFixtureFrame.init(phase:),
                enqueue: { phase in await oversizedRecorder.enqueue(phase) },
                waitUntilObserved: { sequence in await oversizedRecorder.waitUntilObserved(sequence) }
            )
        }
        #expect((await oversizedRecorder.snapshot()).phases.isEmpty)
    }

    @Test("aggregate entry byte overflow emits no begin")
    func aggregateEntryByteOverflowEmitsNoBegin() async throws {
        // Arrange
        let recorder = CatalogWriterRecorder<CatalogWriterFixtureEntry>()
        let writer = BridgeProductMetadataCatalogWriter<CatalogWriterFixtureEntry>()
        let entries = (0..<130).map {
            CatalogWriterFixtureEntry(identifier: "entry-\($0)", payload: String(repeating: "x", count: 65_000))
        }

        // Act / Assert
        await #expect(throws: BridgeProductMetadataCatalogWriterError.encodedEntryBytesExceeded) {
            _ = try await writer.write(
                entries: entries,
                catalogRevision: 1,
                transferID: UUIDv7.generate().uuidString.lowercased(),
                makeProspectiveMetadataFrame: CatalogWriterFixtureFrame.init(phase:),
                enqueue: { phase in await recorder.enqueue(phase) },
                waitUntilObserved: { sequence in await recorder.waitUntilObserved(sequence) }
            )
        }
        #expect((await recorder.snapshot()).phases.isEmpty)
    }

    @Test("product aggregate limits accept exact boundaries and reject one over")
    func productAggregateLimitsAreExact() {
        // Arrange / Act / Assert
        #expect(
            BridgeProductMetadataCatalogCapacity.admits(
                entryCount: BridgeProductMetadataCatalogCapacity.maximumEntryCount,
                encodedEntryBytes: BridgeProductMetadataCatalogCapacity.maximumEncodedEntryBytes
            )
        )
        #expect(
            !BridgeProductMetadataCatalogCapacity.admits(
                entryCount: BridgeProductMetadataCatalogCapacity.maximumEntryCount + 1,
                encodedEntryBytes: BridgeProductMetadataCatalogCapacity.maximumEncodedEntryBytes
            )
        )
        #expect(
            !BridgeProductMetadataCatalogCapacity.admits(
                entryCount: BridgeProductMetadataCatalogCapacity.maximumEntryCount,
                encodedEntryBytes: BridgeProductMetadataCatalogCapacity.maximumEncodedEntryBytes + 1
            )
        )
    }
}

private func maximumFittingCatalogWriterPayloadLength(transferID: String) throws -> Int {
    var lowerBound = 0
    var upperBound = BridgeProductWireContract.maximumMetadataFrameBytes
    var acceptedPayloadLength = 0
    while lowerBound <= upperBound {
        let candidatePayloadLength = lowerBound + ((upperBound - lowerBound) / 2)
        let candidate = BridgeProductMetadataCatalogTransfer<CatalogWriterFixtureEntry>.window(
            transferID: transferID,
            catalogRevision: 1,
            windowOrdinal: 0,
            entries: [
                .init(
                    identifier: "exact",
                    payload: String(repeating: "x", count: candidatePayloadLength)
                )
            ]
        )
        do {
            _ = try BridgeProductMetadataFrameCodec.encodeJSONBody(
                CatalogWriterFixtureFrame(phase: candidate)
            )
            acceptedPayloadLength = candidatePayloadLength
            lowerBound = candidatePayloadLength + 1
        } catch {
            upperBound = candidatePayloadLength - 1
        }
    }
    let exactTransfer = BridgeProductMetadataCatalogTransfer<CatalogWriterFixtureEntry>.window(
        transferID: transferID,
        catalogRevision: 1,
        windowOrdinal: 0,
        entries: [
            .init(
                identifier: "exact",
                payload: String(repeating: "x", count: acceptedPayloadLength)
            )
        ]
    )
    #expect(
        try BridgeProductMetadataFrameCodec.encodeJSONBody(
            CatalogWriterFixtureFrame(phase: exactTransfer)
        ).count == BridgeProductWireContract.maximumMetadataFrameBytes
    )
    return acceptedPayloadLength
}

private struct CatalogWriterFixtureEntry: Codable, Equatable, Sendable {
    let identifier: String
    let payload: String

    init(identifier: String, payload: String = "") {
        self.identifier = identifier
        self.payload = payload
    }
}

private struct CatalogWriterFixtureFrame: Encodable, Sendable {
    let metadataStreamID = "metadata-stream-worst-case-envelope"
    let paneSessionID = "pane-session-worst-case-envelope"
    let phase: BridgeProductMetadataCatalogTransfer<CatalogWriterFixtureEntry>
    let streamSequence = BridgeProductWireContract.maximumSafeInteger
    let subscriptionID = "subscription-worst-case-envelope"
    let subscriptionSequence = BridgeProductWireContract.maximumSafeInteger
    let workerInstanceID = "worker-instance-worst-case-envelope"
}

private actor CatalogWriterRecorder<Entry>
where Entry: Codable & Equatable & Sendable {
    struct Snapshot: Sendable {
        let observedSequences: [Int]
        let phases: [BridgeProductMetadataCatalogTransfer<Entry>]
    }

    private var observedSequences: [Int] = []
    private var phases: [BridgeProductMetadataCatalogTransfer<Entry>] = []

    func enqueue(
        _ phase: BridgeProductMetadataCatalogTransfer<Entry>
    ) -> BridgeProductProducerEnqueueResult {
        phases.append(phase)
        let sequence = phases.count
        return .enqueued(
            .init(
                data: Data([UInt8(sequence)]),
                sequence: sequence,
                terminal: false,
                requiredOpening: false,
                batchComplete: false
            )
        )
    }

    func waitUntilObserved(_ sequence: Int) -> Bool {
        observedSequences.append(sequence)
        return true
    }

    func snapshot() -> Snapshot {
        .init(observedSequences: observedSequences, phases: phases)
    }
}
