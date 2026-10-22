import AgentStudioTestHarness
import Darwin
import Foundation

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// `ZmxTestHarness`'s session-settlement waits, split into their own file
/// (the repo's line-length ceiling, same precedent as
/// `ZmxE2ETests+RealEventWaits.swift`/`ZmxE2ETests+ForcedTiming.swift`):
/// `waitForSessionSocket`/`awaitSessionSocketEvent` (the general
/// socket-appearance/disappearance watch every test body also calls
/// directly) and `waitUntilSessionSettled`/`awaitSessionCreatedLineOrLauncherExit`/
/// `resolveSettledDiscovery`/`resolveViaSetsidWatch` (the settlement path
/// `spawnZmxSession`/`spawnColdRestoreSession` use: a fast-path reconnect
/// check, then -- only for a genuine fresh create -- the launcher's own
/// "created" line raced against it exiting first, then exactly one
/// identity-discovery check). Everything else -- construction,
/// environment, spawning, cleanup -- stays in `ZmxTestHarness.swift`.
extension ZmxTestHarness {
    /// F7 residual (advisor review round 2, Lead 2026-10-02): `open(2)`
    /// failing on `zmxDir` used to fall back to a deadline poll -- the
    /// owner's rule bans deadline polling in tests outright, and having no
    /// event source available is not an exemption. There is nothing to
    /// register a real watch against in that case, so the honest test
    /// behavior is to fail immediately with the real cause
    /// (`SessionSettlementError.sessionDirectoryUnwatchable`), not poll
    /// hoping the directory becomes openable. No deadline/timeout
    /// parameter remains on this function at all.
    ///
    /// R3-N1 hard cutover (advisor round 3, Lead decision 2026-10-02): this
    /// used to also accept `racingAgainstExitOf`, racing the watch below
    /// against a named launcher's own exit (R1 gate 3). F7's redesign gave
    /// `waitUntilSessionSettled` its own dedicated created-line-vs-exit
    /// race instead, so nothing calls this with that parameter anymore
    /// (confirmed: every caller, including every direct test-body use of
    /// this function, passes only `sessionId`/`exists`). Removed rather
    /// than carried as dead code -- it also carried the exact lost-wakeup
    /// R3-N1 found (a confirmed exit whose socket state happened to match
    /// recorded nothing, trusting the file watch to settle a state that
    /// could still change again before that watch ran).
    func waitForSessionSocket(
        sessionId: String,
        exists expectedExists: Bool
    ) async throws -> Bool {
        let sessionSocketPath = sessionSocketPath(for: sessionId)
        if FileManager.default.fileExists(atPath: sessionSocketPath) == expectedExists {
            return true
        }

        let directoryFileDescriptor = open(zmxDir, O_EVTONLY)
        guard directoryFileDescriptor >= 0 else {
            throw SessionSettlementError.sessionDirectoryUnwatchable(path: zmxDir, errno: errno)
        }
        // R2-4 item 2 (review round 2, Lead 2026-10-01): ownership of this
        // descriptor passes to `awaitSessionSocketEvent`, which now closes
        // it from its own dispatch source's cancel handler -- the SDK's
        // documented safe boundary (source.h:449), matching A4's own
        // `closeWatchedDirectory`-from-cancel-handler shape in production.
        // A bare `defer` here would close it the instant that call
        // returns, which is not the same moment: `dispatch_source_cancel`
        // only requests cancellation (source.h:512), so this scope's own
        // close could race the source's still-in-flight teardown.
        return await awaitSessionSocketEvent(
            fileDescriptor: directoryFileDescriptor,
            sessionSocketPath: sessionSocketPath,
            exists: expectedExists
        )
    }

