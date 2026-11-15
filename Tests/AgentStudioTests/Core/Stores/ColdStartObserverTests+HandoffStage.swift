import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// Handoff-stage group split out of `ColdStartObserverTests.swift` (Lead
/// 2026-10-02) purely for the repo's file-length ceiling -- same `@Suite`,
/// same type, via `extension`, so lane inventory and discovery are
/// unaffected. These three tests all exercise Stage 2's
/// `checkForHandoffAndAdvance` path specifically; `openRealDirectoryDescriptor`,
/// `makeFIFOPath`, `openFIFOForWriting`, and `closeFIFOWriteDescriptor`
/// stay in the original file (shared with tests that remained there) and
/// are called here across the split as internal, non-`private` members.
extension ColdStartObserverTests {
    /// Same `KERN_PROCARGS2` shape, carrying `argv` -- used where a test
    /// needs the token genuinely present (`tokenStillPresent`), not just an
    /// empty argv that can only ever read as absent.
    private func makeArgumentVectorBuffer(execPath: String = "/bin/example", argv: [String]) -> [UInt8] {
        var buffer = withUnsafeBytes(of: Int32(argv.count)) { Array($0) }
        buffer.append(contentsOf: Array(execPath.utf8))
        buffer.append(0)
        for argument in argv {
            buffer.append(contentsOf: Array(argument.utf8))
            buffer.append(0)
        }
        return buffer
    }

