import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioTerminal

@MainActor
@Suite("Scrollback startup and quit ordering", .serialized)
struct ScrollbackStartupTerminationTests {
    @Test("the first interactive frame releases snapshot cadence independently of terminal restore settlement")
    func firstFrameReleasesCaptureCadence() async throws {
        let captureClock = AgentStudioTestSupport.TestPushClock()
        let frameClock = AgentStudioTestSupport.TestPushClock()
        let window = WindowLifecycleAtom(deferralDelay: .clock(frameClock))
        let root = FileManager.default.temporaryDirectory.appending(
            path: "scrollback-first-frame-\(UUIDv7.generate().uuidString)")
        let store = ScrollbackStore(directoryURL: root)
        let source = makeSource()
        let recorder = try source.attach()
        let snapshotter = ScrollbackSnapshotter(
            clock: captureClock, store: store, performanceRecorder: nil, inventory: { .complete([:]) },
            paneBindings: { [] }, capture: { _ in .empty }, factSink: source.sink)
        try await withSnapshotter(snapshotter, recorder: recorder, root: root) {
            async let startup = startScrollbackAfterFirstFrame(windowLifecycleStore: window, snapshotter: snapshotter)
            try await recorder.expectNext(in: .scheduler, .firstFrameGateWaiting)
            await frameClock.waitForPendingSleepCount(atLeast: 1)
            captureClock.advance(by: AppPolicies.Restore.captureInterval)
            window.recordFirstInteractiveFramePublished(source: .presented)
            let outcome = await startup
            #expect(outcome == .completed)
            // The helper announces the opened gate before arming cadence.
            try await recorder.expectNext(in: .scheduler, .firstFrameGatePassed)
            try await recorder.expectNext(in: .scheduler, .scheduled)
            await captureClock.waitForPendingSleepCount(exactly: 1)
            await snapshotter.shutdown()
            #expect(captureClock.pendingSleepCount == 0)
            await frameClock.waitForPendingSleepCount(exactly: 0)
            #expect(frameClock.pendingSleepCount == 0)
        }
    }

    @Test("quit capture settles before surface shutdown within the existing termination contract")
    func capturePrecedesSurfaceShutdown() async throws {
        let clock = AgentStudioTestSupport.TestPushClock()
        let pane = ScrollbackPaneBinding(paneID: .generateUUIDv7(), sessionID: .generateUUIDv7())
        let root = FileManager.default.temporaryDirectory.appending(
            path: "scrollback-quit-order-\(UUIDv7.generate().uuidString)")
        let store = ScrollbackStore(directoryURL: root)
        let source = makeSource()
        let recorder = try source.attach()
        let snapshotter = ScrollbackSnapshotter(
            clock: clock, store: store, performanceRecorder: nil,
            inventory: { .complete([pane.sessionID: .alive(wrapperPid: 1)]) }, paneBindings: { [pane] },
            capture: { _ in .accepted(Data("final output".utf8)) }, factSink: source.sink)
        try await withSnapshotter(snapshotter, recorder: recorder, root: root) {
            var observedAtShutdown: ScrollbackLoadResult?
            await captureScrollbackBeforeSurfaceShutdown(snapshotter: snapshotter, budget: .seconds(1)) {
                observedAtShutdown = await store.load(paneId: pane.paneID)
            }
            #expect(observedAtShutdown == .present(ScrollbackStore.persistedForm(Data("final output".utf8))))
            await snapshotter.shutdown()
            #expect(clock.pendingSleepCount == 0)
        }
    }

    private func withSnapshotter(
        _ snapshotter: ScrollbackSnapshotter,
        recorder: FactRecorder<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact>, root: URL,
        body: () async throws -> Void
    ) async throws {
        var bodyError: (any Error)?
        do { try await body() } catch { bodyError = error }
        await snapshotter.shutdown()
        do { try await recorder.finish() } catch { if bodyError == nil { bodyError = error } }
        try await withoutBlockingCooperativePool {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        if let bodyError { throw bodyError }
    }

    private func makeSource() -> LocalFactSource<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact> {
        LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .passFinished, .captureFinished, .retirementFinished, .quitFinished, .stopped: true
                    default: false
                    }
                }))
    }
}
