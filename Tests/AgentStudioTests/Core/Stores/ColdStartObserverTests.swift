import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// SR4, SR5; Program Design item 3: `ColdStartObserver`'s total outcome and
/// its two settlement paths that don't need a real process or a real zmx
/// daemon -- `reportAttachClientExited()` racing an in-progress discovery,
/// and the `.unobservable` cases the plan explicitly sanctions injecting "at
/// the Darwin call boundary with a test double of the syscall wrapper only."
/// The real discovery/handoff paths against a real socket and a real
/// process are proven separately, with real zmx, in the E2E lane.
@Suite("Cold start observer")
struct ColdStartObserverTests {
    /// Not `private` (test-file split, Lead 2026-10-01): shared with
    /// `ColdStartObserverWatchSourceOwnershipTests`, which the repo's
    /// line-length ceiling split out of this file.
    final class ScriptedSyscalls: ColdStartObserverSyscalls, @unchecked Sendable {
        var directoryOpenResult: Result<Int32, POSIXErrorNumber> = .failure(POSIXErrorNumber(EACCES))
        var processArgumentsResult: Result<[UInt8], POSIXErrorNumber> = .failure(POSIXErrorNumber(ESRCH))
        /// Consulted only when `processArgumentsResult` is `.failure` and no
        /// `NOTE_EXIT` fired on that same check. Defaults to the same
        /// outcome the pre-2026-09-30 code always assumed (still alive,
        /// unreadable for some other reason) so a test that never touches
        /// this keeps its prior behavior.
        var leaderStateResult: ColdStartLeaderState = .sameIncarnationAlive
        /// Consumed one per `observeSession` call, in order; once exhausted,
        /// every further call repeats `observeSessionFallback`.
        var observeSessionResults: [ZmxDiscoveryObservation] = []
        /// `beginDiscovery`'s directory watch can (harmlessly, by design)
        /// fire more than once for the same socket appearance, calling
        /// `observeSession` more times than a test scripts -- default
        /// `.failure(.unavailable)` matches every test that doesn't expect
        /// extra calls; a test built around a redundant watch firing (e.g.
        /// `.pendingSetsid` re-checks) sets this to something that stays
        /// consistent with its own scripted sequence instead.
        var observeSessionFallback: ZmxDiscoveryObservation = .failure(.unavailable)
        /// Test-injected sink for "observeSession was called" facts, the
        /// call count as the fact value -- set this (via
        /// `ScriptedSyscalls.observeSessionCallFactVocabulary()` and a
        /// `LocalFactSource`) only in a test that needs to wait for a
        /// specific call count through the typed-fact harness, rather than
        /// a hand-built continuation waiter.
        var observeSessionCallFactSink: (@Sendable (String, Int) -> Void)?
        /// F7 (review round 1): the same technique as `observeSessionCallFactSink`,
        /// for a test that must prove a syscall swap happens strictly after a
        /// specific `readProcessArgumentsBuffer` call has already read the
        /// prior value -- not merely that the swap occurred at some point
        /// before settlement.
        var processArgumentsCallFactSink: (@Sendable (String, Int) -> Void)?

        private let lock = NSLock()
        private var callCount = 0
        private var processArgumentsReadCount = 0

        func openDirectoryForWatching(path: String) -> Result<Int32, POSIXErrorNumber> {
            lock.lock()
            directoryOpenCallCount += 1
            let count = directoryOpenCallCount
            lock.unlock()
            // Lead 2026-10-01 (R1 gate failure 1): fired synchronously, from
            // inside `beginDiscovery`'s own actor-isolated, non-suspending
            // body -- a test awaiting this fact before calling `cancel()`
            // is guaranteed the directory watch source already exists by
            // the time `cancel()` can even enter the actor, since the
            // actor's serial executor cannot interleave `cancel()`'s
            // request until this synchronous call stack either completes
            // or hits a real suspension point (it has none between here
            // and `source.resume()`).
            directoryOpenCallFactSink?(Self.directoryOpenScope, count)
            return directoryOpenResult
        }

