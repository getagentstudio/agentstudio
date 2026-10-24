import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

@Suite("Process exit watcher source ownership")
struct ProcessExitWatcherOwnershipTests {
    @Test("no initial incarnation check occurs until the registration handler fires")
    func registrationOwnsInitialCheck() async throws {
        try await withProcessExitFixture { fixture in
            let identifier = UUIDv7.generate()
            let watch = try await fixture.open(watchId: identifier)
            let source = try #require(fixture.maker.sources().first)
            #expect(fixture.reader.calls().isEmpty)
            let installs = fixture.maker.ledger.snapshot()
            #expect(installs.first == .made(0))
            #expect(installs.last == .resumed(0))
            #expect(installs.filter { $0 == .registrationHandler(0) }.count == 1)
            #expect(installs.filter { $0 == .eventHandler(0) }.count == 1)
            #expect(installs.filter { $0 == .cancelHandler(0) }.count == 1)
            try await fixture.verifyRegistration(watchId: identifier, source: source)
            #expect(fixture.reader.calls() == [foregroundTestProcess(pid: 4200)])
            watch.cancel()
            try await fixture.recorder.expectNext(in: identifier, .sourceCancelled)
            try await fixture.recorder.expectNext(in: identifier, .cancelled)
        }
    }

    @Test("ESRCH and a recycled sampled process settle as alreadyGone")
    func goneIncarnationIsNotARegistrationFailure() async throws {
        try await withProcessExitFixture { fixture in
            fixture.reader.set(.exited)
            let identifier = UUIDv7.generate()
            let watch = try await fixture.open(watchId: identifier)
            let source = try #require(fixture.maker.sources().first)
            try await fixture.verifyRegistration(watchId: identifier, source: source, expected: .exited)
            try await fixture.recorder.expectNext(in: identifier, .sourceCancelled)
            try await fixture.recorder.expectNext(in: identifier, .settled(.alreadyGone(watchId: identifier)))
            watch.cancel()
            let replay = fixture.watcher.watchExit(of: foregroundTestProcess(pid: 4200), watchId: identifier)
            replay.cancel()
            #expect(fixture.maker.sources().count == 1)
            #expect(fixture.maker.ledger.snapshot().filter { $0 == .cancelled(0) }.count == 1)
        }
    }

    @Test(
        "non-ESRCH check failures stay unavailable with a closed reason",
        arguments: [(EACCES, ProcessExitWatchFailure.permissionDenied), (ENOMEM, .resourceExhausted), (EIO, .other)])
    func unreadableIncarnationIsUnavailable(errnoValue: Int32, expected: ProcessExitWatchFailure) async throws {
        try await withProcessExitFixture { fixture in
            let state = ColdStartLeaderState.unverifiable(POSIXErrorNumber(errnoValue))
            fixture.reader.set(state)
            let identifier = UUIDv7.generate()
            let watch = try await fixture.open(watchId: identifier)
            let source = try #require(fixture.maker.sources().first)
            try await fixture.verifyRegistration(watchId: identifier, source: source, expected: state)
            try await fixture.recorder.expectNext(in: identifier, .sourceCancelled)
            try await fixture.recorder.expectNext(in: identifier, .settled(.unavailable(watchId: identifier, expected)))
            watch.cancel()
            #expect(fixture.maker.ledger.snapshot().filter { $0 == .cancelled(0) }.count == 1)
        }
    }

    @Test(
        "source creation failures preserve errno class and create no resumed source",
        arguments: [(ESRCH, true), (EACCES, false)])
    func failedRegistrationCreatesNoSource(errnoValue: Int32, gone: Bool) async throws {
        try await withProcessExitFixture { fixture in
            fixture.maker.fail(with: errnoValue)
            let identifier = UUIDv7.generate()
            let watch = fixture.watcher.watchExit(of: foregroundTestProcess(pid: 4200), watchId: identifier)
            let event: ProcessExitWatchEvent =
                gone ? .alreadyGone(watchId: identifier) : .unavailable(watchId: identifier, .permissionDenied)
            try await fixture.recorder.expectNext(in: identifier, .settled(event))
            watch.cancel()
            #expect(fixture.maker.sources().isEmpty)
            #expect(fixture.reader.calls().isEmpty)
        }
    }

