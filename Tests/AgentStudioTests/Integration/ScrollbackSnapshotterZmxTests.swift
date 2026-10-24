import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

/// Extends the already-classified serialized zmx suite; no new lane row.
extension E2ESerializedTests.ScrollbackCaptureIntegrationTests {
    @Test("a periodic pass snapshots real live sessions without native surfaces")
    func snapshotterTickCapturesRealSurfacelessSessions() async throws {
        try await withRealSnapshotter(consoles: 2) { fixture in
            let pass = try await advanceSnapshotTick(fixture)
            for binding in fixture.bindings {
                let capture = try await fixture.nextCapture(binding)
                try await fixture.recorder.expectNext(in: capture, .captureFinished(.written))
                let rawHistory = try await fixture.rawHistory(binding.sessionID)
                #expect(
                    await fixture.store.load(paneId: binding.paneID)
                        == .present(ScrollbackStore.persistedForm(rawHistory)))
            }
            try await fixture.finishPass(pass, count: 2)
        }
    }

    @Test("real in-place redraw changes the next snapshot without adding terminal rows")
    func snapshotterTickCapturesRealInPlaceRedraw() async throws {
        try await withRealSnapshotter(consoles: 1) { fixture in
            let binding = try #require(fixture.bindings.first)
            let console = try #require(fixture.consoles.first)
            let firstPass = try await advanceSnapshotTick(fixture)
            let firstCapture = try await fixture.nextCapture(binding)
            try await fixture.recorder.expectNext(in: firstCapture, .captureFinished(.written))
            try await fixture.finishPass(firstPass, count: 1)
            let first = await fixture.store.load(paneId: binding.paneID)
            try await console.redrawInPlace()
            let secondPass = try await advanceSnapshotTick(fixture)
            let secondCapture = try await fixture.nextCapture(binding)
            try await fixture.recorder.expectNext(in: secondCapture, .captureFinished(.written))
            try await fixture.finishPass(secondPass, count: 1)
            let rawHistory = try await fixture.rawHistory(binding.sessionID)
            let second = await fixture.store.load(paneId: binding.paneID)
            #expect(second != first)
            #expect(second == .present(ScrollbackStore.persistedForm(rawHistory)))
            #expect(rawHistory.range(of: Data("screen TWO".utf8))?.count == "screen TWO".utf8.count)
        }
    }

    private func advanceSnapshotTick(_ fixture: RealSnapshotterFixture) async throws -> ScrollbackSnapshotterScope {
        await fixture.clock.waitForPendingSleepCount(exactly: 1)
        fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
        let scope = try await fixture.recorder.expectNextOperation(
            matching: { if case .pass = $0 { true } else { false } },
            opening: { $0 == .passStarted(.periodic) }, "real zmx capture pass")
        try await fixture.recorder.expectNext(in: scope, .passStarted(.periodic))
        return scope
    }

    private func withRealSnapshotter(consoles count: Int, body: (RealSnapshotterFixture) async throws -> Void)
        async throws
    {
        let harness = await ZmxTestHarness()
        let backend = try #require(harness.createBackend(), "real isolated zmx backend required")
        var consoles: [ScrollbackZmxConsole] = []
        var fixture: RealSnapshotterFixture?
        var bodyError: (any Error)?
        do {
            for _ in 0..<count { consoles.append(try await ScrollbackZmxConsole.make(harness: harness)) }
            let ready = try RealSnapshotterFixture(harness: harness, backend: backend, consoles: consoles)
            fixture = ready
            await ready.snapshotter.start()
            try await ready.recorder.expectNext(in: .scheduler, .scheduled)
            try await body(ready)
        } catch { bodyError = error }
        if let fixture {
            await fixture.snapshotter.shutdown()
            do { try await fixture.recorder.finish() } catch { if bodyError == nil { bodyError = error } }
            #expect(fixture.clock.pendingSleepCount == 0)
        }
        let cleanup = await harness.cleanup()
        for console in consoles { console.closeHandles() }
        if !cleanup.succeeded { Issue.record("real snapshotter fixture cleanup failed: \(cleanup.diagnostics)") }
        if let bodyError { throw bodyError }
        try #require(cleanup.succeeded)
    }
}

private struct RealSnapshotterFixture {
    let clock: AgentStudioTestSupport.TestPushClock
    let store: ScrollbackStore
    let snapshotter: ScrollbackSnapshotter
    let recorder: FactRecorder<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact>
    let consoles: [ScrollbackZmxConsole]
    let bindings: [ScrollbackPaneBinding]
    private let harness: ZmxTestHarness

    init(harness: ZmxTestHarness, backend: ZmxBackend, consoles: [ScrollbackZmxConsole]) throws {
        self.harness = harness
        self.consoles = consoles
        let bindings: [ScrollbackPaneBinding] = consoles.map {
            .init(paneID: .generateUUIDv7(), sessionID: $0.sessionID)
        }
        let store = ScrollbackStore(directoryURL: URL(fileURLWithPath: harness.zmxDir).appending(path: "scrollback"))
        let clock = AgentStudioTestSupport.TestPushClock()
        self.bindings = bindings
        self.store = store
        self.clock = clock
        let source = LocalFactSource<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .passFinished, .captureFinished, .retirementFinished, .quitFinished, .stopped: true
                    default: false
                    }
                }))
        recorder = try source.attach()
        snapshotter = ScrollbackSnapshotter(
            clock: clock, store: store, performanceRecorder: nil,
            inventory: { await backend.discoverSessionInventory() },
            paneBindings: { bindings }, capture: { await backend.captureHistory($0, clock: clock) },
            factSink: source.sink)
    }

    func nextCapture(_ binding: ScrollbackPaneBinding) async throws -> ScrollbackSnapshotterScope {
        let scope = try await recorder.expectNextOperation(
            matching: { if case .capture(let paneID, _) = $0 { paneID == binding.paneID } else { false } },
            opening: { $0 == .captureStarted(binding) }, "real capture for the expected pane")
        try await recorder.expectNext(in: scope, .captureStarted(binding))
        return scope
    }

    func finishPass(_ scope: ScrollbackSnapshotterScope, count: Int) async throws {
        while true {
            let fact = try await recorder.expectNext(
                in: scope,
                where: {
                    switch $0 {
                    case .captureAdmitted, .captureJoined, .passFinished: true
                    default: false
                    }
                }, "real capture admission, join, or pass completion")
            if case .passFinished(let outcome, let actualCount) = fact {
                #expect(outcome == .completed)
                #expect(actualCount == count)
                return
            }
        }
    }

    func rawHistory(_ sessionID: ZmxSessionID) async throws -> Data {
        let zmxPath = try #require(harness.zmxPath)
        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: zmxPath), arguments: ["history", sessionID.rawValue, "--vt"],
            environment: ProcessInfo.processInfo.environment.merging(["ZMX_DIR": harness.zmxDir]) { _, new in new })
        try #require(output.terminationStatus == 0)
        return output.standardOutput
    }
}