    /// Event-driven wait for a real process's own `NOTE_EXIT`, so a test can
    /// know for certain a leader has already exited before the observer
    /// ever looks at it -- never `Process.waitUntilExit()` (a blocking call
    /// off the cooperative pool) or a sleep. Returns the pid that exited,
    /// the observation that satisfied the wait.
    @discardableResult
    private func waitForRealProcessExit(pid: Int32) async throws -> Int32 {
        let step = HeldStep<Int32>("real process NOTE_EXIT")
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            source.cancel()
            // A raw GCD callback on .global(), not inside a Swift Task --
            // arriveBlocking's own contract for a synchronous seam reached
            // from a thread that may block.
            try? step.arriveBlocking(pid)
        }
        source.setCancelHandler {}
        source.resume()
        let exitedPID = try await step.firstArrival()
        step.release()
        return exitedPID
    }

    /// 2026-09-30 finding: `beginHandoffWatch`'s register-then-check
    /// immediate call hardcodes `exitFired: false` --
    /// `checkForHandoffAndAdvance(identity: identity, attemptID: attemptID,
    /// exitFired: false)`, right after `source.resume()`. Its own comment
    /// only accounts for "handoff may have already completed" (the
    /// token-absent case); it doesn't account for the leader having already
    /// exited before this watch even registers. When that happens, the argv
    /// read genuinely fails (observed for real against a zmx cold-restore
    /// leader that already exited: `EINVAL`, not the `ESRCH` a dead-process
    /// read might suggest), and `handoffChecked`'s `.unreadable` branch sees
    /// the hardcoded `false` and settles `.unobservable` instead of
    /// `.failed` -- even though the leader is provably, already dead.
    /// Reproduced deterministically here: the real process is confirmed
    /// exited (via a real `NOTE_EXIT` wait) before `observeColdStart` is
    /// even called, so the scripted `.unreadable` result can only be seen
    /// through the immediate check's hardcoded `exitFired: false` -- no
    /// later real event is what settles this.
    @Test(
        "a leader already exited before Stage 2 registers still settles failed, not unobservable, on an unreadable argv"
    )
    func leaderAlreadyExitedBeforeHandoffRegistrationSettlesFailedNotUnobservable() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-handoff-already-exited-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let processInputPipe = Pipe()
        var openPipeReadEnd: FileHandle? = processInputPipe.fileHandleForReading
        var openPipeWriteEnd: FileHandle? = processInputPipe.fileHandleForWriting
        defer {
            if let openPipeWriteEnd { try? openPipeWriteEnd.close() }
            if let openPipeReadEnd { try? openPipeReadEnd.close() }
        }
        let controlledProcess = Process()
        controlledProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        controlledProcess.arguments = ["-c", "read _"]
        controlledProcess.standardInput = processInputPipe
        controlledProcess.standardOutput = FileHandle.nullDevice
        controlledProcess.standardError = FileHandle.nullDevice
        try controlledProcess.run()
        let terminalPID = controlledProcess.processIdentifier
        // The child is blocked on its input pipe, so its incarnation remains
        // resolvable until the test closes the pipe's write end.
        let incarnation = try #require(ZmxSessionControl.currentIncarnation(forPID: terminalPID))
        if let pipeWriteEnd = openPipeWriteEnd {
            openPipeWriteEnd = nil
            try pipeWriteEnd.close()
        }
        try await waitForRealProcessExit(pid: terminalPID)
        if let pipeReadEnd = openPipeReadEnd {
            openPipeReadEnd = nil
            try pipeReadEnd.close()
        }

        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        let identity = ZmxSessionIdentity(
            version: 1,
            bootID: "test-boot-id",
            daemon: incarnation,
            terminalLeader: incarnation,
            processGroupID: incarnation.pid,
            sessionCreatedAt: 0
        )
        syscalls.observeSessionResults = [.identity(identity)]
        syscalls.processArgumentsResult = .failure(POSIXErrorNumber(EINVAL))
        syscalls.leaderStateResult = .exited
        let observer = ColdStartObserver(syscalls: syscalls)

        let outcome = await observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
    }

    /// The other half of the same amendment: an unreadable argv from a
    /// leader that's still genuinely alive (the same incarnation) must stay
    /// `.unobservable`, not become `.failed` just because it couldn't be
    /// read -- `leaderState` is what tells these two apart now.
    @Test("an unreadable argv from a leader that's still the same, alive incarnation settles unobservable")
    func unreadableArgvFromAStillAliveLeaderSettlesUnobservable() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-handoff-still-alive-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfIncarnation = try #require(ZmxSessionControl.currentIncarnation(forPID: selfPID))
        let identity = ZmxSessionIdentity(
            version: 1,
            bootID: "test-boot-id",
            daemon: selfIncarnation,
            terminalLeader: selfIncarnation,
            processGroupID: selfIncarnation.pid,
            sessionCreatedAt: 0
        )
        syscalls.observeSessionResults = [.identity(identity)]
        syscalls.processArgumentsResult = .failure(POSIXErrorNumber(EACCES))
        syscalls.leaderStateResult = .sameIncarnationAlive
        let observer = ColdStartObserver(syscalls: syscalls)

        let outcome = await observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        #expect(outcome == .unobservable(.processArgsUnreadable(errno: EACCES)))
    }

    /// The same defect could hit the *event* path too, not just the
    /// immediate post-registration check: a `NOTE_EXEC` event whose own
    /// argv read races a later exit. Held at a real FIFO so the leader-state
    /// swap below happens-before the real leader's own exec, and that
    /// exec's real `NOTE_EXEC` happens-before the check that must see the
    /// swapped values.
    ///
    /// F7 (review round 1): the swap used to follow `async let` directly,
    /// with no synchronization proving the observer's immediate check had
    /// already read the token-present value first -- so this test could
    /// pass via that immediate check settling it, never reaching the real
    /// `NOTE_EXEC` path it claims to prove. `processArgumentsCallFactSink`
    /// makes "the immediate check already read it" a fact this test waits
    /// on (`expectNext ... 1`) before swapping, so the swap is now
    /// guaranteed to happen strictly after that first read and strictly
    /// before the real leader's exec (gated behind the FIFO release below).
    @Test("an exec event whose own argv read races a later exit also settles failed, not just the immediate check")
    func execEventArgvReadRacingALaterExitSettlesFailed() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-handoff-event-race-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)
        let holdFIFOPath = try makeFIFOPath()
        defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }

        let attemptID = ColdRestoreAttemptID.generate()
        let controlledProcess = Process()
        controlledProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        controlledProcess.arguments = ["-c", "cat \(holdFIFOPath); exec /bin/sleep 300"]
        controlledProcess.standardOutput = FileHandle.nullDevice
        controlledProcess.standardError = FileHandle.nullDevice
        try controlledProcess.run()
        defer { controlledProcess.terminate() }
        let terminalPID = controlledProcess.processIdentifier
        let terminalIncarnation = try #require(ZmxSessionControl.currentIncarnation(forPID: terminalPID))

        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        let identity = ZmxSessionIdentity(
            version: 1,
            bootID: "test-boot-id",
            daemon: terminalIncarnation,
            terminalLeader: terminalIncarnation,
            processGroupID: terminalIncarnation.pid,
            sessionCreatedAt: 0
        )
        syscalls.observeSessionResults = [.identity(identity)]
        // The immediate post-registration check: the real leader is
        // genuinely still blocked on the FIFO, token present -- Stage 2
        // must wait here, not settle.
        syscalls.processArgumentsResult = .success(
            makeArgumentVectorBuffer(execPath: "/bin/sh", argv: [attemptID.startupToken]))
        let processArgumentsCallSource = LocalFactSource(
            vocabulary: ScriptedSyscalls.processArgumentsCallFactVocabulary())
        let processArgumentsCallRecorder = try processArgumentsCallSource.attach()
        syscalls.processArgumentsCallFactSink = processArgumentsCallSource.sink
        let observer = ColdStartObserver(syscalls: syscalls)

        async let outcome = observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: attemptID
        )

        // Wait for the immediate post-registration check's own read before
        // swapping -- a fact, not a guess about how far `async let` got.
        try await processArgumentsCallRecorder.expectNext(in: ScriptedSyscalls.processArgumentsScope, 1)

        // Swap before releasing: happens-before the real leader's own exec,
        // which happens-before the real NOTE_EXEC event this swap must be
        // visible to.
        syscalls.processArgumentsResult = .failure(POSIXErrorNumber(EINVAL))
        syscalls.leaderStateResult = .exited
        let writeDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
        try await closeFIFOWriteDescriptor(writeDescriptor)

        let settledOutcome = await outcome

        #expect(settledOutcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
        // The real NOTE_EXEC event's own check read the swapped values --
        // confirms this settled through the event path, not the immediate
        // check alone.
        #expect(syscalls.processArgumentsCallCount == 2)
    }
}