    @Test("cancel before registration does not wait for registration-after-cancel")
    func cancellationBeforeRegistrationCancelsExactlyOnce() async throws {
        try await withProcessExitFixture { fixture in
            let identifier = UUIDv7.generate()
            let watch = try await fixture.open(watchId: identifier)
            let source = try #require(fixture.maker.sources().first)
            watch.cancel()
            watch.cancel()
            try await fixture.recorder.expectNext(in: identifier, .sourceCancelled)
            try await fixture.recorder.expectNext(in: identifier, .cancelled)
            // Invoke a saved callback directly; never wait for an unspecified callback.
            source.registered()
            source.exited()
            #expect(fixture.reader.calls().isEmpty)
            #expect(fixture.maker.ledger.snapshot().filter { $0 == .cancelled(0) }.count == 1)
        }
    }

    @Test("replacement cancellation precedes successor creation and old handlers stay inert")
    func replacementOwnsBothSources() async throws {
        try await withProcessExitFixture { fixture in
            let oldId = UUIDv7.generate()
            let old = try await fixture.open(watchId: oldId)
            let first = try #require(fixture.maker.sources().first)
            try await fixture.verifyRegistration(watchId: oldId, source: first)
            old.cancel()
            try await fixture.recorder.expectNext(in: oldId, .sourceCancelled)
            try await fixture.recorder.expectNext(in: oldId, .cancelled)
            let newId = UUIDv7.generate()
            let current = try await fixture.open(watchId: newId)
            let second = try #require(fixture.maker.sources().last)
            try await fixture.verifyRegistration(watchId: newId, source: second)
            first.exited()
            let ledger = fixture.maker.ledger.snapshot()
            let cancelledIndex = try #require(ledger.firstIndex(of: .cancelled(0)))
            let successorIndex = try #require(ledger.firstIndex(of: .made(1)))
            #expect(cancelledIndex < successorIndex)
            current.cancel()
            try await fixture.recorder.expectNext(in: newId, .sourceCancelled)
            try await fixture.recorder.expectNext(in: newId, .cancelled)
            fixture.watcher.shutdown()
            #expect(fixture.maker.ledger.snapshot().filter { $0 == .cancelled(0) }.count == 1)
            #expect(fixture.maker.ledger.snapshot().filter { $0 == .cancelled(1) }.count == 1)
        }
    }

    @Test("late watch requests after shutdown create zero sources")
    func lateRequestCannotAcquireSource() async throws {
        try await withProcessExitFixture { fixture in
            fixture.watcher.shutdown()
            let identifier = UUIDv7.generate()
            let watch = fixture.watcher.watchExit(of: foregroundTestProcess(pid: 4200), watchId: identifier)
            try await fixture.recorder.expectNext(in: identifier, .lateRequestDropped)
            watch.cancel()
            #expect(fixture.maker.sources().isEmpty)
            #expect(fixture.reader.calls().isEmpty)
        }
    }

    @Test("a look finishing after retirement creates zero native sources")
    func supersededLookCannotAcquireSource() async throws {
        try await withProcessExitFixture { native in
            let fixture = try ForegroundObserverFixture(exitWatcher: native.watcher)
            let held = HeldStep<[ZmxSessionID: ForegroundSnapshot]>(
                "retired pane look finishing late", cancellation: .holdThroughCancellation)
            defer { held.retire() }
            do {
                await fixture.probe.holdNext(held)
                await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
                try await fixture.expectScheduled()
                let look = try await fixture.expectLookStarted(sequence: 1)
                _ = try await held.firstArrival()
                let opening = await fixture.recorder.mark(look)
                await fixture.observer.retire(paneId: fixture.paneId)
                held.release()
                try await fixture.recorder.expectNone(
                    of: {
                        if case .watchRegistered = $0 { return true }
                        return $0 == .observation(.admitted)
                    },
                    "retired look admission or source allocation", from: opening,
                    closedBy: { $0 == .closed(.retired) })
                #expect(native.maker.sources().isEmpty)
                #expect(native.reader.calls().isEmpty)
                try await fixture.close()
            } catch {
                held.retire()
                try? await fixture.close()
                throw error
            }
        }
    }
}
