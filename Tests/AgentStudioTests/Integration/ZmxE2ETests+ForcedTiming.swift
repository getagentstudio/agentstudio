import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// S3's "forced-timing" zmx-e2e list (Program Design item 3): proof for
/// `ColdStartObserver`'s register-then-check idiom under orderings real
/// system timing won't reliably reproduce on its own. Every hold point here
/// is a real, blocking POSIX FIFO `cat` in the real cold-restore script
/// (`plan.replayFile`) or in a thin wrapper standing in for `plan
/// .zmxExecutable` -- never a sleep, never an `async let` race hoping for a
/// particular scheduling order. Opening a FIFO's write end blocks until its
/// reader has already opened it, so that open call is itself the
/// event-driven proof that the held process reached its hold point; no
/// polling, no timeout.
///
/// macOS's real `/bin/sh` re-execs itself once internally (bash's own
/// sh-compatibility startup) before running a `-c` script's body, and that
/// re-exec's argv still carries whatever was passed after the script string
/// -- confirmed for real here with a standalone `EVFILT_PROC` probe against
/// `/bin/sh -c "exec /bin/sleep 5" TOKEN` (two `NOTE_EXEC` events: the
/// first still carrying TOKEN, the second not), matching
/// `TerminalColdRestorePlan`'s own doc comment ("zmx's forked child,
/// `/bin/sh`, and any `/bin/sh`-into-`bash` re-exec" all carry the token
/// before the final `exec` replaces it).
extension E2ESerializedTests.ZmxE2ETests {
    /// One real exec/exit observation on a leader pid, read independently of
    /// `ColdStartObserver`'s own Stage 2 watch.
    private struct LeaderExecObservation: Equatable, Sendable {
        let tokenPresent: Bool
        let exited: Bool
    }

    /// Watches a real process's `EVFILT_PROC` `NOTE_EXEC`/`NOTE_EXIT`
    /// events on its own kqueue registration, separate from the real
    /// observer under test, so a test can assert on what the leader's argv
    /// looked like at each real exec without relying on the observer's own
    /// settlement as the only signal. Event-driven, through the typed-fact
    /// harness: the DispatchSource callback appends each observation to a
    /// `LocalFactSource` synchronously (matching `FactRecorder.append`'s own
    /// "the owner calls this synchronously; it never creates a task"
    /// contract), never a hand-built continuation queue.
    private final class IndependentLeaderExecWitness: @unchecked Sendable {
        private static let scope = "leaderExec"
        private let source: any DispatchSourceProtocol
        private let recorder: FactRecorder<String, LeaderExecObservation>

        init(terminalPID: Int32, startupToken: String) throws {
            let factSource = LocalFactSource(
                vocabulary: FactVocabulary<String, LeaderExecObservation>(
                    describeScope: { $0 },
                    describeFact: { "tokenPresent=\($0.tokenPresent) exited=\($0.exited)" },
                    isClosing: { _, fact in fact.exited }
                ))
            recorder = try factSource.attach()
            let sink = factSource.sink
            let source = DispatchSource.makeProcessSource(
                identifier: terminalPID, eventMask: [.exit, .exec], queue: .global(qos: .userInitiated))
            self.source = source
            source.setEventHandler {
                let exited = source.data.contains(.exit)
                let tokenPresent: Bool
                if exited {
                    tokenPresent = false
                } else {
                    let arguments = E2ESerializedTests.ZmxE2ETests.currentArgumentVector(forPID: terminalPID)
                    tokenPresent = arguments?.contains(startupToken) ?? false
                }
                sink(Self.scope, LeaderExecObservation(tokenPresent: tokenPresent, exited: exited))
            }
            source.setCancelHandler {}
            source.resume()
        }

        deinit {
            source.cancel()
        }

        /// Waits for the first definitive event: either the token gone (the
        /// real handoff exec) or the leader exiting. Registration can race
        /// macOS's own `/bin/sh`->bash internal re-exec -- if that fires as
        /// a live, separately-recorded fact before the exec this test cares
        /// about, consuming just the next fact would return that
        /// still-token-present observation instead. Draining past any such
        /// intermediate, still-token-present exec (each drain step its own
        /// `expectNext`, consuming exactly one fact) keeps the assertion on
        /// the one exec that actually matters, regardless of exactly when
        /// this witness happened to register relative to that internal
        /// re-exec.
        func waitForDefinitiveObservation() async throws -> LeaderExecObservation {
            while true {
                let observation = try await recorder.expectNext(
                    in: Self.scope, where: { _ in true }, "the next leader exec/exit observation")
                guard observation.tokenPresent, !observation.exited else {
                    return observation
                }
            }
        }
    }

