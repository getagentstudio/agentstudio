import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge metadata stream keepalive sender")
struct BridgeProductMetadataKeepaliveSenderTests {
    @Test("open stream pulses on the policy clock and stops with the stream")
    func periodicPulseStops() async throws {
        let clock = TestPushClock()
        let (elements, output) = AsyncStream.makeStream(of: Data.self)
        let sender = makeSender(clock: clock, output: output)
        let timer = Task { await sender.run() }
        var received = elements.makeAsyncIterator()

        await clock.waitForPendingSleepCount(atLeast: 1)
        try await sender.send(queuedFrame(sequence: 0, data: [0x01]))
        #expect(await received.next() == Data([0x01]))

        clock.advance(by: AppPolicies.Bridge.streamKeepaliveInterval)
        let pulse = try #require(await received.next())
        #expect(try decodePulse(pulse)?.frameIdentity.streamSequence == 0)

        await sender.stop()
        timer.cancel()
        await timer.value
        await clock.waitForPendingSleepCount(exactly: 0)
        output.finish()
        #expect(await received.next() == nil)
    }

    @Test("each completed batch has exactly one immediate bookend without a product sequence")
    func completedBatchBookends() async throws {
        let clock = TestPushClock()
        let (elements, output) = AsyncStream.makeStream(of: Data.self)
        let sender = makeSender(clock: clock, output: output)
        var received = elements.makeAsyncIterator()

        try await sender.send(queuedFrame(sequence: 7, data: [0x07], batchComplete: true))
        try await sender.send(queuedFrame(sequence: 10, data: [0x0a], batchComplete: true))
        #expect(await received.next() == Data([0x07]))
        #expect(try decodePulse(#require(await received.next()))?.frameIdentity.streamSequence == 7)
        #expect(await received.next() == Data([0x0a]))
        #expect(try decodePulse(#require(await received.next()))?.frameIdentity.streamSequence == 10)
        await sender.stop()
        output.finish()
        #expect(await received.next() == nil)
    }

    private func makeSender(
        clock: TestPushClock,
        output: AsyncStream<Data>.Continuation
    ) -> BridgeProductMetadataKeepaliveSender {
        BridgeProductMetadataKeepaliveSender(
            correlation: .init(
                metadataStreamId: "metadata-stream-keepalive",
                paneSessionId: "pane-session-keepalive",
                wireVersion: BridgeProductWireContract.version,
                workerInstanceId: "worker-instance-keepalive"
            ),
            clock: clock,
            emitData: { data in _ = output.yield(data) }
        )
    }

    private func queuedFrame(
        sequence: Int,
        data: [UInt8],
        batchComplete: Bool = false
    ) -> BridgeProductQueuedProducerFrame {
        .init(
            data: Data(data),
            sequence: sequence,
            terminal: false,
            requiredOpening: sequence == 0,
            batchComplete: batchComplete
        )
    }

    private func decodePulse(_ data: Data) throws -> BridgeProductStreamKeepaliveFrame? {
        let decoder = try BridgeProductMetadataFrameDecoder()
        guard case .streamKeepalive(let frame) = try decoder.append(data).only else {
            return nil
        }
        try decoder.finish()
        return frame
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
