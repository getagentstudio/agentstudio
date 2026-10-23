import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioTerminal

extension ScrollbackSnapshotterTests {
    @Test("one pass records exact cost and outcome counts without content, ids or paths")
    func passCostProbeReportsBoundedAggregate() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let bindings = (0..<5).map { _ in
            ScrollbackPaneBinding(paneID: .generateUUIDv7(), sessionID: .generateUUIDv7())
        }
        let contentSentinel = "/private/terminal-content-\(UUIDv7.generate().uuidString)"
        let written = Data("\(contentSentinel)\r\n".utf8)
        let unchanged = Data("unchanged valid output".utf8)
        let invalid = Data("invalid interior".utf8) + Data([0xFF]) + Data(contentSentinel.utf8)
        _ = try await fixture.store.store(paneId: bindings[1].paneID, capture: unchanged)
        let hold = HeldStep<ZmxSessionID>("pass probe capture held across two controlled seconds")
        defer { hold.release() }
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: bindings,
            results: [
                bindings[0].sessionID: .accepted(written), bindings[1].sessionID: .accepted(unchanged),
                bindings[2].sessionID: .accepted(invalid), bindings[3].sessionID: .empty,
                bindings[4].sessionID: .deadlineExceeded,
            ], heldCaptures: [bindings[2].sessionID: hold])
        let performance = ScrollbackPassRecorder()
        let snapshotter = ScrollbackSnapshotter(
            clock: fixture.clock, store: fixture.store, performanceRecorder: performance,
            inventory: { await backend.discoverInventory() }, paneBindings: { await backend.paneBindings() },
            capture: { await backend.capture($0) }, factSink: fixture.source.sink)
        var bodyError: (any Error)?
        do {
            let requestID = UUIDv7.generate()
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(20))
            let pass = try await fixture.nextPass(reason: .quit)
            let heldSession = try await hold.firstArrival()
            #expect(heldSession == bindings[2].sessionID)
            fixture.clock.advance(by: .seconds(2))
            hold.release()
            let quitOutcome = await quit
            #expect(quitOutcome == .completed)
            try await fixture.finishPass(pass, count: bindings.count)
            // Completion is the closing event. Absence of recorder calls
            // fails this assertion immediately rather than hanging a waiter.
            let observed = performance.observations()
            let expected = ScrollbackPassMeasurement(
                reason: .quit, paneCount: bindings.count,
                capturedBytes: written.count + unchanged.count + invalid.count,
                writtenBytes: (ScrollbackStore.resetPrefix + written).count,
                outcomeCounts: [.written: 1, .unchanged: 1, .invalidUTF8: 1, .empty: 1, .deadlineExceeded: 1],
                duration: .seconds(2))
            #expect(observed == [.started(.quit), .finished(expected)])
            for observation in observed {
                let serialized = String(describing: observation)
                #expect(!serialized.contains(contentSentinel))
                #expect(!serialized.contains(fixture.root.path))
                #expect(!serialized.contains(requestID.uuidString))
                for binding in bindings {
                    #expect(!serialized.contains(binding.paneID.uuidString))
                    #expect(!serialized.contains(binding.sessionID.rawValue))
                }
            }
        } catch { bodyError = error }
        hold.release()
        await snapshotter.shutdown()
        try await fixture.cleanup()
        if let bodyError { throw bodyError }
    }
}

private final class ScrollbackPassRecorder: ScrollbackPerformanceRecording {
    private let recorded = Mutex<[ScrollbackPerformanceObservation]>([])

    func recordScrollbackPassObservation(_ observation: ScrollbackPerformanceObservation) {
        recorded.withLock { $0.append(observation) }
    }

    func observations() -> [ScrollbackPerformanceObservation] {
        recorded.withLock { $0 }
    }
}
