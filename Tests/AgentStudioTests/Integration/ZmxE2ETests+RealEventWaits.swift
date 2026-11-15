import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

/// F7 (review round 1): real-event waits for R1's own new test cases in
/// `ZmxE2ETests.swift`, split into its own file (the repo's line-length
/// ceiling, same precedent as `ZmxE2ETests+ForcedTiming.swift`) rather than
/// the legacy deadline/yield helpers they replace, which stay in place,
/// unmodified, for that file's earlier inherited tests.
extension E2ESerializedTests.ZmxE2ETests {
    /// A real-event read-arrival wait for R1's own option-A cases, replacing
    /// `waitForObservedSessionIdentity`'s deadline/yield poll (kept,
    /// unmodified, in `ZmxE2ETests.swift`, for that file's earlier
    /// inherited tests). `ZmxBackend.observeSessionIdentity` is a thin
    /// wrapper over the identical `ZmxSessionControl.observe(path:bootID:)`
    /// syscall `ZmxTestHarness.waitForSessionSocket`'s own real vnode watch
    /// already proves out for socket existence -- confirmed by reading
    /// `ZmxBackend.observeSessionIdentity` directly. Registers a watch on
    /// the same zmx directory, then retries the same four transient
    /// failures `waitForObservedSessionIdentity` already tolerates only on
    /// the next real event, never a sleep or a yield loop. Any other
    /// failure propagates immediately, exactly as the legacy helper's own
    /// uncaught case already does.
    ///
    /// Architecture lint follow-up (Lead 2026-10-01): merged with the former
    /// `awaitNextZmxDirectoryEvent` into this one function, renamed to match
    /// what it returns. `IndependentLeaderExecWitness`
    /// (`ZmxE2ETests+ForcedTiming.swift`) is the precedent this follows: the
    /// directory watch's event handler only sinks a fact through
    /// `LocalFactSource` (synchronous, never a Task, matching
    /// `FactRecorder.append`'s own "the owner calls this synchronously; it
    /// never creates a task" contract) -- no `HeldStep`, which parks its
    /// caller until a test-side `release()`/`fail()`/`retire()` and is not a
    /// one-shot event primitive, and no hand-built continuation. The retry
    /// loop (try the real check, then wait for the next event fact on a
    /// miss) stays entirely in this function's own async context: nothing
    /// async runs inside the GCD event handler. The session identity this
    /// loop was built to find IS the value that satisfies it, so this
    /// function returns it directly and every caller asserts on that
    /// returned identity.
    ///
    /// R2-4 item 3 (review round 2, Lead 2026-10-01): the FD-lifetime
    /// defect A4 already fixed once in production and this file's own
    /// `awaitAlreadyRunningProcessExit` never had -- a bare
    /// `defer { close(directoryFileDescriptor) }` races
    /// `eventSource.cancel()`'s asynchronous request (source.h:512) rather
    /// than running from its cancel handler, the SDK's own documented safe
    /// point.
    ///
    /// R2-5 item 2 (Lead decision 2026-10-02, option c): one of the four
    /// transient connect failures below means the socket file already
    /// exists -- `ZmxBackend.observeSessionIdentity` only returns `nil`
    /// while it's genuinely absent (confirmed by reading it directly:
    /// every one of these four is thrown only after that absence check
    /// already failed) -- so `listen`, `setsid` and process-readiness
    /// finishing do not necessarily produce another write/rename on this
    /// directory; waiting for the next directory event here could wait
    /// past a daemon that is already answering correctly. This function
    /// must not own its own retry loop for that gap, though: it calls
    /// `harness.waitUntilSessionSettled`, which already handles it through
    /// the identical backoff schedule `ColdStartObserver.attemptDiscoveryConnect`
    /// uses, via `resolveSettledDiscovery` -- the one
    /// architecture-debt-ledger-tracked polling instance left in
    /// `ZmxTestHarness.swift`, not a second one here. A transient failure
    /// that recurs on the one `observeSessionIdentity` attempt made right
    /// after settling is a real failure, propagated typed, not retried
    /// again. The directory watch itself is unchanged for the
    /// genuinely-absent case below: the socket file appearing IS a
    /// write/rename on this directory.
    ///
    /// N1 (advisor review round 2, Lead 2026-10-02): `backend` widened from
    /// the concrete `ZmxBackend` to `any ZmxSessionRestoreProbing` -- the
    /// protocol `observeSessionIdentity` is actually declared on, and the
    /// same one `resolveRecreationVerdictOffMain`
    /// (`WorkspaceSurfaceCoordinator+TerminalContentMounting.swift`) already
    /// takes -- purely so this function's own lifetime test can drive it
    /// with a held fake probe instead of a real zmx daemon. Every existing
    /// call site still passes a concrete `ZmxBackend`, which already
    /// conforms; no behavior change. `queue` and the two fact sinks are the
    /// same kind of seam (default global queue / no-op closures) already
    /// established by `ColdStartObserverTests.ScriptedSyscalls`'s own
    /// `directoryOpenCallFactSink`/`directoryCloseCallFactSink` pair --
    /// mirrored here rather than a new shape, so a test can learn the real
    /// descriptor number at open time and observe the real close instead of
    /// racing a queue-drain proxy for either (the same unsoundness
    /// `directoryDescriptorStaysOpenUntilCancellationCompletes`,
    /// `ColdStartObserverWatchSourceOwnershipTests.swift`, already found and
    /// fixed for the production observer).
    func awaitSessionIdentityOnRealEvent(
        _ sessionID: ZmxSessionID,
        harness: ZmxTestHarness,
        backend: any ZmxSessionRestoreProbing,
        zmxDirectory: String,
        queue: DispatchQueue = .global(qos: .userInitiated),
        directoryOpenFactSink: @escaping @Sendable (Int32) -> Void = { _ in },
        directoryCloseFactSink: @escaping @Sendable (Int32) -> Void = { _ in },
        // R3-3b (review round 3, Lead decision 2026-10-02): fires once this
        // function requests cancellation -- a no-op in production (default
        // `{}`). `dispatch_source_cancel` is non-blocking (source.h:512), so
        // this fact comes before the cancel handler can run. By itself it
        // does not prove safe descriptor lifetime; the lifetime test also
        // joins this wait's unwind while the target queue remains held.
        cancellationRequestedFactSink: @escaping @Sendable () -> Void = {}
    ) async throws -> Data {
        let directoryFileDescriptor = open(zmxDirectory, O_EVTONLY)
        guard directoryFileDescriptor >= 0 else { throw ZmxSessionControlFailure.unavailable }
        directoryOpenFactSink(directoryFileDescriptor)

        let scope = "zmxDirectoryEvent"
        let source = LocalFactSource(
            vocabulary: FactVocabulary<String, Void>(
                describeScope: { $0 },
                describeFact: { _ in "directory event" },
                // Never closing: the retry loop below may need more than one
                // directory-event fact before `backend.observeSessionIdentity`
                // finally succeeds, and nothing in this fact stream itself
                // marks the last one -- that decision is external to it. A
                // closing vocabulary here would make the second fact at this
                // scope a reported violation (FactRecorder's own
                // FactAfterClose), matching `IndependentLeaderExecWitness`'s
                // (ZmxE2ETests+ForcedTiming.swift) non-closing vocabulary for
                // the same reason.
                isClosing: { _, _ in false }
            )
        )
        let recorder = try source.attach()
        let sink = source.sink

        let eventSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFileDescriptor,
            eventMask: [.write, .rename],
            queue: queue
        )
        eventSource.setEventHandler {
            // A raw GCD callback on .global(), not inside a Swift Task;
            // LocalFactSource.sink is synchronous and safe here. Never
            // cancelled from inside the handler: this watch must keep
            // firing across every retry, not just the first.
            sink(scope, ())
        }
        // A4-shaped: closes the descriptor this source owns, exactly once,
        // only once cancellation has actually completed. The fact sink is
        // a no-op in production (default `{ _ in }`); N1's own test is the
        // only caller that supplies one, to observe the real close instead
        // of racing a queue-drain proxy for it (the same unsoundness
        // `directoryDescriptorStaysOpenUntilCancellationCompletes`,
        // `ColdStartObserverWatchSourceOwnershipTests.swift`, already
        // found and fixed for the production observer).
        eventSource.setCancelHandler {
            close(directoryFileDescriptor)
            directoryCloseFactSink(directoryFileDescriptor)
        }
        // A2 (advisor review round 2, Lead 2026-10-02): this function's own
        // loop below already checks `backend.observeSessionIdentity`
        // *before* ever parking on `recorder.expectNext`, so it is not
        // blind the way a bare synchronous-after-`resume()` check would be
        // -- but if the socket's creation write lands in the gap between
        // this `resume()` call and kernel registration actually completing
        // (SDK source.h:745), the kqueue event for it is never generated at
        // all, and once this loop *is* parked on `expectNext`, nothing else
        // would ever wake it to re-check. Firing the identical "directory
        // event" fact from the registration handler closes that gap: if the
        // loop is already parked, this wakes it to re-check now that
        // registration is confirmed; if it isn't parked yet, `expectNext`'s
        // own history scan (not a live race) still finds this fact later.
        // No new async machinery needed -- this mirrors `setEventHandler`'s
        // own closure exactly, just from the registration callback instead.
        eventSource.setRegistrationHandler {
            sink(scope, ())
        }
        eventSource.resume()
        defer {
            eventSource.cancel()
            cancellationRequestedFactSink()
        }