    /// Blocks until a freshly spawned session's terminal leader has
    /// completed `setsid()`, using the exact production discovery mechanism
    /// (`ZmxSessionControl.observeForDiscovery`, backed off on a refused
    /// connect, and an `EVFILT_PROC NOTE_EXEC` watch when setsid hasn't
    /// landed yet) rather than a sleep or a retry-until poll loop --
    /// mirroring `ColdStartObserver.attemptDiscoveryConnect` and
    /// `beginSetsidWatch`. `spawnZmxSession` and `spawnColdRestoreSession`
    /// call this before returning, so every zmx-e2e test that spawns
    /// through them starts from a session whose leader is already past the
    /// setsid race window.
    ///
    /// R2-5 item 2 (Lead decision 2026-10-02, option c): widened from
    /// `private` so `ZmxE2ETests+RealEventWaits.swift`'s
    /// `awaitSessionIdentityOnRealEvent` can reuse this exact settle wait
    /// for its own transient-connect-failure case, instead of its own
    /// polling loop.
    ///
    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): the fast path stays
    /// first and is unchanged -- a socket already on disk means some
    /// earlier launcher already created this session, so this call is a
    /// reconnect, not a creation, and there is no "created" line of its
    /// own to ever wait for (`aLiveSessionReconnectedThroughTheFallbackScriptStaysUnchanged`,
    /// ZmxE2ETests.swift, is exactly this case). Only when the socket does
    /// not exist yet does this race `sessionCreatedStep` (armed by
    /// `beginDrainingStandardOutput` at spawn time) against
    /// `zmxLauncherProcessID` exiting first, inline below rather than
    /// through a separate `await…`-named helper -- `TestWaitHelperReturnsObservationRule`
    /// requires exactly this: a wait with nothing of its own to return folds
    /// into the one function whose return value (`ZmxSessionIdentity`) the
    /// caller actually asserts on. Both `nil` (the default) means there is
    /// no launcher of this call's own to wait on at all, matching every
    /// caller that reuses this settle wait on an already-existing session
    /// (`RealEventWaits`' retry case), which the fast path above already
    /// covers in the ordinary case.
    @discardableResult
    func waitUntilSessionSettled(
        sessionId: String,
        zmxLauncherProcessID: Int32? = nil,
        sessionCreatedStep: HeldStep<Result<Void, any Error>>? = nil
    ) async throws -> ZmxSessionIdentity {
        let socketPath = sessionSocketPath(for: sessionId)
        if !FileManager.default.fileExists(atPath: socketPath) {
            guard let zmxLauncherProcessID, let sessionCreatedStep else {
                throw SessionSettlementError.socketNeverAppeared(sessionId: sessionId)
            }
            // Register-then-check, exactly like `resolveViaSetsidWatch`
            // below and bfe1253ea/6c718ad85's identical fix in
            // `awaitSessionSocketEvent`: the exit event is the fact once it
            // fires -- not the launcher's reaped status, which races
            // Foundation's own `Process` reaping it on an unrelated
            // handler. `kill(pid, 0)` ESRCH is only the mandatory initial
            // check's own fallback, for a launcher already gone (and
            // possibly already reaped) before this watch registered to see
            // a real exit event for it.
            let source = DispatchSource.makeProcessSource(
                identifier: zmxLauncherProcessID, eventMask: [.exit], queue: DispatchQueue.global(qos: .userInitiated)
            )
            func launcherConfirmedGone(exitFired: Bool) -> Bool {
                if exitFired { return true }
                return kill(zmxLauncherProcessID, 0) != 0 && errno == ESRCH
            }
            func checkAndSettleIfLauncherGone(exitFired: Bool) {
                guard launcherConfirmedGone(exitFired: exitFired) else { return }
                source.cancel()
                try? sessionCreatedStep.arriveBlocking(
                    .failure(SessionSettlementError.launcherExitedBeforeSessionCreated(sessionId: sessionId)))
            }
            source.setEventHandler { checkAndSettleIfLauncherGone(exitFired: source.data.contains(.exit)) }
            source.setCancelHandler {}
            source.setRegistrationHandler { checkAndSettleIfLauncherGone(exitFired: false) }
            source.resume()
            defer { source.cancel() }

            let outcome = try await sessionCreatedStep.firstArrival()
            sessionCreatedStep.release()
            try outcome.get()
        }
        let bootID = try await WorkspaceUndoJournalClock.current().bootID
        return try await resolveSettledDiscovery(socketPath: socketPath, bootID: bootID)
    }

    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): no retry, no sleep, no
    /// backoff. `waitUntilSessionSettled`'s own caller already proved the
    /// daemon listening by the time this runs -- either the socket already
    /// existed (a reconnect: `createSocket` runs before any fork,
    /// vendor/zmx/src/loop.zig:741) or this call's own launcher printed its
    /// "session created" line, which cannot happen before `createSocket`'s
    /// `bind`+`listen` (socket.zig:113-114, loop.zig:763-777) already
    /// succeeded. `.connectionRefused` (the bind-before-listen gap this
    /// file's own prior tolerance was written for) is therefore
    /// structurally impossible by the time this runs. Every other transient
    /// failure (`.timeout`, `.unavailable`, `.processUnverifiable`) is not
    /// retried here either, matching production's own policy exactly:
    /// `ColdStartObserver.attemptDiscoveryConnect` (ColdStartObserver.swift:280-315)
    /// only ever retries `.connectionRefused` -- every other failure falls
    /// straight through to `discoverySettled(identity: nil, ...)`, no
    /// retry. A red run here is diagnosed at its owner, the same as any
    /// other suite failure; no budget or retry count is added just to make
    /// one pass, and the zmx lane is opt-in, not a PR gate. If
    /// `test_orphanDiscovery_findsUntrackedSession` (two concurrent daemon
    /// spawns, ZmxE2ETests.swift) ever reproduces the `.timeout` this
    /// file's deleted retry once tolerated, that is evidence for a
    /// production deadline decision, not a reason to retry here.
    private func resolveSettledDiscovery(socketPath: String, bootID: String) async throws -> ZmxSessionIdentity {
        switch ZmxSessionControl.observeForDiscovery(path: socketPath, bootID: bootID) {
        case .identity(let identity):
            return identity
        case .pendingSetsid(let terminalPID):
            return try await resolveViaSetsidWatch(terminalPID: terminalPID, socketPath: socketPath, bootID: bootID)
        case .terminalLeaderGone:
            throw SessionSettlementError.terminalLeaderConfirmedGone
        case .failure(let failure):
            throw failure
        }
    }

    /// Register-then-check, exactly like `ColdStartObserver
    /// .beginSetsidWatch`/`checkForSetsidAndAdvance`: the leader can
    /// complete setsid and exec between the `.pendingSetsid` observation
    /// above and this registration, so the mandatory initial check must
    /// run only once kernel registration is confirmed complete, not
    /// synchronously after `resume()` returns on the caller's own Task.
    ///
    /// R2-4 item 2 (review round 2, Lead 2026-10-01): the prior shape ran
    /// that initial check synchronously right after `resume()`, which only
    /// requests registration -- the SDK's own contract (source.h:745) says
    /// the registration handler fires "once the corresponding kevent() has
    /// been registered with the system, following the initial
    /// dispatch_resume()". A transition landing in the gap between
    /// `resume()` returning and kernel registration actually completing
    /// could be missed by both: the kqueue wasn't registered yet to catch
    /// it as an edge, and the synchronous check had already read "still
    /// pending." Setting `setRegistrationHandler` before `resume()`, and
    /// running the same check from it, closes that gap -- the same one F1
    /// fixed in production. Both the event handler and the registration
    /// handler now run on this source's own GCD queue and may call
    /// `arriveBlocking` directly; there is no longer a separate
    /// caller's-Task code path.
    private func resolveViaSetsidWatch(
        terminalPID: Int32,
        socketPath: String,
        bootID: String
    ) async throws -> ZmxSessionIdentity {
        // `HeldStep` itself already guarantees only the first arrival is
        // returned by `firstArrival()` -- a later arrival is simply
        // recorded and ignored, so the former hand-kept `SettlementGate`
        // added nothing `HeldStep` doesn't already provide.
        let step = HeldStep<Result<ZmxSessionIdentity, any Error>>(
            "zmx setsid watch settlement")
        let source = DispatchSource.makeProcessSource(
            identifier: terminalPID,
            eventMask: [.exit, .exec],
            queue: DispatchQueue.global(qos: .userInitiated)
        )

        // Pure: nil means "not settled yet, stays armed." Shared by the
        // registration handler's mandatory initial check and the event
        // handler's later re-checks -- both now run on this source's own
        // GCD queue, never on the caller's Task.
        func outcome(exitFired: Bool) -> Result<ZmxSessionIdentity, any Error>? {
            if exitFired {
                return .failure(SessionSettlementError.terminalLeaderExitedBeforeSetsid(terminalPID: terminalPID))
            }
            switch ZmxSessionControl.observeForDiscovery(path: socketPath, bootID: bootID) {
            case .identity(let identity):
                return .success(identity)
            case .pendingSetsid:
                return nil  // not settled yet; the watch stays armed for the next event
            case .terminalLeaderGone:
                return .failure(SessionSettlementError.terminalLeaderConfirmedGone)
            case .failure(let failure):
                return .failure(failure)
            }
        }

        // One shared check, called from both the event handler and the
        // registration handler -- mirroring `ColdStartObserver
        // .beginSetsidWatch`'s own `checkForSetsidAndAdvance` shape.
        // Idempotent: a settled source is already cancelled, so a harmless
        // re-entry from the other callback finds nothing left to check
        // (`outcome` would be called again, but `step.arriveBlocking` after
        // the first `firstArrival()` only records and is ignored).
        func checkAndSettleIfReady(exitFired: Bool) {
            guard let result = outcome(exitFired: exitFired) else { return }
            source.cancel()
            // A raw GCD callback on .global(), not inside a Swift Task.
            try? step.arriveBlocking(result)
        }

        source.setEventHandler {
            checkAndSettleIfReady(exitFired: source.data.contains(.exit))
        }
        source.setCancelHandler {}
        // The mandatory initial check: `exitFired: false` mirrors the event
        // handler's own shape for this call -- this firing carries no real
        // `NOTE_EXIT`, so an already-dead leader is still caught by
        // `ZmxSessionControl.observeForDiscovery`'s own `.terminalLeaderGone`
        // case inside `outcome`, not assumed from this call alone.
        source.setRegistrationHandler {
            checkAndSettleIfReady(exitFired: false)
        }
        source.resume()
        // R3-3 item 1 (review round 3, Lead decision 2026-10-02): the
        // socket sibling (`awaitSessionSocketEvent` above) already cancels
        // and releases unconditionally; this wait propagated a thrown
        // `firstArrival()` (task cancellation) straight past both,
        // leaking the still-armed source and never releasing the step.
        // `defer` runs on every exit from here, cancellation included --
        // cancelling an already-settled source is the documented no-op
        // every other register-then-check wait in this file already
        // relies on.
        defer {
            step.release()
            source.cancel()
        }

        let settled = try await step.firstArrival()
        return try settled.get()
    }

    /// F7 (review round 1): no more a timed race. A real-time `clock.sleep`
    /// racing the real vnode event made this return `false` ("never
    /// appeared") whenever the daemon was merely slow, not actually broken
    /// -- "wrapping a timeout in HeldStep does not change what determines
    /// its verdict." Register-then-check against the real event alone now;
    /// a socket that genuinely never appears is caught only by the suite's
    /// own runner-owned hang bound, which names this step
    /// ("session socket event") as what was awaited.
    ///
    /// R2-4 item 2 (review round 2, Lead 2026-10-01): the prior shape ran
    /// its "register-then-check" synchronously on the caller's own Task
    /// right after `resume()`, which only requests kernel registration
    /// (source.h:745) -- a transition landing in the gap before that
    /// registration actually completes could be missed by both the
    /// not-yet-armed kqueue and the already-run synchronous check. Moving
    /// the mandatory initial check into `setRegistrationHandler` closes
    /// that gap, mirroring `resolveViaSetsidWatch`'s identical fix above.
    /// The cancel handler now also owns closing `fileDescriptor` -- the
    /// caller (`waitForSessionSocket`) no longer does, for the same A4
    /// reasoning: only the cancel handler is the SDK's documented
    /// safe-to-close point (source.h:449).
    ///
    /// R3-N1 hard cutover (advisor round 3, Lead decision 2026-10-02): R1
    /// gate 3 once raced this against a named launcher's own exit (see
    /// `waitForSessionSocket`'s doc comment); removed along with that
    /// parameter, since nothing calls this with one anymore and it carried
    /// a real lost-wakeup -- a confirmed exit whose socket state happened
    /// to match recorded nothing, trusting this very watch to settle a
    /// state that could still change again (zmx deleting its own socket
    /// during shutdown/error cleanup, vendor/zmx/src/loop.zig:780,:834)
    /// before it ran.
    private func awaitSessionSocketEvent(
        fileDescriptor: Int32,
        sessionSocketPath: String,
        exists expectedExists: Bool
    ) async -> Bool {
        let step = HeldStep<Bool>("session socket event")
        let eventSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .userInitiated)
        )

        // Shared by the registration handler's mandatory initial check and
        // the event handler's later re-checks -- both run on this source's
        // own GCD queue, never on the caller's Task, so both may call
        // `arriveBlocking` directly. Idempotent: a settled source is
        // already cancelled, so a harmless re-entry from the other
        // callback finds nothing new to do.
        func checkAndSettleIfSocketReady() {
            guard FileManager.default.fileExists(atPath: sessionSocketPath) == expectedExists else { return }
            eventSource.cancel()
            // A raw GCD callback on .global(), not inside a Swift Task.
            try? step.arriveBlocking(true)
        }

        eventSource.setEventHandler {
            checkAndSettleIfSocketReady()
        }
        // A4-shaped: closes the descriptor this source owns, exactly once,
        // only once cancellation has actually completed.
        eventSource.setCancelHandler {
            close(fileDescriptor)
        }
        // The mandatory initial check, run once kernel registration is
        // confirmed complete -- not synchronously after `resume()` returns.
        eventSource.setRegistrationHandler {
            checkAndSettleIfSocketReady()
        }
        eventSource.resume()

        let result = (try? await step.firstArrival()) ?? false
        step.release()
        // Safety net, not the primary path: if `firstArrival()` returned
        // through external cancellation rather than a matched check above,
        // the source may still be live -- cancelling here is a no-op when
        // already cancelled, and still routes the descriptor's close
        // through the cancel handler either way.
        eventSource.cancel()
        return result
    }
}
