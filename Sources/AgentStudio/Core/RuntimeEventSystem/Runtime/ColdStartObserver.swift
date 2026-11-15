import AgentStudioInfrastructure
import Darwin
import Dispatch
import Foundation

/// Proves handoff or failure for one cold-restore attempt entirely from
/// OS-observable facts (SR4, SR5; Program Design revision 11, item 3). Two
/// register-then-check stages, each registering its kqueue-backed watch
/// before checking so no event between registration and check is missed.
/// "Register" means confirmed kernel registration (amended 2026-10-01, A2):
/// each stage's mandatory initial check runs from a
/// `dispatch_source_set_registration_handler` callback, not synchronously
/// after `resume()` — `resume()` only requests registration; a check run
/// synchronously right after it races a still-outstanding kevent()
/// registration and can lose an event with no later recovery, by design.
///
/// 1. **Discovery** — `EVFILT_VNODE` `NOTE_WRITE` on the zmx directory, then
///    checks whether the session's socket exists; on appearance, calls
///    `ZmxSessionControl.observe` for the new session's identity. A
///    `.connectionRefused` connect (zmx binds the socket's path before it
///    calls `listen`; amended 2026-09-30) retries on a short backoff rather
///    than settling — see `attemptDiscoveryConnect`. A `.pendingSetsid`
///    connect (the pty child hasn't called `setsid` yet; amended again
///    2026-09-30) registers `EVFILT_PROC` on the terminal pid and
///    re-observes at its next exec/exit — see `beginSetsidWatch`. A
///    `.terminalLeaderGone` connect (amended a third time 2026-09-30:
///    `ZmxSessionControl.processSnapshot`'s own zombie-misclassification fix,
///    stage 1's counterpart to stage 2's `ColdStartLeaderState`) settles
///    `.failed` directly — the terminal leader is positively confirmed dead,
///    not merely unverifiable.
/// 2. **Handoff** — `EVFILT_PROC` `NOTE_EXEC | NOTE_EXIT` on the identity's
///    terminal-leader pid, then reads its argument vector via
///    `KERN_PROCARGS2` (never the environment: macOS returns none to a
///    third-party reader for any process) and looks for the startup token
///    (`ColdRestoreAttemptID.startupToken`) among its elements. An
///    unreadable argv with no `NOTE_EXIT` on that same event (amended
///    2026-09-30) no longer assumes the leader is still alive: it classifies
///    the leader's own OS-reported state (`ColdStartObserverSyscalls
///    .leaderState`, `proc_pidinfo`-based, never `kill(pid, 0)` — measured
///    wrong against a real zombie) and settles `.failed` when that state is
///    `.exited` — covering both a leader that already exited before this
///    watch ever registered, and a `NOTE_EXEC` event whose own argv read
///    races a later exit — see `checkHandoff`/`handoffChecked`.
///
/// `reportAttachClientExited()` is a third, independent settlement path:
/// Ghostty's `showChildExited` action is the one event-driven fact present
/// whether the attach client dies during discovery (never creates a
/// socket) or after (Program Design item 3: "that exit is the failure
/// fact. No timer is involved."). It can fire at any point and always wins
/// once it does — the App/Features bridge that calls it owns resolving
/// which pending observer a given pane's exit belongs to.
///
/// One observer per attempt: `observeColdStart` may be called exactly once.
package actor ColdStartObserver {
    /// One handoff check's result: read the leader's current argv, then
    /// decide what it means. `unreadable` means the read itself failed
    /// (`sysctl` error or no argument vector returned) — whether that
    /// becomes `.failed` or `.unobservable` depends on whether `NOTE_EXIT`
    /// was also observed on this same event, or (amended 2026-09-30) on the
    /// leader's own OS-reported state read at the same time as the argv
    /// attempt: a leader that had already exited before this check even ran
    /// — no `NOTE_EXIT` on this particular call, since the exit happened
    /// before the watch registered, or is racing a `NOTE_EXEC` event's own
    /// argv read — still explains an unreadable argv exactly as a live
    /// `NOTE_EXIT` would.
    private enum HandoffCheckResult {
        case tokenAbsent
        case tokenStillPresent
        case unreadable(errno: Int32, leaderState: ColdStartLeaderState)
    }

    private let syscalls: any ColdStartObserverSyscalls
    /// A2/A3/A4 (test technique amendment, 2026-10-01): the target queue
    /// every watch's registration/event/cancel handler runs on. Private per
    /// observer, not the shared `DispatchQueue.global(qos: .userInitiated)`
    /// — production still gets `.userInitiated`-equivalent priority via the
    /// default's own `qos:`, but this observer's handlers no longer
    /// compete with unrelated work on a process-wide pool. Injectable so a
    /// test can `suspend()`/`resume()` it directly (a real, documented GCD
    /// primitive) to hold a handler deterministically, instead of
    /// saturating a shared queue or blocking a thread with a semaphore.
    private let targetQueue: DispatchQueue
    /// A3 (test technique, Lead 2026-10-01): creates the setsid/handoff
    /// process-watch source — injectable so a test can supply a double that
    /// records `resume()`/`cancel()`/handler installs, proving source
    /// ownership directly instead of through kernel or queue timing. See
    /// `ColdStartProcessWatchSource.swift`.
    private let processWatchSourceMaker: ColdStartProcessWatchSourceMaker
    /// R3-3 item 2 (review round 3, Lead decision 2026-10-02): owner-local
    /// typed facts, mirroring `TerminalActivityProjector`'s own `factSink`
    /// exactly -- `nil` in every production caller, no behavior change.
    /// Lets a test prove which guard actually ran instead of inferring it
    /// from timing. See `ColdStartObserverFacts.swift`.
    private let factSink: ColdStartObserverFactSink?
    private var settlementContinuation: CheckedContinuation<ColdStartOutcome, Never>?
    /// Set when `settle()` runs before `observeColdStart` ever started —
    /// `reportAttachClientExited()` is registered (via
    /// `ColdStartAttachExitBinding`) before the surface that could exit is
    /// even created, so a `showChildExited` racing ahead of this actor's own
    /// `observeColdStart` call is a real, expected ordering, not a bug.
    /// `observeColdStart` returns this immediately instead of waiting.
    private var preSettledOutcome: ColdStartOutcome?
    private var isSettled = false
    /// A3: set the moment this attempt commits to the handoff stage —
    /// independent of `isSettled`, so a discovery-stage callback that was
    /// already in flight (queued before the handoff watch took over) is
    /// inert even though the attempt hasn't fully settled yet.
    private var hasBegunHandoffWatch = false
    private var hasStartedObserving = false
    private var directoryDescriptor: Int32?
    private var directoryWatchSource: (any DispatchSourceProtocol)?
    private var processWatchSource: (any ColdStartProcessWatchSource)?

    package init(
        syscalls: any ColdStartObserverSyscalls = DarwinColdStartObserverSyscalls(),
        targetQueue: DispatchQueue = DispatchQueue(
            label: "com.agentstudio.coldStartObserver.watch", qos: .userInitiated),
        processWatchSourceMaker: @escaping ColdStartProcessWatchSourceMaker = defaultColdStartProcessWatchSourceMaker,
        factSink: ColdStartObserverFactSink? = nil
    ) {
        self.syscalls = syscalls
        self.targetQueue = targetQueue
        self.processWatchSourceMaker = processWatchSourceMaker
        self.factSink = factSink
    }

    /// Runs the full two-stage watch for one cold-restore attempt, returning
    /// the total outcome. Never called twice on the same instance.
    package func observeColdStart(
        zmxDirectory: URL,
        socketPath: String,
        bootID: String,
        attemptID: ColdRestoreAttemptID
    ) async -> ColdStartOutcome {
        precondition(!hasStartedObserving, "observeColdStart called more than once")
        hasStartedObserving = true
        if let preSettledOutcome {
            return preSettledOutcome
        }
        return await withCheckedContinuation { continuation in
            settlementContinuation = continuation
            beginDiscovery(zmxDirectory: zmxDirectory, socketPath: socketPath, bootID: bootID, attemptID: attemptID)
        }
    }

    /// SR5; Program Design item 3, "the surface's command exits before
    /// handoff, including while discovering": the App/Features bridge for
    /// Ghostty's `showChildExited` fact. Never inspects an exit status —
    /// Ghostty's own comment on macOS exit-code detection being unreliable
    /// applies here too — so any attach-client exit before handoff settles
    /// this window as failed, full stop.
    package func reportAttachClientExited() {
        settle(.failed(.exitedBeforeHandoff(exitStatus: nil)))
    }

    /// Retirement or activation cancellation (Program Design item 4):
    /// "removes its kqueue registrations and settles the slot." The
    /// returned outcome carries no meaning worth acting on — the caller
    /// already knows this ended because it retired the pane, not because
    /// the observer learned anything.
    package func cancel() {
        settle(.unobservable(.identityUnverifiable))
    }

    private func settle(_ outcome: ColdStartOutcome) {
        guard !isSettled else { return }
        isSettled = true
        teardownWatches()
        if let settlementContinuation {
            settlementContinuation.resume(returning: outcome)
            self.settlementContinuation = nil
        } else {
            preSettledOutcome = outcome
        }
    }

    private func teardownWatches() {
        // A4: the directory descriptor is closed by `directoryWatchSource`'s
        // own cancel handler (set at creation in `beginDiscovery`), not
        // here -- `dispatch_source_cancel` is asynchronous (source.h:512);
        // closing the descriptor before cancellation actually completes
        // permits its reuse while the source may still reference it
        // (source.h:449). This call only requests cancellation and drops
        // this actor's own reference.
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
        directoryDescriptor = nil
        processWatchSource?.cancel()
        processWatchSource = nil
    }

    // MARK: - Stage 1: discovery

    private func beginDiscovery(
        zmxDirectory: URL,
        socketPath: String,
        bootID: String,
        attemptID: ColdRestoreAttemptID
    ) {
        let descriptor: Int32
        switch syscalls.openDirectoryForWatching(path: zmxDirectory.path) {
        case .failure(let errorNumber):
            settle(.unobservable(.watchRegistrationFailed(errno: errorNumber.rawValue)))
            return
        case .success(let openedDescriptor):
            descriptor = openedDescriptor
        }
        directoryDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: targetQueue
        )
        source.setEventHandler { [weak self] in
            self?.checkForSocketAndAdvance(
                socketPath: socketPath, bootID: bootID, attemptID: attemptID, trigger: .directoryEvent)
        }
        // A4: closes the descriptor this source owns, exactly once, only
        // once cancellation has actually completed -- `dispatch_source
        // _cancel` is asynchronous (source.h:512); the cancel handler is
        // the SDK's own documented boundary for when the handle is safe to
        // close (source.h:449 warns that closing earlier permits the
        // descriptor's reuse while the source may still reference it).
        // Captures `descriptor` and `syscalls` directly, not `self
        // .directoryDescriptor` -- the actor's own property is already
        // niled out by the time this runs. R1 gate (Lead 2026-10-01):
        // routed through `syscalls.closeWatchedDirectory`, not a raw
        // `close(descriptor)`, so a test can observe the real close as a
        // typed fact instead of racing a queue drain against this same
        // asynchronous cancellation.
        let syscalls = self.syscalls
        source.setCancelHandler {
            syscalls.closeWatchedDirectory(descriptor)
        }
        // A2: the mandatory initial check must run once kernel registration
        // is actually confirmed complete, not merely after `resume()`
        // returns -- `resume()` only requests registration; the SDK's own
        // contract (source.h:745) says the registration handler is
        // submitted "once the corresponding kevent() has been registered
        // with the system, following the initial dispatch_resume()". Set
        // before `resume()`, so it always fires asynchronously once, never
        // inline: "if a source is already registered when the registration
        // handler is set, [it] will be invoked immediately" does not apply
        // here. The socket may already exist by the time registration
        // completes (or appear between completion and this firing — the
        // event handler fires again and re-checks harmlessly).
        source.setRegistrationHandler { [weak self] in
            self?.checkForSocketAndAdvance(
                socketPath: socketPath, bootID: bootID, attemptID: attemptID, trigger: .registration)
        }
        directoryWatchSource = source
        source.resume()
    }

    /// Runs wherever it's called from — the DispatchSource's own GCD queue,
    /// whether its registration handler (the mandatory initial check, once
    /// kernel registration is confirmed complete) or its event handler.
    /// Launches the connect attempt as its own task rather than blocking
    /// here, since a refused connect now retries with a real `Task.sleep`
    /// (see `attemptDiscoveryConnect`), which this `nonisolated` function
    /// itself cannot `await`.
    ///
    /// R3-3 item 2 (review round 3, Lead decision 2026-10-02): `trigger`
    /// names which callback this run came from and is posted unconditionally
    /// -- before the existence guard below, not after -- so a test can prove
    /// the registration handler's own mandatory check actually ran, even on
    /// a call where the socket does not exist yet. `self.factSink` is a
    /// `let`, read here the same way `self.syscalls`/`self.targetQueue`
    /// already are from this `nonisolated` function.
    nonisolated private func checkForSocketAndAdvance(
        socketPath: String,
        bootID: String,
        attemptID: ColdRestoreAttemptID,
        trigger: ColdStartSocketCheckTrigger
    ) {
        factSink?(.socketCheckRan(trigger))
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        Task {
            await self.attemptDiscoveryConnect(
                socketPath: socketPath, bootID: bootID, attemptID: attemptID, retryIndex: 0)
        }
    }

    /// Program Design item 3, stage 1, amended 2026-09-30: zmx binds the
    /// session socket's filesystem path before it calls `listen`
    /// (socket.zig:113-114), so a connect landing in that gap is refused,
    /// not queued, and no further kqueue directory event follows `listen`
    /// to re-trigger discovery -- the next-`NOTE_WRITE` idea doesn't work
    /// here. `.connectionRefused` retries on `AppPolicies.Restore
    /// .discoveryConnectRetryDelays`'s backoff instead. Exhausting every
    /// attempt still refused does NOT settle: the window stays discovering,
    /// resolved only by a later real fact -- `reportAttachClientExited()`,
    /// or a subsequent `observeSession` failure that isn't `.connectionRefused`
    /// reaching `discoverySettled`'s existing endpoint check.
    ///
    /// `@concurrent nonisolated` (SE-0461): escapes to the global concurrent
    /// executor for its blocking `syscalls.observeSession` call and its
    /// `Task.sleep` backoff, neither of which may run on this actor's own
    /// serial executor. Re-enters the actor only through `discoverySettled`.
    @concurrent nonisolated private func attemptDiscoveryConnect(
        socketPath: String,
        bootID: String,
        attemptID: ColdRestoreAttemptID,
        retryIndex: Int
    ) async {
        switch syscalls.observeSession(path: socketPath, bootID: bootID) {
        case .identity(let identity):
            await discoverySettled(identity: identity, socketPath: socketPath, attemptID: attemptID)
        case .pendingSetsid(let terminalPID):
            // Program Design item 3, stage 1, amended again 2026-09-30:
            // forkpty's child hasn't called setsid yet. This is still
            // discovering, not unobservable -- watch its own exec/exit
            // rather than the zmx directory (listen leaves no further
            // directory event to catch).
            await beginSetsidWatch(
                terminalPID: terminalPID, socketPath: socketPath, bootID: bootID, attemptID: attemptID)
        case .failure(.connectionRefused):
            let delaysMilliseconds = AppPolicies.Restore.discoveryConnectRetryDelays
            guard retryIndex < delaysMilliseconds.count else { return }
            let delayNanoseconds = UInt64(delaysMilliseconds[retryIndex]) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await attemptDiscoveryConnect(
                socketPath: socketPath, bootID: bootID, attemptID: attemptID, retryIndex: retryIndex + 1)
        case .terminalLeaderGone:
            // Proof of death (SR2; Stage 1's version of the zombie fix
            // ColdStartLeaderState already made for stage 2): the terminal
            // leader is positively confirmed dead, not merely unverifiable,
            // so this settles failed directly rather than going through
            // discoverySettled's endpoint-absence check -- the daemon
            // answered fine, the socket is still there.
            await self.settle(.failed(.exitedBeforeHandoff(exitStatus: nil)))
        case .failure:
            await discoverySettled(identity: nil, socketPath: socketPath, attemptID: attemptID)
        }
    }

    /// Program Design item 3, stage 1, amended again 2026-09-30: forkpty's
    /// child always calls `setsid` before its first exec, so this registers
    /// `EVFILT_PROC` `NOTE_EXEC | NOTE_EXIT` on the terminal pid `observe`
    /// couldn't yet validate, then re-observes -- register-then-check,
    /// exactly like discovery's own socket watch and stage 2's handoff
    /// watch. `NOTE_EXIT` firing before any successful observe means the
    /// leader died before ever becoming a session/group leader: failed, not
    /// unobservable.
    ///
    /// Not `private` (A3, Lead 2026-10-01): a dedicated test proves a late
    /// `.pendingSetsid` reaching here after settlement installs no watch by
    /// calling this directly after `cancel()`, rather than racing a real
    /// discovery call against settlement (see `ColdStartObserverTests`).
    package func beginSetsidWatch(
        terminalPID: Int32,
        socketPath: String,
        bootID: String,
        attemptID: ColdRestoreAttemptID
    ) {
        // A3: a late `.pendingSetsid` reaching here after this attempt has
        // already settled (or already committed to handoff through a
        // different, earlier discovery observation) must not install a new
        // watch -- nothing would ever cancel it.
        guard !isSettled, !hasBegunHandoffWatch else { return }
        // R2-1 (review round 2, Lead 2026-10-01): registration and a
        // directory event can each start an independent discovery connect,
        // and both can observe `.pendingSetsid` before either reaches
        // handoff -- each call here must not silently drop a still-active
        // predecessor's source. Cancel it first, matching the identical
        // line already in `beginHandoffWatch` below for the same reason.
        processWatchSource?.cancel()
        let source = processWatchSourceMaker(terminalPID, [.exit, .exec], targetQueue)
        source.setEventHandler { [weak self] exitFired in
            self?.checkForSetsidAndAdvance(
                terminalPID: terminalPID, socketPath: socketPath, bootID: bootID, attemptID: attemptID,
                exitFired: exitFired)
        }
        source.setCancelHandler {}
        // A2: the mandatory initial check must wait for confirmed kernel
        // registration (see `beginDiscovery`'s own comment for the SDK
        // contract) -- setsid (and the exec after it) may already have
        // completed by the time registration confirms. `exitFired: false`
        // here mirrors the event handler's own shape: this firing carries
        // no real `NOTE_EXIT`, so an already-dead leader is caught by
        // `syscalls.observeSession`'s own `.terminalLeaderGone` case below,
        // not assumed from this call alone.
        source.setRegistrationHandler { [weak self] in
            self?.checkForSetsidAndAdvance(
                terminalPID: terminalPID, socketPath: socketPath, bootID: bootID, attemptID: attemptID,
                exitFired: false)
        }
        processWatchSource = source
        source.resume()
    }

    /// Runs wherever it's called from — the DispatchSource's own GCD queue,
    /// whether its registration handler (the mandatory initial check) or
    /// its event handler — never on this actor's executor, matching
    /// `checkForSocketAndAdvance`'s reasoning.
    nonisolated private func checkForSetsidAndAdvance(
        terminalPID: Int32,
        socketPath: String,
        bootID: String,
        attemptID: ColdRestoreAttemptID,
        exitFired: Bool
    ) {
        if exitFired {
            // Direct settle, not discoverySettled's endpoint-absence check:
            // the socket already exists (that's how this reached
            // .pendingSetsid at all) -- it's the leader itself that died,
            // the exact fact reportAttachClientExited() and stage 2's own
            // exitFired branch already settle unconditionally.
            //
            // R2-1: routed through settleFromSetsidWatch, not settle
            // directly -- cancellation is asynchronous (A4's own reasoning,
            // applied to process sources too), so a callback already queued
            // on this source before beginHandoffWatch cancelled and
            // superseded it can still run after this attempt has moved on.
            // That queued callback must not fail an attempt whose real
            // handoff watch (a different source) may still succeed.
            Task { await self.settleFromSetsidWatch(.failed(.exitedBeforeHandoff(exitStatus: nil))) }
            return
        }
        switch syscalls.observeSession(path: socketPath, bootID: bootID) {
        case .identity(let identity):
            Task { await self.discoverySettled(identity: identity, socketPath: socketPath, attemptID: attemptID) }
        case .pendingSetsid:
            // Not yet -- the watch stays armed and re-checks on the next
            // exec/exit event, exactly like discovery's socket watch and
            // stage 2's handoff watch.
            break
        case .terminalLeaderGone:
            // The exec event that woke this watch carried no NOTE_EXIT, but
            // the re-observe found the leader already a confirmed-dead
            // zombie -- proof of death, same as attemptDiscoveryConnect's
            // own handling, not "not yet." R2-1: same superseded-callback
            // reasoning as the exitFired branch above.
            Task { await self.settleFromSetsidWatch(.failed(.exitedBeforeHandoff(exitStatus: nil))) }
        case .failure:
            // A genuinely different failure than the one that started this
            // watch (e.g. the endpoint disappeared underneath it): resolve
            // through the existing settlement logic rather than looping.
            Task { await self.discoverySettled(identity: nil, socketPath: socketPath, attemptID: attemptID) }
        }
    }

    /// R2-1 (review round 2, Lead 2026-10-01): the setsid stage's own
    /// version of `discoverySettled`'s superseded-callback guard above --
    /// `hasBegunHandoffWatch` is set the moment this attempt commits to
    /// handoff, independent of `isSettled`, so a setsid watch's own
    /// exit/failure callback that was already queued before that
    /// transition cannot fail an attempt whose handoff watch may still
    /// succeed.
    ///
    /// R3-3 item 2 (review round 3, Lead decision 2026-10-02): posts the
    /// disposition as the last step of whichever branch this guard takes --
    /// `.ignoredAsStale` is the closing fact a negative proof needs, since
    /// without it "nothing changed after the stale callback" is
    /// indistinguishable from "nothing has run yet".
    private func settleFromSetsidWatch(_ outcome: ColdStartOutcome) {
        guard !isSettled, !hasBegunHandoffWatch else {
            factSink?(.setsidSettlementProcessed(.ignoredAsStale))
            return
        }
        settle(outcome)
        factSink?(.setsidSettlementProcessed(.applied))
    }

    private func discoverySettled(
        identity: ZmxSessionIdentity?,
        socketPath: String,
        attemptID: ColdRestoreAttemptID
    ) {
        // A3: a superseded discovery-stage callback (e.g. the setsid
        // watch's own in-flight event, still queued when the handoff watch
        // already took over) must not re-enter here -- `hasBegunHandoffWatch`
        // is set the moment this attempt committed to handoff, independent
        // of `isSettled`, which only covers full settlement.
        guard !isSettled, !hasBegunHandoffWatch else { return }
        // A4: see `teardownWatches`'s own comment -- the cancel handler set
        // in `beginDiscovery` owns closing the descriptor, not this call.
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
        directoryDescriptor = nil

        guard let identity else {
            // "once the session was discovered, observe finds its endpoint
            // gone or refused" is proof (SR2); anything else `observe`
            // threw is a genuine "couldn't verify," distinguished by
            // whether the endpoint itself is still there.
            let endpointGone = (try? ZmxSessionControl.endpointIsAbsent(path: socketPath)) ?? false
            if endpointGone {
                settle(.failed(.exitedBeforeHandoff(exitStatus: nil)))
            } else {
                settle(.unobservable(.identityUnverifiable))
            }
            return
        }
        beginHandoffWatch(identity: identity, attemptID: attemptID)
    }

    // MARK: - Stage 2: handoff

    private func beginHandoffWatch(identity: ZmxSessionIdentity, attemptID: ColdRestoreAttemptID) {
        // A3: commit to handoff before anything else -- makes a superseded
        // discovery-stage callback that's already queued (e.g. the setsid
        // watch's own event, racing this call) inert via `discoverySettled`'s
        // own guard, and cancel the setsid watch's source before this
        // overwrites `processWatchSource`, so it stops delivering future
        // events and its ownership isn't silently dropped. Cancellation
        // itself is asynchronous (A4); this only disposes of the reference,
        // it does not guarantee no in-flight callback is already queued --
        // `hasBegunHandoffWatch` is what makes that queued callback inert.
        hasBegunHandoffWatch = true
        processWatchSource?.cancel()
        let terminalLeaderPid = identity.terminalLeader.pid
        let source = processWatchSourceMaker(terminalLeaderPid, [.exit, .exec], targetQueue)
        source.setEventHandler { [weak self] exitFired in
            self?.checkForHandoffAndAdvance(identity: identity, attemptID: attemptID, exitFired: exitFired)
        }
        source.setCancelHandler {}
        // A2: the mandatory initial check must wait for confirmed kernel
        // registration (see `beginDiscovery`'s own comment for the SDK
        // contract) -- handoff may already have completed between
        // discovering the identity and registration confirming.
        source.setRegistrationHandler { [weak self] in
            self?.checkForHandoffAndAdvance(identity: identity, attemptID: attemptID, exitFired: false)
        }
        processWatchSource = source
        source.resume()
    }

    /// Runs wherever it's called from — the DispatchSource's own GCD queue,
    /// whether its registration handler (the mandatory initial check) or
    /// its event handler — never on this actor's executor, matching
    /// `checkForSocketAndAdvance`'s reasoning.
    nonisolated private func checkForHandoffAndAdvance(
        identity: ZmxSessionIdentity,
        attemptID: ColdRestoreAttemptID,
        exitFired: Bool
    ) {
        let result = checkHandoff(terminalLeader: identity.terminalLeader, attemptID: attemptID)
        Task {
            await self.handoffChecked(identity: identity, checkResult: result, exitFired: exitFired)
        }
    }

    /// The leader-state read (amended 2026-09-30) runs here too, next to
    /// the argv read and on the same nonisolated executor — never inside
    /// the actor — so `HandoffCheckResult` always carries a complete
    /// answer. That completeness is what makes the order the two
    /// unstructured `Task`s (this check's own, and `settle`'s continuation
    /// resume) finish in stop mattering: nothing downstream needs a second
    /// syscall to decide.
    nonisolated private func checkHandoff(
        terminalLeader: ZmxProcessIncarnation, attemptID: ColdRestoreAttemptID
    ) -> HandoffCheckResult {
        switch syscalls.readProcessArgumentsBuffer(pid: terminalLeader.pid) {
        case .failure(let errorNumber):
            return .unreadable(errno: errorNumber.rawValue, leaderState: syscalls.leaderState(of: terminalLeader))
        case .success(let buffer):
            guard let arguments = ProcessArgumentsBufferParser.argumentVector(in: buffer) else {
                return .unreadable(errno: EINVAL, leaderState: syscalls.leaderState(of: terminalLeader))
            }
            return arguments.contains(attemptID.startupToken) ? .tokenStillPresent : .tokenAbsent
        }
    }

    private func handoffChecked(
        identity: ZmxSessionIdentity,
        checkResult: HandoffCheckResult,
        exitFired: Bool
    ) {
        guard !isSettled else { return }
        switch checkResult {
        case .tokenAbsent:
            // "the leader is alive, it is still the process from the
            // discovered session's identity (same pid and start time, so a
            // reused pid can't pass), and its arguments no longer carry
            // this attempt's token" — a successful, token-absent read wins
            // as handed off regardless of whether NOTE_EXIT also fired in
            // this same event: the token's absence already proves the exec
            // happened, even if the shell then exited immediately after.
            if ZmxSessionControl.currentIncarnation(forPID: identity.terminalLeader.pid) == identity.terminalLeader {
                settle(.handedOff)
            } else {
                settle(.unobservable(.identityUnverifiable))
            }
        case .tokenStillPresent:
            // Still pending unless the leader has also exited: another exec
            // (zmx's own forked child, /bin/sh's re-exec into bash) without
            // the token gone yet is normal — "no time-only failure" — so
            // this simply waits for the next EVFILT_PROC event.
            if exitFired {
                settle(.failed(.exitedBeforeHandoff(exitStatus: nil)))
            }
        case .unreadable(let errorNumber, let leaderState):
            // NOTE_EXIT explains an unreadable argv (the process is gone).
            // Amended 2026-09-30: when no NOTE_EXIT fired on this event —
            // including the immediate post-registration check, which never
            // carries a real one — the leader's own OS-reported state
            // decides instead of assuming still-alive. `.exited` covers a
            // leader that exited before this watch even registered, and a
            // NOTE_EXEC event whose own argv read raced a later exit.
            if exitFired {
                settle(.failed(.exitedBeforeHandoff(exitStatus: nil)))
            } else {
                switch leaderState {
                case .exited:
                    settle(.failed(.exitedBeforeHandoff(exitStatus: nil)))
                case .sameIncarnationAlive, .unverifiable:
                    settle(.unobservable(.processArgsUnreadable(errno: errorNumber)))
                }
            }
        }
    }
}