        while true {
            do {
                if let identity = try await backend.observeSessionIdentity(sessionID) {
                    return identity
                }
                // Genuinely absent, not a transient connect failure: the
                // socket file appearing is itself a write/rename on
                // `zmxDirectory`, so waiting for the next one is correct.
                _ = try await recorder.expectNext(in: scope, where: { _ in true }, "zmx directory event")
            } catch ZmxSessionControlFailure.unavailable, ZmxSessionControlFailure.connectionRefused,
                ZmxSessionControlFailure.processUnverifiable, ZmxSessionControlFailure.timeout
            {
                // The socket exists (that's the only way this catch is
                // reached), so the daemon simply isn't answering yet --
                // exactly the harness's own settle wait already handles.
                // No retry loop of this function's own: settle once, then
                // make exactly one more attempt. Thrown, not caught again,
                // if that attempt still fails transiently -- a transient
                // failure after settling is a real failure.
                try await harness.waitUntilSessionSettled(sessionId: sessionID.rawValue)
                if let identity = try await backend.observeSessionIdentity(sessionID) {
                    return identity
                }
                // Settled but still absent is not expected; fall back to
                // the same directory-event wait as the initial absence
                // case above.
                _ = try await recorder.expectNext(in: scope, where: { _ in true }, "zmx directory event")
            }
        }
    }

    /// The repo's own `awaitProcessExit` (`AgentStudioTestHarness/ProcessExitWait.swift`)
    /// isn't usable here -- it calls `process.run()` itself, and this call
    /// site's `process` is already running (started by
    /// `spawnColdRestoreSessionWithoutWaitingForSettlement`). `process.waitUntilExit()`
    /// spins the calling thread's run loop and exit delivery goes to the
    /// launching thread's -- the exact hazard `awaitProcessExit`'s own doc
    /// comment names, confirmed by reading it directly. This is that same
    /// function's await half only, minus the launch, against a process
    /// already in flight.
    ///
    /// Architecture lint follow-up (Lead 2026-10-01): register-then-check
    /// against a `LocalFactSource`/`FactRecorder` pair instead of a
    /// hand-built `CheckedContinuation`. `Process.terminationHandler` only
    /// sinks the exit status fact -- synchronous, never a Task -- and
    /// `recorder.expectNext(in:where:_:)` returns that fact's value
    /// directly, so the exit status IS what this wait returns. An
    /// already-exited process is reported straight from the synchronous
    /// check below, with no detour through the fact source at all.
    func awaitAlreadyRunningProcessExit(_ process: Process) async throws -> Int32 {
        let scope = "already-running process exit"
        let source = LocalFactSource(
            vocabulary: FactVocabulary<String, Int32>(
                describeScope: { $0 },
                describeFact: { "exit status \($0)" },
                isClosing: { _, _ in true }
            )
        )
        let recorder = try source.attach()
        let sink = source.sink

        process.terminationHandler = { exitedProcess in
            // Process.terminationHandler runs on an arbitrary queue, not
            // inside a Swift Task; LocalFactSource.sink is synchronous and
            // safe here.
            sink(scope, exitedProcess.terminationStatus)
        }
        // Register-then-check: the process may have already exited in the
        // gap between its caller spawning it and this call, and a handler
        // set after that exit is not guaranteed to fire for it.
        if !process.isRunning {
            process.terminationHandler = nil
            return process.terminationStatus
        }
        return try await withTaskCancellationHandler {
            try await recorder.expectNext(in: scope, where: { _ in true }, "process exit status")
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