        func closeWatchedDirectory(_ descriptor: Int32) {
            close(descriptor)
            lock.lock()
            directoryCloseCallCount += 1
            lock.unlock()
            // R1 gate (Lead 2026-10-01, FAIL 1 fix 1): `testQueue.sync {}`
            // only proves blocks enqueued before it ran have completed --
            // `dispatch_source_cancel`'s own deregistration (source.h:512)
            // happens on libdispatch's manager thread, so the cancel
            // handler's submission to the target queue is not ordered
            // against an unrelated `sync {}` issued around the same time.
            // This fact is fired from inside the real close call itself
            // (routed here instead of a raw `close(descriptor)` in
            // `ColdStartObserver`'s own cancel handler), so a test awaiting
            // it observes the real close, not a queue-drain proxy for it.
            directoryCloseCallFactSink?(Self.directoryCloseScope, descriptor)
        }

        /// F7 follow-up (Lead 2026-10-01, R1 gate failure 1): same
        /// technique as `processArgumentsCallFactSink`, for a test that
        /// must prove the directory watch source already exists -- not
        /// merely that `observeColdStart` was called -- before racing it
        /// against `cancel()`.
        var directoryOpenCallFactSink: (@Sendable (String, Int) -> Void)?
        private var directoryOpenCallCount = 0

        /// R1 gate (Lead 2026-10-01, FAIL 1 fix 1): the fact value is the
        /// closed descriptor itself, so a test can assert it matches the
        /// one it opened, not merely that some close happened.
        var directoryCloseCallFactSink: (@Sendable (String, Int32) -> Void)?
        private(set) var directoryCloseCallCount = 0

        static let directoryOpenScope = "openDirectoryForWatching"
        static let directoryCloseScope = "closeWatchedDirectory"

        /// The typed-fact vocabulary for `directoryCloseCallFactSink`.
        static func directoryCloseCallFactVocabulary() -> FactVocabulary<String, Int32> {
            FactVocabulary(
                describeScope: { $0 }, describeFact: { "closeWatchedDirectory fd=\($0)" },
                isClosing: { _, _ in true })
        }

        /// The typed-fact vocabulary for `directoryOpenCallFactSink`.
        static func directoryOpenCallFactVocabulary() -> FactVocabulary<String, Int> {
            FactVocabulary(
                describeScope: { $0 }, describeFact: { "openDirectoryForWatching call #\($0)" },
                isClosing: { _, _ in false })
        }

        func readProcessArgumentsBuffer(pid: Int32) -> Result<[UInt8], POSIXErrorNumber> {
            lock.lock()
            processArgumentsReadCount += 1
            let count = processArgumentsReadCount
            let result = processArgumentsResult
            lock.unlock()
            processArgumentsCallFactSink?(Self.processArgumentsScope, count)
            return result
        }

        static let processArgumentsScope = "readProcessArgumentsBuffer"

        /// The typed-fact vocabulary for `processArgumentsCallFactSink`.
        static func processArgumentsCallFactVocabulary() -> FactVocabulary<String, Int> {
            FactVocabulary(
                describeScope: { $0 }, describeFact: { "readProcessArgumentsBuffer call #\($0)" },
                isClosing: { _, _ in false })
        }

        func leaderState(of incarnation: ZmxProcessIncarnation) -> ColdStartLeaderState {
            leaderStateResult
        }

        func observeSession(path: String, bootID: String) -> ZmxDiscoveryObservation {
            lock.lock()
            let result = observeSessionResults.isEmpty ? observeSessionFallback : observeSessionResults.removeFirst()
            callCount += 1
            let count = callCount
            lock.unlock()
            // The owner calls the sink synchronously, at this call's own
            // serialization point -- matching FactRecorder.append's own
            // contract ("The owner calls this synchronously; it never
            // creates a task").
            observeSessionCallFactSink?(Self.observeSessionScope, count)
            return result
        }

        var observeSessionCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        var processArgumentsCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return processArgumentsReadCount
        }

        static let observeSessionScope = "observeSession"