    private static func currentArgumentVector(forPID pid: Int32) -> [String]? {
        switch DarwinColdStartObserverSyscalls().readProcessArgumentsBuffer(pid: pid) {
        case .success(let buffer):
            return ProcessArgumentsBufferParser.argumentVector(in: buffer)
        case .failure:
            return nil
        }
    }

    /// A thin wrapper standing in for `plan.zmxExecutable`: blocks reading
    /// `holdFIFOPath` (a `cat`, exactly like the production script's own
    /// `replayFile` hold), then `exec`s the real zmx binary with the exact
    /// arguments it was given, so the rest of the cold-restore flow runs
    /// completely unmodified once released. No socket, no daemon, no
    /// terminal leader exists at all while held -- zmx itself never ran.
    private func makeZmxHoldWrapperScript(realZmxPath: String, holdFIFOPath: String) throws -> String {
        let wrapperPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmx-hold-wrapper-\(UUIDv7.generate().uuidString)").path
        let scriptContent = """
            #!/bin/sh
            cat \(ZmxBackend.shellEscape(holdFIFOPath)) >/dev/null 2>&1
            exec \(ZmxBackend.shellEscape(realZmxPath)) "$@"
            """
        try scriptContent.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
        return wrapperPath
    }

    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): the exiting sibling of
    /// `makeZmxHoldWrapperScript` -- holds at the identical FIFO rendezvous,
    /// then exits instead of ever exec-ing into real zmx. No socket, no
    /// daemon, no `session "<id>" created` line can ever be produced by
    /// this process; it proves `waitUntilSessionSettled`'s launcher-exit
    /// race, not the "created" line side of it.
    private func makeExitingWithoutAttachingWrapperScript(holdFIFOPath: String) throws -> String {
        let wrapperPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmx-exit-wrapper-\(UUIDv7.generate().uuidString)").path
        let scriptContent = """
            #!/bin/sh
            cat \(ZmxBackend.shellEscape(holdFIFOPath)) >/dev/null 2>&1
            exit 1
            """
        try scriptContent.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
        return wrapperPath
    }

    /// S3 zmx-e2e list: "zmx held before socket creation while the mount
    /// completes -> no failure, then a normal handoff." `plan.zmxExecutable`
    /// is a wrapper blocked on its own FIFO, so the real zmx binary never
    /// runs while held -- no socket, no daemon exist at all. The observer
    /// registers its directory watch against that empty state; releasing
    /// the wrapper is what lets zmx run for the first time, so `.handedOff`
    /// is only reachable after release, proving the register-then-check
    /// discovery path survives starting with nothing to find yet.
    @Test("zmx held before the socket is created causes no false failure, then a normal handoff")
    func zmxHeldBeforeSocketCreationCausesNoFalseFailureThenANormalHandoff() async throws {
        try await withRealBackend { harness, _ in
            let realZmxPath = try #require(harness.zmxPath)
            let sessionID = ZmxSessionID.generateUUIDv7()
            let attemptID = ColdRestoreAttemptID.generate()
            let holdFIFOPath = try makeFIFOPath()
            defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }
            let wrapperPath = try makeZmxHoldWrapperScript(realZmxPath: realZmxPath, holdFIFOPath: holdFIFOPath)
            defer { try? FileManager.default.removeItem(atPath: wrapperPath) }

            let plan = TerminalColdRestorePlan(
                zmxExecutable: URL(fileURLWithPath: wrapperPath),
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                sessionID: sessionID,
                loginShell: URL(fileURLWithPath: "/bin/bash"),
                folderCandidates: [URL(fileURLWithPath: "/tmp")],
                notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
                replayFile: nil,
                resume: nil,
                attemptID: attemptID
            )
            let bootID = try await WorkspaceUndoJournalClock.current().bootID
            let socketPath = "\(harness.zmxDir)/\(sessionID.rawValue)"
            let observer = ColdStartObserver()

            // Not the settlement-waiting default: the wrapper is held
            // before it ever execs the real zmx, so no session could ever
            // settle while held.
            _ = try harness.spawnColdRestoreSessionWithoutWaitingForSettlement(plan: plan)

            // Register the real observer now, while the socket genuinely
            // does not exist -- the wrapper hasn't exec'd into zmx yet.
            async let outcome = observer.observeColdStart(
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                socketPath: socketPath,
                bootID: bootID,
                attemptID: attemptID
            )

            // Deterministic proof the wrapper has reached, and is blocked
            // at, its own hold point.
            let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
            #expect(
                !FileManager.default.fileExists(atPath: socketPath),
                "the socket must not exist while zmx itself is held before ever running")

            // Release: the wrapper execs the real zmx, which creates the
            // session normally from here.
            try await closeFIFOWriteDescriptor(writeDescriptor)

            let settledOutcome = await outcome
            #expect(settledOutcome == .handedOff)
        }
    }

    /// R1 gate 4, F7 fix (Lead decision 2026-10-02): the missing coverage
    /// the whole fix exists for -- a launcher that exits before ever
    /// printing its own `session "<id>" created` line used to hang
    /// `waitUntilSessionSettled` forever (R1 gate 3 on 4b71cd1a5); it must
    /// now surface as `SessionSettlementError.launcherExitedBeforeSessionCreated`
    /// instead. Same deterministic FIFO rendezvous as the test above --
    /// held, then released -- except the wrapper `exit 1`s instead of ever
    /// exec-ing into real zmx, so no socket, no daemon and no "created"
    /// line can ever exist for this session. Exercises `spawnZmxSession`'s
    /// own waiting path directly, through `ZmxTestHarness` -- no need for a
    /// `TerminalColdRestorePlan` since this is proving the launcher-exit
    /// race itself, not a cold-restore scenario.
    @Test("a launcher that exits before ever printing its own created line is a typed failure, not a hang")
    func aLauncherExitingBeforePrintingCreatedIsATypedFailureNotAHang() async throws {
        try await withRealBackend { harness, _ in
            let sessionID = ZmxSessionID.generateUUIDv7()
            let holdFIFOPath = try makeFIFOPath()
            defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }
            let wrapperPath = try makeExitingWithoutAttachingWrapperScript(holdFIFOPath: holdFIFOPath)
            defer { try? FileManager.default.removeItem(atPath: wrapperPath) }

            async let spawnAttempt = harness.spawnZmxSession(
                zmxPath: wrapperPath, sessionId: sessionID.rawValue, commandArgs: [])

            // Deterministic proof the wrapper has reached, and is blocked
            // at, its own hold point -- identical rendezvous to the held
            // test above.
            let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
            #expect(
                !FileManager.default.fileExists(atPath: "\(harness.zmxDir)/\(sessionID.rawValue)"),
                "no socket can exist yet: this wrapper never reaches real zmx")

            // Release: the wrapper exits instead of ever exec-ing into zmx.
            try await closeFIFOWriteDescriptor(writeDescriptor)

            do {
                _ = try await spawnAttempt
                Issue.record("expected the launcher's exit to surface a typed failure instead of settling")
            } catch ZmxTestHarness.SessionSettlementError.launcherExitedBeforeSessionCreated(let failedSessionId) {
                #expect(failedSessionId == sessionID.rawValue)
            } catch {
                Issue.record("expected launcherExitedBeforeSessionCreated, got \(error)")
            }

            // `withRealBackend`'s own cleanup assertion below this closure
            // is the proof that matters here: it calls `terminateSpawnedProcesses`
            // unconditionally, which both reaps this already-exited wrapper
            // and tears down its stdout reader -- a leaked process or a
            // reader left spinning would show up as a cleanup failure, not
            // as silence.
        }
    }

    /// S3 zmx-e2e list: "macOS `sh`->bash re-exec not treated as the
    /// handoff (the token survives it)." Holds the leader, already past
    /// macOS's own internal `/bin/sh`->bash re-exec (confirmed empirically:
    /// see this file's doc comment), at `cat plan.replayFile` -- a FIFO --
    /// before the script's only in-process `exec` into `loginShell`. While
    /// held, the leader's live argv still carries the token (a direct
    /// snapshot read, safe at any point before release since the script
    /// cannot reach its own final exec until released). Releasing lets that
    /// exec happen; the real observer can only settle `.handedOff` after
    /// it, and an independent `EVFILT_PROC` witness confirms the exact same
    /// exec dropped the token.
    @Test("macOS sh's internal re-exec still carries the startup token and is not mistaken for handoff")
    func macosShInternalReexecCarriesTheTokenAndIsNotMistakenForHandoff() async throws {
        try await withRealBackend { harness, _ in
            let zmxPath = try #require(harness.zmxPath)
            let sessionID = ZmxSessionID.generateUUIDv7()
            let attemptID = ColdRestoreAttemptID.generate()
            let holdFIFOPath = try makeFIFOPath()
            defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }

            let plan = TerminalColdRestorePlan(
                zmxExecutable: URL(fileURLWithPath: zmxPath),
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                sessionID: sessionID,
                loginShell: URL(fileURLWithPath: "/bin/bash"),
                folderCandidates: [URL(fileURLWithPath: "/tmp")],
                notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
                replayFile: URL(fileURLWithPath: holdFIFOPath),
                resume: nil,
                attemptID: attemptID
            )
            let bootID = try await WorkspaceUndoJournalClock.current().bootID
            let socketPath = "\(harness.zmxDir)/\(sessionID.rawValue)"
            let observer = ColdStartObserver()

            // The settlement-waiting default is fine here: settlement only
            // needs the daemon, socket, and setsid, none of which depend on
            // the script's own progress toward `cat`. Settlement already
            // proved the session discoverable, so this direct observe
            // succeeds immediately -- it's how spawnColdRestoreSession
            // itself found the leader pid, read a second time here to get
            // it back (its own return value is the spawned Process, not
            // the identity).
            _ = try await harness.spawnColdRestoreSession(plan: plan)
            let identity = try ZmxSessionControl.observe(path: socketPath, bootID: bootID)
            let witness = try IndependentLeaderExecWitness(
                terminalPID: identity.terminalLeader.pid, startupToken: attemptID.startupToken)

            async let outcome = observer.observeColdStart(
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                socketPath: socketPath,
                bootID: bootID,
                attemptID: attemptID
            )

            // Deterministic proof the leader has reached, and is blocked
            // at, `cat <replayFile>` -- past macOS's own sh-internal
            // re-exec, since the script body only starts running once sh
            // has fully finished its own startup.
            let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
            let heldArguments = try #require(
                E2ESerializedTests.ZmxE2ETests.currentArgumentVector(forPID: identity.terminalLeader.pid))
            #expect(
                heldArguments.contains(attemptID.startupToken),
                "the token must still be present while held before the script's own final exec")

            // Release: `cat` sees EOF, and the script's only in-process
            // exec into loginShell follows. The real observer cannot settle
            // .handedOff until after that exec actually replaces the
            // token-carrying argv -- it cannot get there earlier, so this
            // is proof by construction, not by timing luck.
            try await closeFIFOWriteDescriptor(writeDescriptor)

            let settledOutcome = await outcome
            #expect(settledOutcome == .handedOff)

            // Confirm independently, off the real observer's own path, that
            // the very next real exec on this pid is the one that drops the
            // token.
            let finalExecObservation = try await witness.waitForDefinitiveObservation()
            #expect(finalExecObservation == LeaderExecObservation(tokenPresent: false, exited: false))
        }
    }

    /// S3 zmx-e2e list: "a handoff before registration, caught by the
    /// check." Holds the leader at the same `replayFile` FIFO, releases it,
    /// and waits -- event-driven, on an independent `EVFILT_PROC` witness,
    /// never a sleep -- until the leader's own token-dropping exec has
    /// already happened for real. Only then does it construct and start the
    /// real observer. `beginHandoffWatch`'s immediate synchronous check
    /// right after registering (not a later event, since none will ever
    /// come: the leader has already reached its long-lived final shell) is
    /// the only thing that can possibly catch this handoff -- if that
    /// register-then-check were missing or broken, this settles nothing and
    /// the test times out against the lane's hang bound rather than passing
    /// by accident.
    @Test("a handoff that already happened before the observer registers is still caught by its own check")
    func aHandoffAlreadyDoneBeforeTheObserverRegistersIsStillCaughtByItsOwnCheck() async throws {
        try await withRealBackend { harness, _ in
            let zmxPath = try #require(harness.zmxPath)
            let sessionID = ZmxSessionID.generateUUIDv7()
            let attemptID = ColdRestoreAttemptID.generate()
            let holdFIFOPath = try makeFIFOPath()
            defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }

            let plan = TerminalColdRestorePlan(
                zmxExecutable: URL(fileURLWithPath: zmxPath),
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                sessionID: sessionID,
                loginShell: URL(fileURLWithPath: "/bin/bash"),
                folderCandidates: [URL(fileURLWithPath: "/tmp")],
                notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
                replayFile: URL(fileURLWithPath: holdFIFOPath),
                resume: nil,
                attemptID: attemptID
            )
            let bootID = try await WorkspaceUndoJournalClock.current().bootID
            let socketPath = "\(harness.zmxDir)/\(sessionID.rawValue)"

            _ = try await harness.spawnColdRestoreSession(plan: plan)
            let identity = try ZmxSessionControl.observe(path: socketPath, bootID: bootID)
            let witness = try IndependentLeaderExecWitness(
                terminalPID: identity.terminalLeader.pid, startupToken: attemptID.startupToken)

            let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
            try await closeFIFOWriteDescriptor(writeDescriptor)

            // Event-driven wait for the real, independent proof that the
            // handoff exec has already happened -- no observer exists yet.
            let finalExecObservation = try await witness.waitForDefinitiveObservation()
            #expect(finalExecObservation == LeaderExecObservation(tokenPresent: false, exited: false))

            // Only now construct and start the observer: the handoff is
            // already done, so beginHandoffWatch's immediate check right
            // after registering is the only path that can settle this.
            let observer = ColdStartObserver()
            let settledOutcome = await observer.observeColdStart(
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                socketPath: socketPath,
                bootID: bootID,
                attemptID: attemptID
            )
            #expect(settledOutcome == .handedOff)
        }
    }
}
