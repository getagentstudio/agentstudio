import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AgentStudioCore

/// SR4, SR5; Program Design item 3, stage 2 (amended 2026-09-30): the retry
/// policy `DarwinColdStartObserverSyscalls.readProcessArgumentsBuffer(pid:)`
/// applies after `sysctl(KERN_PROCARGS2)` returns `EIO` -- an intermediate
/// exec racing the read, confirmed empirically against real zmx (30/30 EIO
/// occurrences, 30/30 recovered on the very next read). Exercises the
/// injectable retry loop directly, with a scripted single-read function, so
/// this proves the policy itself without a real process or a real `sysctl`
/// call -- the real syscall path is proven against real zmx in the E2E lane.
@Suite("Darwin cold start observer syscalls")
struct DarwinColdStartObserverSyscallsTests {
    @Test("an EIO read followed by a success returns the successful read's buffer")
    func eioReadFollowedBySuccessReturnsTheSuccessfulReadsBuffer() {
        // Arrange
        var callCount = 0
        let expectedBuffer: [UInt8] = [1, 2, 3]

        // Act
        let result = DarwinColdStartObserverSyscalls.readProcessArgumentsBuffer(
            pid: 4242,
            attempts: 3
        ) { _ in
            callCount += 1
            return callCount == 1 ? .failure(POSIXErrorNumber(EIO)) : .success(expectedBuffer)
        }

        // Assert
        #expect(callCount == 2)
        switch result {
        case .success(let buffer): #expect(buffer == expectedBuffer)
        case .failure: Issue.record("Expected the second, successful read to win")
        }
    }

    @Test("EIO on every attempt exhausts the retry budget and reports the last errno")
    func eioOnEveryAttemptExhaustsTheRetryBudgetAndReportsTheLastErrno() {
        // Arrange
        var callCount = 0

        // Act
        let result = DarwinColdStartObserverSyscalls.readProcessArgumentsBuffer(
            pid: 4242,
            attempts: 3
        ) { _ in
            callCount += 1
            return .failure(POSIXErrorNumber(EIO))
        }

        // Assert: exactly `attempts` calls -- no fourth attempt, no early exit.
        #expect(callCount == 3)
        switch result {
        case .success: Issue.record("Expected every attempt to fail")
        case .failure(let errorNumber): #expect(errorNumber.rawValue == EIO)
        }
    }

    @Test("a successful first read never retries")
    func aSuccessfulFirstReadNeverRetries() {
        // Arrange
        var callCount = 0
        let expectedBuffer: [UInt8] = [9]

        // Act
        let result = DarwinColdStartObserverSyscalls.readProcessArgumentsBuffer(
            pid: 4242,
            attempts: 3
        ) { _ in
            callCount += 1
            return .success(expectedBuffer)
        }

        // Assert
        #expect(callCount == 1)
        switch result {
        case .success(let buffer): #expect(buffer == expectedBuffer)
        case .failure: Issue.record("Expected the first read to succeed")
        }
    }

    /// `leaderState`'s "pid was recycled" branch: a real, alive process
    /// answers `proc_pidinfo` successfully, but a start time that doesn't
    /// match the discovered incarnation means the original leader is gone
    /// and this pid now belongs to someone else.
    @Test("proc_pidinfo succeeding against a real, alive process with a mismatched start time reads as exited")
    func mismatchedStartTimeOnARealAliveProcessReadsAsExited() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let bogusIncarnation = ZmxProcessIncarnation(pid: selfPID, startSeconds: 0, startMicroseconds: 0)

        let state = DarwinColdStartObserverSyscalls().leaderState(of: bogusIncarnation)

        #expect(state == .exited)
    }

    /// The real-zombie proof behind the whole amendment: `posix_spawn` a
    /// child that exits immediately and deliberately isn't reaped, wait for
    /// its real `NOTE_EXIT` (event-driven, not a sleep -- this is exactly
    /// when it becomes a zombie and stays one), then assert `leaderState`
    /// classifies it `.exited`. Always `waitpid`s before returning, even on
    /// failure, so a zombie never leaks out of this test.
    @Test("a real zombie -- exited but not yet reaped -- reads as exited")
    func aRealZombieReadsAsExited() async throws {
        let executablePath = "/bin/sh"
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(executablePath),
            strdup("-c"),
            strdup("exit 0"),
            nil,
        ]
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        var childPID: pid_t = 0
        let spawnStatus = posix_spawn(&childPID, executablePath, nil, nil, &argv, environ)
        try #require(spawnStatus == 0, "posix_spawn failed with status \(spawnStatus)")
        // Unconditional: runs on every exit from here, including a failed
        // #expect below, so a zombie never leaks out of this test.
        defer {
            var reapedStatus: Int32 = 0
            waitpid(childPID, &reapedStatus, 0)
        }

        // The real NOTE_EXIT: the child becomes a zombie exactly then, and
        // stays one (unreaped) until this test's own deferred waitpid above.
        let step = HeldStep<Void>("real zombie NOTE_EXIT")
        let source = DispatchSource.makeProcessSource(
            identifier: childPID, eventMask: .exit, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            source.cancel()
            try? step.arriveBlocking(())
        }
        source.setCancelHandler {}
        source.resume()
        try await step.firstArrival()
        step.release()

        let incarnation = ZmxProcessIncarnation(pid: childPID, startSeconds: 0, startMicroseconds: 0)
        let state = DarwinColdStartObserverSyscalls().leaderState(of: incarnation)

        #expect(state == .exited)
    }
}