        /// The typed-fact vocabulary for `observeSessionCallFactSink`: the
        /// scope is fixed (one channel per `ScriptedSyscalls` instance), the
        /// fact is the call count observed at that call.
        static func observeSessionCallFactVocabulary() -> FactVocabulary<String, Int> {
            FactVocabulary(
                describeScope: { $0 }, describeFact: { "observeSession call #\($0)" }, isClosing: { _, _ in false })
        }
    }

    /// A minimal, valid `KERN_PROCARGS2`-shaped buffer with `argc = 0` --
    /// `ProcessArgumentsBufferParser.argumentVector` parses it to an empty
    /// array, which never contains a startup token, without needing any
    /// argv strings encoded.
    private func makeEmptyArgumentVectorBuffer(execPath: String = "/bin/example") -> [UInt8] {
        var buffer = withUnsafeBytes(of: Int32(0)) { Array($0) }
        buffer.append(contentsOf: Array(execPath.utf8))
        buffer.append(0)
        return buffer
    }

    /// Not `private` (test-file split, Lead 2026-10-02): shared with
    /// `ColdStartObserverTests+HandoffStage.swift`'s own FIFO-held test --
    /// `private` is file-scoped and does not cross the split.
    func makeFIFOPath() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cold-start-observer-fifo-\(UUIDv7.generate().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return path
    }

    /// Blocks until the matching read end (`cat <fifo>`) has genuinely
    /// opened -- real POSIX rendezvous, not a timing guess. Offloaded off
    /// the cooperative pool since it's a real blocking syscall.
    ///
    /// Not `private` (test-file split, Lead 2026-10-02): shared with
    /// `ColdStartObserverTests+HandoffStage.swift`'s own FIFO-held test --
    /// `private` is file-scoped and does not cross the split.
    func openFIFOForWriting(atPath path: String) async throws -> Int32 {
        try await withoutBlockingCooperativePool {
            let descriptor = open(path, O_WRONLY)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        }
    }

    /// Not `private` (test-file split, Lead 2026-10-02): shared with
    /// `ColdStartObserverTests+HandoffStage.swift`'s own FIFO-held test --
    /// `private` is file-scoped and does not cross the split.
    func closeFIFOWriteDescriptor(_ descriptor: Int32) async throws {
        try await withoutBlockingCooperativePool {
            guard close(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    @Test("a directory-watch registration failure settles unobservable, carrying the injected errno")
    func registrationFailureSettlesUnobservable() async throws {
        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .failure(POSIXErrorNumber(EACCES))
        let observer = ColdStartObserver(syscalls: syscalls)

        let outcome = await observer.observeColdStart(
            zmxDirectory: URL(filePath: "/does/not/matter"),
            socketPath: "/does/not/matter/session",
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        #expect(outcome == .unobservable(.watchRegistrationFailed(errno: EACCES)))
    }

    /// R1 Stage 1 fix (2026-09-30), bullet 2 of its own test list: a
    /// positively-confirmed-dead terminal leader (`ZmxSessionControl
    /// .observeForDiscovery`'s `.terminalLeaderGone`, now that
    /// `processSnapshot` tells it apart from a genuinely unverifiable
    /// daemon) settles discovery `.failed` directly -- proof of death
    /// (SR2), never `.unobservable`, matching an absent endpoint's own
    /// standing in `discoverySettled`.
    @Test("a terminal leader positively confirmed dead settles failed, not unobservable")
    func terminalLeaderGoneSettlesFailed() async throws {
        // Arrange
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-terminal-leader-gone-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        // Pre-created: "register first, then check" means discovery must
        // already find this socket path present the moment it starts.
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        syscalls.observeSessionResults = [.terminalLeaderGone]
        let observer = ColdStartObserver(syscalls: syscalls)

        // Act
        let outcome = await observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        // Assert
        #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
        #expect(syscalls.observeSessionCallCount == 1)
    }

    @Test("reportAttachClientExited settles a still-pending discovery as failed, never touching exit status")
    func attachClientExitSettlesPendingDiscoveryAsFailed() async throws {
        // A real, harmless directory whose socket never appears: proves the
        // real kqueue registration path doesn't hang or crash, while the
        // race is decided deterministically because discovery genuinely
        // cannot complete on its own here.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let observer = ColdStartObserver()

        let observationTask = Task {
            await observer.observeColdStart(
                zmxDirectory: temporaryDirectory,
                socketPath: temporaryDirectory.appending(path: "never-appears").path,
                bootID: "test-boot-id",
                attemptID: ColdRestoreAttemptID.generate()
            )
        }
        await observer.reportAttachClientExited()

        let outcome = await observationTask.value

        #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
    }

    @Test(
        "reportAttachClientExited racing ahead of observeColdStart itself is not a crash -- observeColdStart returns the pre-settled outcome"
    )
    func attachClientExitBeforeObserveColdStartIsNotACrash() async throws {
        let observer = ColdStartObserver()

        await observer.reportAttachClientExited()
        let outcome = await observer.observeColdStart(
            zmxDirectory: URL(filePath: "/does/not/matter"),
            socketPath: "/does/not/matter/session",
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
    }

    @Test("a second reportAttachClientExited after settlement is a no-op, not a double-resume")
    func secondReportAfterSettlementIsANoOp() async throws {
        let observer = ColdStartObserver()

        await observer.reportAttachClientExited()
        let outcome = await observer.observeColdStart(
            zmxDirectory: URL(filePath: "/does/not/matter"),
            socketPath: "/does/not/matter/session",
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )
        // Would trap (double resume of a CheckedContinuation) if settle()
        // weren't idempotent.
        await observer.reportAttachClientExited()

        #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
    }

    @Test("cancel settles a still-pending discovery without hanging its awaiter")
    func cancelSettlesPendingDiscoveryWithoutHanging() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-cancel-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let observer = ColdStartObserver()

        let observationTask = Task {
            await observer.observeColdStart(
                zmxDirectory: temporaryDirectory,
                socketPath: temporaryDirectory.appending(path: "never-appears").path,
                bootID: "test-boot-id",
                attemptID: ColdRestoreAttemptID.generate()
            )
        }
        await observer.cancel()

        // The awaiter is unblocked; the specific outcome value carries no
        // meaning the caller of cancel() should act on (see cancel()'s doc).
        _ = await observationTask.value
    }

    /// Opens `path` for `EVFILT_VNODE` watching itself, the same call
    /// `DarwinColdStartObserverSyscalls.openDirectoryForWatching` makes --
    /// a scripted `ScriptedSyscalls` still needs a real, valid descriptor
    /// for `ColdStartObserver`'s real `DispatchSource` registration to work
    /// against, even though the connect/observe step past it is faked. The
    /// observer's own `teardownWatches()` closes it on settlement.
    ///
    /// Not `private` (test-file split, Lead 2026-10-02): shared with
    /// `ColdStartObserverTests+HandoffStage.swift`'s moved handoff-stage
    /// tests -- `private` is file-scoped and does not cross the split.
    func openRealDirectoryDescriptor(at path: String) throws -> Int32 {
        let descriptor = open(path, O_EVTONLY)
        try #require(descriptor >= 0, "expected to open a real directory for EVFILT_VNODE watching")
        return descriptor
    }

    /// Program Design item 3, stage 1, amended 2026-09-30: zmx binds the
    /// session socket's filesystem path before it calls `listen`, so a
    /// connect landing in that gap is refused, not queued -- `discovery`
    /// retries rather than settling unobservable. `terminalLeader` is this
    /// test process's own real, live incarnation (queried the same way
    /// `ZmxSessionControl.currentIncarnation` does), so stage 2's handoff
    /// comparison is fully real, not scripted -- only the discovery-connect
    /// seam is a test double.
    @Test("a connect refused twice then succeeding retries discovery and reaches handoff")
    func connectRefusedTwiceThenSucceedingRetriesDiscoveryAndReachesHandoff() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-discovery-retry-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        // Pre-created: "register first, then check" means discovery must
        // already find this socket path present the moment it starts.
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
        syscalls.observeSessionResults = [
            .failure(.connectionRefused),
            .failure(.connectionRefused),
            .identity(identity),
        ]
        syscalls.processArgumentsResult = .success(makeEmptyArgumentVectorBuffer())
        let observer = ColdStartObserver(syscalls: syscalls)

        let outcome = await observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        #expect(outcome == .handedOff)
        #expect(syscalls.observeSessionCallCount == 3)
    }

    /// The other half of the same amendment: exhausting every retry still
    /// refused must NOT settle on the timing alone -- the window stays
    /// discovering until a real fact resolves it. Driven entirely through
    /// the scripted call-count seam, never a sleep in this test.
    @Test("a connect refused on every retry stays discovering, and settles only on a later attach-client exit")
    func connectRefusedOnEveryRetryStaysDiscoveringAndSettlesOnAttachClientExit() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-discovery-exhausted-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        syscalls.observeSessionResults = Array(
            repeating: .failure(.connectionRefused), count: AppPolicies.Restore.discoveryConnectRetryDelays.count + 1)
        let observeSessionCallSource = LocalFactSource(vocabulary: ScriptedSyscalls.observeSessionCallFactVocabulary())
        let observeSessionCallRecorder = try observeSessionCallSource.attach()
        syscalls.observeSessionCallFactSink = observeSessionCallSource.sink
        let observer = ColdStartObserver(syscalls: syscalls)

        let observationTask = Task {
            await observer.observeColdStart(
                zmxDirectory: temporaryDirectory,
                socketPath: socketPath,
                bootID: "test-boot-id",
                attemptID: ColdRestoreAttemptID.generate()
            )
        }

        // Every scripted attempt (the initial connect plus every retry) has
        // genuinely run before the exit fires -- proves the window was
        // still discovering through the whole retry budget, not settled
        // early by some other path. Sequential expectNext calls on this one
        // fact channel are themselves the proof of arrival order.
        let expectedAttempts = AppPolicies.Restore.discoveryConnectRetryDelays.count + 1
        for expectedCount in 1...expectedAttempts {
            try await observeSessionCallRecorder.expectNext(in: ScriptedSyscalls.observeSessionScope, expectedCount)
        }
        await observer.reportAttachClientExited()

        let outcome = await observationTask.value

        #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
    }

    /// Program Design item 3, stage 1, amended again 2026-09-30:
    /// `unexpectedProcessGroup`/`unexpectedProcessParent` means the pty
    /// child hasn't called `setsid` yet -- still discovering, not
    /// unobservable. Watches a real, short-lived process's own real exec
    /// (spawned here, not zmx) so the re-observe genuinely happens at a
    /// real `NOTE_EXEC`, not just the immediate post-registration check --
    /// the scripted sequence's middle entry proves that immediate check
    /// still sees `.pendingSetsid` (the real process hasn't exec'd yet).
    ///
    /// Amended a third time 2026-09-30, against real evidence, not a guess:
    /// a plain `sleep 0.05` before the real exec raced the test's own async
    /// setup under load -- the scripted immediate-post-registration check
    /// always answers `.pendingSetsid` regardless of what the real process
    /// has actually done, so if the real exec happened before
    /// `beginSetsidWatch`'s registration (possible under load, since
    /// nothing bounded that race), the watch registered too late to ever
    /// see its `NOTE_EXEC`, and the observer hung until the final `/bin/sleep
    /// 300` itself exited (`.failed`, not `.handedOff`, after minutes, not
    /// milliseconds). A deterministic FIFO hold point (the same pattern
    /// `43f02d4c8` uses against real zmx) removes the race instead of
    /// tolerating it: the real process cannot reach its own exec until this
    /// test releases it, and the release itself waits for `ScriptedSyscalls`'
    /// own call-count event -- proof the immediate post-registration check
    /// (call 2) has already happened, which only occurs after
    /// `beginSetsidWatch`'s `DispatchSource` has already registered.
    @Test("unexpectedProcessGroup re-observes at the real exec and discovers correctly")
    func pendingSetsidReobservesAtRealExecAndDiscovers() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-pending-setsid-exec-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let holdFIFOPath = try makeFIFOPath()
        defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }

        let controlledProcess = Process()
        controlledProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        controlledProcess.arguments = ["-c", "read _ < '\(holdFIFOPath)'; exec /bin/sleep 300"]
        controlledProcess.standardOutput = FileHandle.nullDevice
        controlledProcess.standardError = FileHandle.nullDevice
        try controlledProcess.run()
        defer { controlledProcess.terminate() }
        let terminalPID = controlledProcess.processIdentifier

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
        syscalls.observeSessionResults = [
            .pendingSetsid(terminalPID: terminalPID),
            // The immediate post-registration check (register-then-check):
            // the real process is still blocked at the FIFO hold, so it
            // genuinely hasn't exec'd yet -- deterministically, not by
            // timing luck.
            .pendingSetsid(terminalPID: terminalPID),
            // The check the real NOTE_EXEC event triggers, once this test
            // releases the hold below.
            .identity(identity),
        ]
        // beginDiscovery's directory watch can harmlessly re-fire beyond
        // what's scripted above (e.g. the temp directory's own creation
        // write); keep any such extra call consistent with "still
        // discovering" instead of falling to the default .unavailable,
        // which would spuriously settle unobservable.
        syscalls.observeSessionFallback = .pendingSetsid(terminalPID: terminalPID)
        syscalls.processArgumentsResult = .success(makeEmptyArgumentVectorBuffer())
        let observeSessionCallSource = LocalFactSource(vocabulary: ScriptedSyscalls.observeSessionCallFactVocabulary())
        let observeSessionCallRecorder = try observeSessionCallSource.attach()
        syscalls.observeSessionCallFactSink = observeSessionCallSource.sink
        let observer = ColdStartObserver(syscalls: syscalls)

        async let outcome = observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        // Release only once the observer's own immediate post-registration
        // check has genuinely happened -- an event ScriptedSyscalls itself
        // reports, never a poll or a sleep. Two sequential expectNext calls
        // (call 1: the initial discovery check; call 2: the immediate
        // post-registration check) prove both happened in order before
        // releasing the hold.
        try await observeSessionCallRecorder.expectNext(in: ScriptedSyscalls.observeSessionScope, 1)
        try await observeSessionCallRecorder.expectNext(in: ScriptedSyscalls.observeSessionScope, 2)
        let fifoWriteDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
        try await closeFIFOWriteDescriptor(fifoWriteDescriptor)

        let settledOutcome = await outcome
        #expect(settledOutcome == .handedOff)
        #expect(syscalls.observeSessionCallCount == 3)
    }

    /// The other half: a leader that exits before ever calling `setsid`
    /// (or at least before `observe` ever succeeds) settles failed, never
    /// unobservable -- `NOTE_EXIT` fires with no intervening `NOTE_EXEC`.
    ///
    /// Amended 2026-09-30: replaced a `sleep 0.05; exit 1` real-process
    /// ordering with the sibling test's own FIFO hold point. The real
    /// process cannot reach its own `exit 1` until this test confirms --
    /// via `ScriptedSyscalls`' own call-count event, never a poll or a
    /// sleep -- that `beginSetsidWatch`'s `DispatchSource` has already
    /// registered, so the `NOTE_EXIT` this test asserts on is always a live
    /// fire against an armed watch, not a race against an arbitrary delay.
    @Test("a leader that exits before setsid ever succeeds settles failed")
    func pendingSetsidExitBeforeAnySuccessSettlesFailed() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-pending-setsid-exit-test-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let holdFIFOPath = try makeFIFOPath()
        defer { try? FileManager.default.removeItem(atPath: holdFIFOPath) }

        let controlledProcess = Process()
        controlledProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        controlledProcess.arguments = ["-c", "read _ < '\(holdFIFOPath)'; exit 1"]
        controlledProcess.standardOutput = FileHandle.nullDevice
        controlledProcess.standardError = FileHandle.nullDevice
        try controlledProcess.run()
        let terminalPID = controlledProcess.processIdentifier

        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        syscalls.observeSessionResults = [
            .pendingSetsid(terminalPID: terminalPID),
            .pendingSetsid(terminalPID: terminalPID),
        ]
        // See the sibling test's comment: absorb any extra redundant
        // directory-watch-triggered call without spuriously settling.
        syscalls.observeSessionFallback = .pendingSetsid(terminalPID: terminalPID)
        let observeSessionCallSource = LocalFactSource(vocabulary: ScriptedSyscalls.observeSessionCallFactVocabulary())
        let observeSessionCallRecorder = try observeSessionCallSource.attach()
        syscalls.observeSessionCallFactSink = observeSessionCallSource.sink
        let observer = ColdStartObserver(syscalls: syscalls)

        async let outcome = observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        // Release only once the observer's own immediate post-registration
        // check has genuinely happened -- an event ScriptedSyscalls itself
        // reports, never a poll or a sleep. Two sequential expectNext calls
        // (call 1: the initial discovery check; call 2: the immediate
        // post-registration check) prove both happened in order before
        // releasing the hold.
        try await observeSessionCallRecorder.expectNext(in: ScriptedSyscalls.observeSessionScope, 1)
        try await observeSessionCallRecorder.expectNext(in: ScriptedSyscalls.observeSessionScope, 2)
        let fifoWriteDescriptor = try await openFIFOForWriting(atPath: holdFIFOPath)
        try await closeFIFOWriteDescriptor(fifoWriteDescriptor)

        let settledOutcome = await outcome
        #expect(settledOutcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
    }

    /// A2 (blocker, advisor review 2026-10-01; test technique corrected by
    /// the Lead 2026-10-01 to avoid saturating a shared queue): proves the
    /// discovery watch's mandatory initial check does not run until kernel
    /// registration is actually confirmed complete -- not merely after
    /// `source.resume()` returns. The SDK is explicit that `resume()` only
    /// requests registration: `dispatch_source_set_registration_handler`'s
    /// own contract says its handler is submitted "once the corresponding
    /// kevent() has been registered with the system, following the initial
    /// dispatch_resume()" (source.h:745), never synchronously inline at
    /// `resume()`'s own call site.
    ///
    /// Injects a private, test-owned `DispatchQueue` as the observer's own
    /// `targetQueue` (the same seam production uses — just a test-supplied
    /// queue instead of production's own private one) and suspends it
    /// before `observeColdStart` ever starts. `dispatch_suspend`/
    /// `dispatch_resume` on a queue is a documented, deterministic GCD
    /// primitive that holds a source's *handler block* from running; it
    /// does not affect the source's own, independent kernel registration
    /// (`source.resume()` still proceeds regardless of its target queue's
    /// suspend state) -- this is why suspending the queue, not the source,
    /// is the right seam for "registration confirmed, handler not yet run".
    /// The socket file is created only after the watch is active but while
    /// the queue is still suspended -- the event landing in the exact
    /// window A2 is about, with no raw kernel timing and nothing
    /// process-global touched.
    ///
    /// Before this fix, `beginDiscovery`'s mandatory check runs
    /// synchronously inside `beginDiscovery` itself, before this test ever
    /// creates the socket file: it sees nothing, and — with no
    /// registration handler to ever re-check — `syscalls.observeSession`
    /// is never called again. This test would then never observe that
    /// first call and relies on the runner's own hang bound, exactly like
    /// `FactRecorder.expectNext`'s own documented contract (no sleeps, no
    /// deadlines of its own). After the fix, the registration-handler-
    /// driven check only runs once this test resumes the queue, by which
    /// point the file already exists, and it is observed correctly.
    ///
    /// R2-4 item 4 (review round 2, Lead 2026-10-01), corrected and its
    /// residual disclosed rather than claimed away:
    ///
    /// 1. the prior version ordered file creation only by `async let`'s own
    ///    program order, which does not guarantee the child task has even
    ///    reached `source.resume()` by then -- a file created too early
    ///    would satisfy the old, buggy synchronous-after-`resume()` check
    ///    too. Fixed by awaiting `openDirectoryForWatching`'s own call fact
    ///    first: its doc comment confirms this fires from inside
    ///    `beginDiscovery`'s non-suspending body, with no suspension point
    ///    before `source.resume()`, so that stretch cannot be interrupted
    ///    on the same thread. Unlike `directoryDescriptorStaysOpenUntil
    ///    CancellationCompletes`'s use of the same fact (`ColdStartObserver
    ///    WatchSourceOwnershipTests.swift`), this test never re-enters the
    ///    actor afterward, so it does not need that test's stronger
    ///    before-`cancel()`-can-enter-the-actor guarantee.
    /// 2. R3-3 item 2 (Lead decision 2026-10-02), now closed: the
    ///    `DispatchQueue.getSpecific` witness below proves the registration
    ///    fact was emitted from the injected target queue's handler. The
    ///    provenance tag alone cannot distinguish that handler from an
    ///    immediate actor call after `resume()`.
    ///
    /// Gate 5 fix (Lead 2026-10-02): the registration handler's block itself
    /// runs on `testQueue` (`beginDiscovery`'s `DispatchSource.makeFileSystemObjectSource(...,
    /// queue: targetQueue)`), so it cannot fire while `testQueue` is still
    /// suspended -- awaiting `.socketCheckRan(.registration)` before
    /// `testQueue.resume()` self-deadlocks. The file is created and the
    /// queue resumed first; `expectNext`'s exact-match overload
    /// (`FactRecorder.swift`) then requires the very next fact in this
    /// scope to equal `.socketCheckRan(.registration)`, throwing
    /// `UnexpectedFact` rather than skipping ahead if it is not -- so a
    /// removed mandatory check, which would leave only a later
    /// `.socketCheckRan(.directoryEvent)` fact (from the same `createFile`
    /// call's real `NOTE_WRITE`) or none at all, still fails this.
    @Test("the discovery watch's mandatory check observes an event that lands while its queue is suspended")
    func discoveryMandatoryCheckWaitsForConfirmedKernelRegistration() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-a2-registration-timing-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path

        let testQueue = DispatchQueue(label: "cold-start-observer-a2-test-queue", qos: .userInitiated)
        let registrationQueueKey = DispatchSpecificKey<Bool>()
        testQueue.setSpecific(key: registrationQueueKey, value: true)
        testQueue.suspend()

        let syscalls = ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        // A single, terminal result: this test is about whether the check
        // observes the file at all, not about the stages past discovery.
        syscalls.observeSessionResults = [.terminalLeaderGone]
        let observeSessionCallSource = LocalFactSource(vocabulary: ScriptedSyscalls.observeSessionCallFactVocabulary())
        let observeSessionCallRecorder = try observeSessionCallSource.attach()
        syscalls.observeSessionCallFactSink = observeSessionCallSource.sink
        // R2-4 item 4: the one real ordering guarantee available without a
        // new production seam -- see the doc comment above.
        let directoryOpenCallSource = LocalFactSource(vocabulary: ScriptedSyscalls.directoryOpenCallFactVocabulary())
        let directoryOpenCallRecorder = try directoryOpenCallSource.attach()
        syscalls.directoryOpenCallFactSink = directoryOpenCallSource.sink
        // R3-3 item 2: the fact sink this test's own doc comment above
        // named and deferred -- see there for why it proves registration
        // ran, not merely that some check eventually found the file.
        let observerFactSource = LocalFactSource(
            vocabulary: FactVocabulary<String, ColdStartObserverFact>(
                describeScope: { $0 }, describeFact: { "\($0)" }, isClosing: { _, _ in false }))
        let observerFactRecorder = try observerFactSource.attach()
        let registrationContextSource = LocalFactSource(
            vocabulary: FactVocabulary<String, Bool>(
                describeScope: { $0 }, describeFact: { "registration handler on target queue: \($0)" },
                isClosing: { _, _ in false }))
        let registrationContextRecorder = try registrationContextSource.attach()
        let observer = ColdStartObserver(
            syscalls: syscalls, targetQueue: testQueue,
            factSink: { fact in
                if case .socketCheckRan(.registration) = fact {
                    registrationContextSource.sink(
                        "registrationContext",
                        DispatchQueue.getSpecific(key: registrationQueueKey) ?? false
                    )
                }
                observerFactSource.sink("coldStartFact", fact)
            })

        // Act
        async let outcome = observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        // Wait for beginDiscovery's open call before creating the file. This
        // fact is emitted before the source is constructed or resumed; the
        // queue-specific witness below independently proves which handler
        // later ran the mandatory check.
        try await directoryOpenCallRecorder.expectNext(in: ScriptedSyscalls.directoryOpenScope, 1)

        // The file exists before either handler's block can actually run --
        // the queue is still suspended.
        FileManager.default.createFile(atPath: socketPath, contents: nil)
        testQueue.resume()

        // R3-3 item 2, gate 5 fix: the FIRST socketCheckRan fact in this
        // scope must be the registration handler's -- a removed mandatory
        // check would never post this, leaving only a later
        // `.directoryEvent` fact (or none) here instead.
        _ = try await observerFactRecorder.expectNext(in: "coldStartFact", .socketCheckRan(.registration))
        _ = try await registrationContextRecorder.expectNext(in: "registrationContext", true)

        // Assert: that same check observed the file it just created and
        // proceeded to attempt the connect.
        try await observeSessionCallRecorder.expectNext(in: ScriptedSyscalls.observeSessionScope, 1)

        let settledOutcome = await outcome
        #expect(settledOutcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
    }
}
