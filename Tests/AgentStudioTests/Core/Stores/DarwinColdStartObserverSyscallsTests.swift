import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Darwin cold start observer syscalls")
struct DarwinColdStartObserverSyscallsTests {
    // One argv element, with the executable path and its alignment padding.
    private static let startupBuffer: [UInt8] = [1, 0, 0, 0] + Array("/bin/sh\0\0/bin/sh\0".utf8)

    @Test("startup handoff recovers from a transient EINVAL through the production adapter")
    func startupRetriesTransientEINVAL() {
        // Arrange: the kernel can report EINVAL while the leader is mid-exec.
        let bytes = Self.startupBuffer
        let calls = ScriptedArgumentsSyscalls(
            sizes: [.success(24)], fetches: [.failure(POSIXErrorNumber(EINVAL)), .success(bytes.count)], bytes: bytes)
        let syscalls = DarwinColdStartObserverSyscalls(argumentsReader: ProcessArgumentsReader(syscalls: calls))

        // Act
        let result = syscalls.readProcessArgumentsBuffer(pid: 42)

        // Assert: D18 restores startup's retry-any-errno policy, without size queries.
        #expect(result == .success(bytes))
        #expect(calls.fetchCount == 2)
        #expect(calls.queryCount == 0)
        #expect(calls.maximumSizeQueryCount == 1)
        #expect(calls.requestedSizes == [64, 64])
    }

    @Test("startup handoff reads a complete snapshot without querying changing size metadata")
    func startupDoesNotQueryChangingSizeMetadata() {
        // Arrange: size-only responses would disagree across an exec; the data fetch is complete.
        let bytes = Self.startupBuffer
        let calls = ScriptedArgumentsSyscalls(
            sizes: [.success(24), .success(28)], fetches: [.success(bytes.count)], bytes: bytes)
        let syscalls = DarwinColdStartObserverSyscalls(argumentsReader: ProcessArgumentsReader(syscalls: calls))

        // Act
        let result = syscalls.readProcessArgumentsBuffer(pid: 42)

        // Assert: the known complete bytes are the oracle, independently of size metadata.
        #expect(result == .success(bytes))
        #expect(calls.fetchCount == 1)
        #expect(calls.queryCount == 0)
        #expect(calls.maximumSizeQueryCount == 1)
        #expect(calls.requestedSizes == [64])
    }

    @Test("startup handoff exhausts persistent EIO after exactly three maximum-capacity fetches")
    func startupPersistentEIOExhaustsBudget() {
        let calls = ScriptedArgumentsSyscalls(sizes: [.success(24)], fetches: [.failure(POSIXErrorNumber(EIO))])
        let syscalls = DarwinColdStartObserverSyscalls(argumentsReader: ProcessArgumentsReader(syscalls: calls))

        let result = syscalls.readProcessArgumentsBuffer(pid: 42)

        #expect(result == .failure(POSIXErrorNumber(EIO)))
        #expect(calls.fetchCount == 3)
        #expect(calls.queryCount == 0)
        #expect(calls.maximumSizeQueryCount == 1)
        #expect(calls.requestedSizes == [64, 64, 64])
    }

    @Test("startup handoff returns the last errno after retrying different failures")
    func startupExhaustionReturnsLastErrno() {
        let calls = ScriptedArgumentsSyscalls(
            sizes: [.success(24)],
            fetches: [
                .failure(POSIXErrorNumber(EIO)), .failure(POSIXErrorNumber(EINVAL)), .failure(POSIXErrorNumber(ESRCH)),
            ])
        let syscalls = DarwinColdStartObserverSyscalls(argumentsReader: ProcessArgumentsReader(syscalls: calls))

        let result = syscalls.readProcessArgumentsBuffer(pid: 42)

        #expect(result == .failure(POSIXErrorNumber(ESRCH)))
        #expect(calls.fetchCount == 3)
        #expect(calls.queryCount == 0)
        #expect(calls.requestedSizes == [64, 64, 64])
    }

    @Test("startup handoff uses the shared argument reader and preserves errno")
    func sharedArgumentReaderPreservesResult() {
        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        let calls = ScriptedArgumentsSyscalls(sizes: [.success(8)], fetches: [.success(7)], bytes: bytes)
        let syscalls = DarwinColdStartObserverSyscalls(argumentsReader: ProcessArgumentsReader(syscalls: calls))
        #expect(syscalls.readProcessArgumentsBuffer(pid: 42) == .success(bytes))
        let refused = ScriptedArgumentsSyscalls(sizes: [.success(8)], fetches: [.failure(POSIXErrorNumber(ESRCH))])
        let failed = DarwinColdStartObserverSyscalls(argumentsReader: ProcessArgumentsReader(syscalls: refused))
        #expect(failed.readProcessArgumentsBuffer(pid: 42) == .failure(POSIXErrorNumber(ESRCH)))
        #expect(refused.queryCount == 0)
        #expect(refused.fetchCount == 3)
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
