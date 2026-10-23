import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@Suite("Scrollback snapshot cadence and lifecycle")
struct ScrollbackSnapshotterTests {
    @Test("a tick captures every live pane without visibility, surface or restore-phase inputs")
    func tickCapturesAllLiveBindings() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        // These panes represent visible, hidden, restoring and surfaceless
        // owners. The input contract cannot filter by any of those states.
        let bindings = (0..<4).map { _ in makeBinding() }
        let results = Dictionary(
            uniqueKeysWithValues: bindings.enumerated().map { index, binding in
                (binding.sessionID, ScrollbackCaptureResult.accepted(Data("pane \(index)".utf8)))
            })
        let backend = ScrollbackCaptureFixtureBackend(bindings: bindings, results: results)
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        try await withSnapshotter(snapshotter, fixture: fixture) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
            let pass = try await fixture.nextPass(reason: .periodic)
            for (index, binding) in bindings.enumerated() {
                let capture = try await fixture.nextCapture(binding)
                try await fixture.recorder.expectNext(in: capture, .captureFinished(.written))
                #expect(
                    await fixture.store.load(paneId: binding.paneID)
                        == .present(ScrollbackStore.resetPrefix + Data("pane \(index)".utf8)))
            }
            try await fixture.finishPass(pass, count: 4)
            await snapshotter.shutdown()
            #expect(fixture.clock.pendingSleepCount == 0)
        }
    }

    @Test("in-place output redraw is captured on the next tick without a row-growth or activity signal")
    func nextTickCapturesInPlaceRedraw() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [binding], results: [binding.sessionID: .accepted(Data("old row".utf8))])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        try await withSnapshotter(snapshotter, fixture: fixture) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            try await captureTick(fixture, snapshotter: snapshotter, binding: binding, disposition: .written)
            await backend.replaceResult(sessionID: binding.sessionID, result: .accepted(Data("new row".utf8)))
            try await captureTick(fixture, snapshotter: snapshotter, binding: binding, disposition: .written)
            #expect(
                await fixture.store.load(paneId: binding.paneID)
                    == .present(ScrollbackStore.resetPrefix + Data("new row".utf8)))
            try await captureTick(fixture, snapshotter: snapshotter, binding: binding, disposition: .unchanged)
            await snapshotter.shutdown()
        }
    }

    @Test(
        "failed or empty captures keep the last accepted snapshot",
        arguments: [
            ScrollbackCaptureResult.empty, .deadlineExceeded, .exceededCeiling, .launchFailed(errno: 2), .readFailed,
            .exitedNonZero(7),
        ])
    func failedCaptureKeepsSnapshot(result: ScrollbackCaptureResult) async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        let original = Data("last accepted".utf8)
        _ = try await fixture.store.store(paneId: binding.paneID, capture: original)
        let backend = ScrollbackCaptureFixtureBackend(bindings: [binding], results: [binding.sessionID: result])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        try await withSnapshotter(snapshotter, fixture: fixture) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            try await captureTick(
                fixture, snapshotter: snapshotter, binding: binding, disposition: disposition(for: result))
            #expect(
                await fixture.store.load(paneId: binding.paneID) == .present(ScrollbackStore.resetPrefix + original))
            await snapshotter.shutdown()
        }
    }

    @Test("unavailable inventory closes the pass without admitting captures")
    func unavailableInventoryDoesNotCapture() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [binding], results: [:], inventory: .unavailable(.timedOut))
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        try await withSnapshotter(snapshotter, fixture: fixture) {
            let requestID = UUIDv7.generate()
            let opening = await fixture.recorder.mark(.pass(requestID))
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            try await fixture.recorder.expectNone(
                of: { if case .captureAdmitted = $0 { true } else { false } },
                "unavailable inventory must not admit captures", from: opening,
                closedBy: { $0 == .passFinished(outcome: .inventoryUnavailable, capturedPaneCount: 0) })
            _ = await quit
            #expect(await backend.callCount(for: binding.sessionID) == 0)
            await snapshotter.shutdown()
        }
    }

    @Test("unavailable persisted bindings keep prior snapshots without admitting a capture")
    func unavailableBindingsDoesNotCapture() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        let original = Data("saved before binding read failed".utf8)
        _ = try await fixture.store.store(paneId: binding.paneID, capture: original)
        let backend = ScrollbackCaptureFixtureBackend(bindings: [binding], results: [:])
        let snapshotter = ScrollbackSnapshotter(
            clock: fixture.clock, store: fixture.store, performanceRecorder: nil,
            inventory: { await backend.discoverInventory() },
            paneBindings: { throw BindingReadFailure.unavailable }, capture: { await backend.capture($0) },
            factSink: fixture.source.sink)
        try await withSnapshotter(snapshotter, fixture: fixture) {
            let requestID = UUIDv7.generate()
            let opening = await fixture.recorder.mark(.pass(requestID))
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            try await fixture.recorder.expectNone(
                of: { if case .captureAdmitted = $0 { true } else { false } },
                "failed binding read cannot admit captures", from: opening,
                closedBy: { $0 == .passFinished(outcome: .bindingsUnavailable, capturedPaneCount: 0) })
            _ = await quit
            #expect(await backend.callCount(for: binding.sessionID) == 0)
            #expect(
                await fixture.store.load(paneId: binding.paneID) == .present(ScrollbackStore.resetPrefix + original))
        }
    }

    private enum BindingReadFailure: Error { case unavailable }

    @Test("periodic and quit passes share one capture per pane")
    func quitJoinsPeriodicCapture() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        let hold = HeldStep<ZmxSessionID>("shared periodic/quit history capture")
        defer { hold.release() }
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [binding], results: [binding.sessionID: .accepted(Data("shared".utf8))],
            heldCaptures: [binding.sessionID: hold])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        let releaseCaptures: @Sendable () -> Void = { hold.release() }
        try await withSnapshotter(snapshotter, fixture: fixture, releaseHolds: releaseCaptures) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
            let periodicPass = try await fixture.nextPass(reason: .periodic)
            let capture = try await fixture.nextCapture(binding)
            _ = try await hold.firstArrival()
            let requestID = UUIDv7.generate()
            let quitOpening = await fixture.recorder.mark(.pass(requestID))
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            try await fixture.recorder.expectNext(in: .quit(requestID), .quitStarted)
            let quitPass = try await fixture.nextPass(reason: .quit)
            #expect(quitPass == .pass(requestID))
            try await fixture.recorder.expectNext(in: quitPass, .captureJoined(binding))
            hold.release()
            try await fixture.recorder.expectNext(in: capture, .captureFinished(.written))
            try await fixture.finishPass(periodicPass, count: 1)
            try await fixture.recorder.expectNone(
                of: { if case .captureAdmitted = $0 { true } else { false } },
                "quit must join the already-admitted periodic capture", from: quitOpening,
                closedBy: { $0 == .passFinished(outcome: .completed, capturedPaneCount: 1) })
            let outcome = await quit
            #expect(outcome == .completed)
            #expect(await backend.callCount(for: binding.sessionID) == 1)
            await snapshotter.shutdown()
        }
    }

    @Test("quit joins the periodic capture and also captures a newly created live pane")
    func quitIncludesBindingCreatedDuringPeriodicPass() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let original = makeBinding()
        let added = makeBinding()
        let hold = HeldStep<ZmxSessionID>("original capture held while a new live pane is created")
        defer { hold.release() }
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [original],
            results: [original.sessionID: .accepted(Data("original pane".utf8))],
            heldCaptures: [original.sessionID: hold])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        let releaseCaptures: @Sendable () -> Void = { hold.release() }
        try await withSnapshotter(snapshotter, fixture: fixture, releaseHolds: releaseCaptures) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
            let periodicPass = try await fixture.nextPass(reason: .periodic)
            let originalCapture = try await fixture.nextCapture(original)
            _ = try await hold.firstArrival()
            await backend.addLiveBinding(added, result: .accepted(Data("new pane".utf8)))
            let requestID = UUIDv7.generate()
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            let quitPass = try await fixture.nextPass(reason: .quit)
            try await fixture.recorder.expectNext(in: quitPass, .captureJoined(original))
            hold.release()
            try await fixture.recorder.expectNext(in: originalCapture, .captureFinished(.written))
            try await fixture.finishPass(periodicPass, count: 1)
            let addedCapture = try await fixture.nextCapture(added)
            try await fixture.recorder.expectNext(in: addedCapture, .captureFinished(.written))
            try await fixture.finishPass(quitPass, count: 2)
            let quitOutcome = await quit
            #expect(quitOutcome == .completed)
            #expect(await backend.callCount(for: original.sessionID) == 1)
            #expect(await backend.callCount(for: added.sessionID) == 1)
            #expect(
                await fixture.store.load(paneId: added.paneID)
                    == .present(ScrollbackStore.resetPrefix + Data("new pane".utf8)))
        }
    }

    @Test("quit refreshes a completed pane while sharing only the pane still in flight")
    func quitRefreshesCompletedPaneDuringHeldPeriodicFleet() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let completed = makeBinding()
        let inFlight = makeBinding()
        let oldBytes = Data("A before redraw".utf8)
        let newBytes = Data("A after redraw".utf8)
        let hold = HeldStep<ZmxSessionID>("B remains in flight after A has completed")
        defer { hold.release() }
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [completed, inFlight],
            results: [completed.sessionID: .accepted(oldBytes), inFlight.sessionID: .accepted(Data("B".utf8))],
            heldCaptures: [inFlight.sessionID: hold])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        let releaseCaptures: @Sendable () -> Void = { hold.release() }
        try await withSnapshotter(snapshotter, fixture: fixture, releaseHolds: releaseCaptures) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
            let periodicPass = try await fixture.nextPass(reason: .periodic)
            let completedCapture = try await fixture.nextCapture(completed)
            try await fixture.recorder.expectNext(in: completedCapture, .captureFinished(.written))
            let sharedCapture = try await fixture.nextCapture(inFlight)
            let heldSession = try await hold.firstArrival()
            #expect(heldSession == inFlight.sessionID)
            #expect(
                await fixture.store.load(paneId: completed.paneID)
                    == .present(ScrollbackStore.resetPrefix + oldBytes))
            await backend.replaceResult(sessionID: completed.sessionID, result: .accepted(newBytes))
            let requestID = UUIDv7.generate()
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            let quitPass = try await fixture.nextPass(reason: .quit)
            // This event proves quit has joined B before B is released.
            // Whether A is refreshed before or after B settles is not prescribed.
            while true {
                let observation = try await fixture.recorder.expectNext(
                    in: quitPass,
                    where: {
                        switch $0 {
                        case .captureAdmitted, .captureJoined: true
                        default: false
                        }
                    }, "quit admission or join through the in-flight B capture")
                if observation == .captureJoined(inFlight) { break }
                switch observation {
                case .captureAdmitted(let binding), .captureJoined(let binding):
                    #expect(binding == completed)
                default:
                    Issue.record("quit must share B before completing its pass")
                }
            }
            hold.release()
            try await fixture.recorder.expectNext(in: sharedCapture, .captureFinished(.written))
            try await fixture.finishPass(periodicPass, count: 2)
            let quitOutcome = await quit
            #expect(quitOutcome == .completed)
            try await fixture.finishPass(quitPass, count: 2)
            #expect(
                await fixture.store.load(paneId: completed.paneID)
                    == .present(ScrollbackStore.resetPrefix + newBytes))
            #expect(await backend.callCount(for: completed.sessionID) == 2)
            #expect(await backend.callCount(for: inFlight.sessionID) == 1)
            #expect(await backend.peakConcurrency() <= AppPolicies.Restore.maximumConcurrentCaptures)
        }
    }

    @Test(
        "rejected invalid or alternate output closes with a typed outcome and preserves old bytes",
        arguments: [
            Data("bad".utf8) + Data([0xFF]) + Data("interior".utf8),
            Data("\u{1B}[?1049h\u{1B}[?25ltemporary app".utf8),
        ])
    func rejectedCaptureRecordsDisposition(captureBytes: Data) async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        let original = Data("last valid primary output".utf8)
        _ = try await fixture.store.store(paneId: binding.paneID, capture: original)
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [binding], results: [binding.sessionID: .accepted(captureBytes)])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        try await withSnapshotter(snapshotter, fixture: fixture) {
            let requestID = UUIDv7.generate()
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            let pass = try await fixture.nextPass(reason: .quit)
            let capture = try await fixture.nextCapture(binding)
            let observed = try await fixture.recorder.expectNext(
                in: capture, where: { if case .captureFinished = $0 { true } else { false } },
                "typed capture rejection outcome")
            guard case .captureFinished(let disposition) = observed else {
                Issue.record("capture must end with its typed disposition")
                return
            }
            let expected: ScrollbackSnapshotDisposition =
                captureBytes.first == 0x1B ? .keepPrevious : .invalidUTF8
            #expect(disposition == expected)
            let quitOutcome = await quit
            #expect(quitOutcome == .completed)
            try await fixture.finishPass(pass, count: 1)
            #expect(
                await fixture.store.load(paneId: binding.paneID)
                    == .present(ScrollbackStore.resetPrefix + original))
        }
    }

    @Test("quit deadline cancels a held capture, keeps old bytes, and joins work")
    func quitDeadlineCancelsCapture() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        let original = Data("previous".utf8)
        _ = try await fixture.store.store(paneId: binding.paneID, capture: original)
        let hold = HeldStep<ZmxSessionID>("capture cancelled at quit budget")
        defer { hold.release() }
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [binding], results: [binding.sessionID: .accepted(Data("late".utf8))],
            heldCaptures: [binding.sessionID: hold])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        let releaseCaptures: @Sendable () -> Void = { hold.release() }
        try await withSnapshotter(snapshotter, fixture: fixture, releaseHolds: releaseCaptures) {
            let requestID = UUIDv7.generate()
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            try await fixture.recorder.expectNext(in: .quit(requestID), .quitStarted)
            let pass = try await fixture.nextPass(reason: .quit)
            let capture = try await fixture.nextCapture(binding)
            _ = try await hold.firstArrival()
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: .seconds(1))
            let outcome = await quit
            #expect(outcome == .deadlineExceeded)
            try await fixture.recorder.expectNext(in: capture, .captureFinished(.cancelled))
            try await fixture.finishPass(pass, outcome: .cancelled, count: 1)
            try await fixture.recorder.expectNext(in: .quit(requestID), .quitFinished(.deadlineExceeded))
            #expect(await backend.activeCaptureCount() == 0)
            #expect(
                await fixture.store.load(paneId: binding.paneID) == .present(ScrollbackStore.resetPrefix + original))
            #expect(fixture.clock.pendingSleepCount == 0)
            await snapshotter.shutdown()
        }
    }

    @Test("a late capture after retirement cannot recreate the snapshot")
    func retirementRejectsLateCapture() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let binding = makeBinding()
        _ = try await fixture.store.store(paneId: binding.paneID, capture: Data("old before retirement".utf8))
        let hold = HeldStep<ZmxSessionID>(
            "late capture ignores cancellation until explicitly released", cancellation: .holdThroughCancellation)
        defer { hold.release() }
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: [binding], results: [binding.sessionID: .accepted(Data("late".utf8))],
            heldCaptures: [binding.sessionID: hold])
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        let releaseCaptures: @Sendable () -> Void = { hold.release() }
        try await withSnapshotter(snapshotter, fixture: fixture, releaseHolds: releaseCaptures) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
            let pass = try await fixture.nextPass(reason: .periodic)
            let capture = try await fixture.nextCapture(binding)
            _ = try await hold.firstArrival()
            let operationID = UUIDv7.generate()
            async let retirement = snapshotter.retire(operationID: operationID, paneIDs: [binding.paneID])
            try await fixture.recorder.expectNext(in: .retirement(operationID), .retirementStarted([binding.paneID]))
            try await hold.cancellationObserved()
            #expect(await fixture.store.load(paneId: binding.paneID) == .absent)
            hold.release()
            try await retirement
            try await fixture.recorder.expectNext(in: .retirement(operationID), .retirementFinished)
            try await fixture.recorder.expectNext(in: capture, .captureFinished(.retired))
            try await fixture.finishPass(pass, count: 1)
            #expect(await fixture.store.load(paneId: binding.paneID) == .absent)
            let snapshotURL = fixture.store.snapshotURL(for: binding.paneID)
            #expect(await withoutBlockingCooperativePool { !FileManager.default.fileExists(atPath: snapshotURL.path) })
            await snapshotter.shutdown()
        }
    }

    @Test("only positively live owned sessions are admitted")
    func inventoryFiltersUnresponsiveRefusedMissingAndForeignSessions() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let live = makeBinding()
        let unresponsive = makeBinding()
        let refused = makeBinding()
        let missing = makeBinding()
        let foreignSession = ZmxSessionID.generateUUIDv7()
        let bindings = [live, unresponsive, refused, missing]
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: bindings,
            results: Dictionary(uniqueKeysWithValues: bindings.map { ($0.sessionID, .accepted(Data("output".utf8))) }),
            inventory: .complete([
                live.sessionID: .alive(wrapperPid: 1), unresponsive.sessionID: .unresponsive,
                refused.sessionID: .refused, foreignSession: .alive(wrapperPid: 2),
            ]))
        let snapshotter = makeSnapshotter(fixture, backend: backend)
        try await withSnapshotter(snapshotter, fixture: fixture) {
            let requestID = UUIDv7.generate()
            let opening = await fixture.recorder.mark(.pass(requestID))
            async let quit = snapshotter.captureForQuit(requestID: requestID, budget: .seconds(1))
            let capture = try await fixture.nextCapture(live)
            try await fixture.recorder.expectNext(in: capture, .captureFinished(.written))
            let forbiddenAdmission: @Sendable (ScrollbackSnapshotterFact) -> Bool = { fact in
                if case .captureAdmitted(let binding) = fact { binding != live } else { false }
            }
            try await fixture.recorder.expectNone(
                of: forbiddenAdmission, "non-live or unowned sessions cannot be captured", from: opening,
                closedBy: { $0 == .passFinished(outcome: .completed, capturedPaneCount: 1) })
            _ = await quit
            await snapshotter.shutdown()
        }
    }

    @Test("capture concurrency is bounded while every live pane is eventually visited")
    func concurrencyIsBounded() async throws {
        let fixture = try ScrollbackSnapshotterFixture()
        let bindings = (0..<5).map { _ in makeBinding() }
        let holds = Dictionary(
            uniqueKeysWithValues: bindings.map {
                ($0.sessionID, HeldStep<ZmxSessionID>("bounded capture for one live session"))
            })
        defer { for hold in holds.values { hold.release() } }
        let backend = ScrollbackCaptureFixtureBackend(
            bindings: bindings,
            results: Dictionary(uniqueKeysWithValues: bindings.map { ($0.sessionID, .accepted(Data("output".utf8))) }),
            heldCaptures: holds)
        let snapshotter = ScrollbackSnapshotter(
            clock: fixture.clock, store: fixture.store, performanceRecorder: nil,
            inventory: { await backend.discoverInventory() }, paneBindings: { await backend.paneBindings() },
            capture: { await backend.capture($0) }, maximumConcurrentCaptures: 2, factSink: fixture.source.sink)
        let releaseCaptures: @Sendable () -> Void = { for hold in holds.values { hold.release() } }
        try await withSnapshotter(snapshotter, fixture: fixture, releaseHolds: releaseCaptures) {
            await snapshotter.start()
            try await fixture.recorder.expectNext(in: .scheduler, .scheduled)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
            let pass = try await fixture.nextPass(reason: .periodic)
            for _ in 0..<2 {
                let scope = try await fixture.recorder.expectNextOperation(
                    matching: { if case .capture = $0 { true } else { false } },
                    opening: { if case .captureStarted = $0 { true } else { false } },
                    "one of the first bounded captures")
                let fact = try await fixture.recorder.expectNext(
                    in: scope, where: { if case .captureStarted = $0 { true } else { false } }, "capture started")
                guard case .captureStarted(let binding) = fact else {
                    Issue.record("expected capture start")
                    return
                }
                _ = try await holds[binding.sessionID]?.firstArrival()
            }
            for hold in holds.values { hold.release() }
            try await fixture.finishPass(pass, count: 5)
            #expect(await backend.peakConcurrency() == 2)
            #expect(await backend.activeCaptureCount() == 0)
            for binding in bindings { #expect(await backend.callCount(for: binding.sessionID) == 1) }
            await snapshotter.shutdown()
        }
    }

    private func withSnapshotter(
        _ snapshotter: ScrollbackSnapshotter, fixture: ScrollbackSnapshotterFixture,
        releaseHolds: @escaping @Sendable () -> Void = {}, body: () async throws -> Void
    ) async throws {
        var bodyError: (any Error)?
        do {
            try await withTaskCancellationHandler {
                try await body()
            } onCancel: {
                releaseHolds()
            }
        } catch { bodyError = error }
        releaseHolds()
        await snapshotter.shutdown()
        try await fixture.cleanup()
        if let bodyError { throw bodyError }
    }

    private func makeBinding() -> ScrollbackPaneBinding {
        .init(paneID: .generateUUIDv7(), sessionID: .generateUUIDv7())
    }

    private func makeSnapshotter(_ fixture: ScrollbackSnapshotterFixture, backend: ScrollbackCaptureFixtureBackend)
        -> ScrollbackSnapshotter
    {
        ScrollbackSnapshotter(
            clock: fixture.clock, store: fixture.store, performanceRecorder: nil,
            inventory: { await backend.discoverInventory() }, paneBindings: { await backend.paneBindings() },
            capture: { await backend.capture($0) }, factSink: fixture.source.sink)
    }

    private func captureTick(
        _ fixture: ScrollbackSnapshotterFixture, snapshotter: ScrollbackSnapshotter, binding: ScrollbackPaneBinding,
        disposition: ScrollbackSnapshotDisposition
    ) async throws {
        await fixture.clock.waitForPendingSleepCount(exactly: 1)
        fixture.clock.advance(by: AppPolicies.Restore.captureInterval)
        let pass = try await fixture.nextPass(reason: .periodic)
        let capture = try await fixture.nextCapture(binding)
        try await fixture.recorder.expectNext(in: capture, .captureFinished(disposition))
        try await fixture.finishPass(pass, count: 1)
    }

    private func disposition(for result: ScrollbackCaptureResult) -> ScrollbackSnapshotDisposition {
        switch result {
        case .accepted: .written
        case .empty: .empty
        case .deadlineExceeded: .deadlineExceeded
        case .exceededCeiling: .exceededCeiling
        case .launchFailed(let errno): .launchFailed(errno: errno)
        case .readFailed: .readFailed
        case .exitedNonZero(let status): .exitedNonZero(status)
        }
    }
}
