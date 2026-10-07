import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// A3 (advisor review 2026-10-01; test technique corrected by the Lead
/// 2026-10-01 — option (c)): `ColdStartObserver`'s process-watch source
/// ownership, proven as direct facts (who got cancelled, who got created,
/// in what order, who stayed inert) through an injected
/// `ColdStartProcessWatchSourceMaker`, never through kernel or queue
/// timing — the SDK (source.h) says nothing about an already-submitted
/// registration handler's fate after `cancel()`, so a test relying on that
/// would be unsound. Split out of `ColdStartObserverTests.swift` to keep
/// both files under the repo's line-length ceiling; shares that file's own
/// `ScriptedSyscalls` double (`internal`, not `private`, for exactly this
/// reason).
///
/// A4 (R1 gate, Lead 2026-10-01): also holds the directory-descriptor
/// lifetime test, moved here from `ColdStartObserverTests.swift` for the
/// same line-length reason -- the original "process-watch" name no longer
/// covered it, hence this file and suite's own rename to "watch source"
/// (both the process watch and the directory watch).
@Suite("Cold start observer watch source ownership")
struct ColdStartObserverWatchSourceOwnershipTests {
    /// A3 (test technique corrected by the Lead 2026-10-01): a fake
    /// `ColdStartProcessWatchSource` that records its own `resume()`/
    /// `cancel()`/handler installs, and lets a test fire a simulated
    /// exec/exit event directly -- ownership proven as a direct fact
    /// (who got cancelled, who stayed inert) with no kernel or queue
    /// timing involved. `cancel()` does NOT clear the event handler
    /// (corrected, review round 2, Lead 2026-10-01): a real `DispatchSource`
    /// keeps its registered handler closure even after `cancel()`, so a
    /// `simulateEvent` after cancellation must still reach `ColdStartObserver`
    /// for real, exercising its own `hasBegunHandoffWatch`/`isSettled` stage
    /// guards -- a fake that cleared the handler would stay inert by its
    /// own construction instead of proving that production guard.
    private final class FakeProcessWatchSource: ColdStartProcessWatchSource, @unchecked Sendable {
        let identifier: Int32
        private let lock = NSLock()
        private var eventHandler: (@Sendable (Bool) -> Void)?
        private var cancelHandler: (@Sendable () -> Void)?
        private var registrationHandler: (@Sendable () -> Void)?
        private(set) var resumeCallCount = 0
        private(set) var cancelCallCount = 0

        init(identifier: Int32) {
            self.identifier = identifier
        }

        func setEventHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
            lock.lock()
            eventHandler = handler
            lock.unlock()
        }

        func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.lock()
            cancelHandler = handler
            lock.unlock()
        }

        func setRegistrationHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.lock()
            registrationHandler = handler
            lock.unlock()
        }

        func resume() {
            lock.lock()
            resumeCallCount += 1
            let handler = registrationHandler
            lock.unlock()
            // The fake's own registration completes immediately --
            // deterministic, no real kernel involved.
            handler?()
        }

        func cancel() {
            lock.lock()
            guard cancelCallCount == 0 else {
                lock.unlock()
                return
            }
            cancelCallCount += 1
            let handler = cancelHandler
            lock.unlock()
            handler?()
        }

        /// R2-4 item 5 / R2-1 (review round 2, Lead 2026-10-01): `cancel()`
        /// no longer clears `eventHandler`, and this keeps dispatching to
        /// whatever handler was captured, cancelled or not. A real
        /// `DispatchSource` retains its registered handler closure even
        /// after `cancel()` is called -- cancellation is asynchronous
        /// (A4), so a callback already queued on a cancelled/superseded
        /// source can still run. Clearing the handler here would make this
        /// a no-op by construction, proving only this fake's own
        /// bookkeeping; dispatching for real is what lets a test prove
        /// production's own stage guard (`hasBegunHandoffWatch`/`isSettled`)
        /// ignores that late callback.
        func simulateEvent(exitFired: Bool) {
            lock.lock()
            let handler = eventHandler
            lock.unlock()
            handler?(exitFired)
        }
    }

    /// A3: records every process-watch source this maker creates, in
    /// creation order, so a test can inspect the exact ownership sequence.
    private final class RecordingProcessWatchSourceMaker: @unchecked Sendable {
        private let lock = NSLock()
        private var sources: [FakeProcessWatchSource] = []

        var createdSources: [FakeProcessWatchSource] {
            lock.lock()
            defer { lock.unlock() }
            return sources
        }

        var maker: ColdStartProcessWatchSourceMaker {
            { [weak self] identifier, _, _ in
                let source = FakeProcessWatchSource(identifier: identifier)
                self?.lock.lock()
                self?.sources.append(source)
                self?.lock.unlock()
                return source
            }
        }
    }

    /// Opens `path` for `EVFILT_VNODE` watching itself, the same call
    /// `DarwinColdStartObserverSyscalls.openDirectoryForWatching` makes --
    /// a scripted `ScriptedSyscalls` still needs a real, valid descriptor
    /// for `ColdStartObserver`'s real `DispatchSource` registration to work
    /// against, even though the connect/observe step past it is faked.
    /// Duplicated from `ColdStartObserverTests`'s own private helper of the
    /// same name -- small and self-contained enough that sharing it isn't
    /// worth a cross-file seam.
    private func openRealDirectoryDescriptor(at path: String) throws -> Int32 {
        let descriptor = open(path, O_EVTONLY)
        try #require(descriptor >= 0, "expected to open a real directory for EVFILT_VNODE watching")
        return descriptor
    }

    /// A minimal, valid `KERN_PROCARGS2`-shaped buffer with `argc = 0` --
    /// `ProcessArgumentsBufferParser.argumentVector` parses it to an empty
    /// array, which never contains a startup token. Duplicated from
    /// `ColdStartObserverTests`'s own private helper of the same name.
    private func makeEmptyArgumentVectorBuffer(execPath: String = "/bin/example") -> [UInt8] {
        var buffer = withUnsafeBytes(of: Int32(0)) { Array($0) }
        buffer.append(contentsOf: Array(execPath.utf8))
        buffer.append(0)
        return buffer
    }

    /// Same `KERN_PROCARGS2` shape, carrying `argv` -- used where a test
    /// needs the token genuinely present (`tokenStillPresent`), not just an
    /// empty argv that can only ever read as absent. Duplicated from
    /// `ColdStartObserverTests`'s own private helper of the same name.
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

    /// A3 (important, advisor review 2026-10-01; test technique corrected
    /// by the Lead 2026-10-01 -- option (c), a direct ownership fact
    /// instead of a mechanism the SDK doesn't specify): proves a late
    /// `.pendingSetsid` discovery result reaching `beginSetsidWatch` after
    /// this attempt has already settled installs no new source.
    ///
    /// Settles the observer first, then delivers the late result directly
    /// through `beginSetsidWatch` itself (relaxed to `package` visibility
    /// for exactly this reason) -- no race against discovery's own timing,
    /// since the observer is unconditionally already settled before this
    /// call.
    @Test("beginSetsidWatch installs no source once the attempt has already settled")
    func beginSetsidWatchInstallsNoSourceAfterSettlement() async throws {
        let recordingMaker = RecordingProcessWatchSourceMaker()
        let syscalls = ColdStartObserverTests.ScriptedSyscalls()
        let observer = ColdStartObserver(syscalls: syscalls, processWatchSourceMaker: recordingMaker.maker)

        await observer.cancel()

        // Act: the late .pendingSetsid result, delivered directly.
        await observer.beginSetsidWatch(
            terminalPID: 4242,
            socketPath: "/tmp/cold-start-observer-a3-late-pending-setsid-does-not-exist",
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        // Assert: the maker was never called.
        #expect(recordingMaker.createdSources.isEmpty)
    }

    /// A3: proves `beginHandoffWatch` cancels the setsid watch's own
    /// source before creating the handoff source, and that the cancelled
    /// source stays inert — a late event on it can never advance the
    /// stage again (no second `observeSession` call).
    @Test("the setsid watch's source is cancelled before the handoff source is created, and stays inert")
    func setsidSourceCancelledBeforeHandoffSourceCreatedAndStaysInert() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-a3-superseded-watch-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let recordingMaker = RecordingProcessWatchSourceMaker()
        let syscalls = ColdStartObserverTests.ScriptedSyscalls()
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
            .pendingSetsid(terminalPID: 4242),
            .identity(identity),
        ]
        syscalls.processArgumentsResult = .success(makeEmptyArgumentVectorBuffer())
        let observer = ColdStartObserver(syscalls: syscalls, processWatchSourceMaker: recordingMaker.maker)

        let outcome = await observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        #expect(outcome == .handedOff)

        // Assert ownership: exactly two sources -- setsid, then handoff --
        // and the setsid source was cancelled (by beginHandoffWatch, before
        // the handoff source's own creation call in the same synchronous
        // body). Settlement (teardownWatches) then cancels the current
        // (handoff) source too -- every owned source cancelled exactly
        // once, the teardown half of ownership.
        let createdSources = recordingMaker.createdSources
        #expect(createdSources.count == 2)
        guard let setsidSource = createdSources.first, let handoffSource = createdSources.last else { return }
        #expect(setsidSource.cancelCallCount == 1)
        #expect(handoffSource.cancelCallCount == 1)

        // Assert inert: a late event on the superseded setsid source
        // cannot advance anything.
        let callCountBeforeSimulatedEvent = syscalls.observeSessionCallCount
        setsidSource.simulateEvent(exitFired: true)
        #expect(syscalls.observeSessionCallCount == callCountBeforeSimulatedEvent)
    }

    /// R2-1 (review round 2, Lead 2026-10-01): an independent connect (e.g.
    /// a concurrent directory event) that already found `.pendingSetsid`
    /// and registered its own setsid watch before discovery's own normal
    /// flow even starts, modeled as a direct `beginSetsidWatch` call
    /// (package-visible for exactly this reason, matching
    /// `beginSetsidWatchInstallsNoSourceAfterSettlement` above), followed
    /// by discovery's own real flow independently reaching `.pendingSetsid`
    /// too and carrying the attempt all the way to a real handoff and
    /// settlement.
    ///
    /// Proves the two things the prior sibling test could not: (1)
    /// discovery's own setsid watch cancels the pre-emptive one instead of
    /// silently dropping its reference (the leak this residual closes --
    /// "every created source is either current or cancelled"); (2) while
    /// the handoff is still pending, a callback queued on that pre-emptive,
    /// long-superseded source is ignored.
    ///
    /// R3-3a (Lead decision 2026-10-02): the handoff registration check
    /// reads a token-present argv and stays pending. The pre-emptive
    /// superseded setsid source then reports exit; its own disposition fact
    /// must say `.ignoredAsStale` before the test changes argv and delivers
    /// the handoff source's token-absent event. This proves the handoff-stage
    /// guard while `isSettled` is still false.
    @Test(
        "repeated pendingSetsid discovery keeps one current source and ignores a superseded exit before handoff settles"
    )
    func repeatedPendingSetsidKeepsOneCurrentSourceAndIgnoresSupersededExitBeforeHandoffSettles() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-r2-1-repeated-setsid-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let recordingMaker = RecordingProcessWatchSourceMaker()
        let syscalls = ColdStartObserverTests.ScriptedSyscalls()
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
        let attemptID = ColdRestoreAttemptID.generate()
        // Call 1: the pre-emptive direct beginSetsidWatch below, whose own
        // fake-source registration fires synchronously. Call 2: discovery's
        // own mandatory check, once its real directory watch registers --
        // both must still read .pendingSetsid, so neither commits to
        // handoff on its own. Call 3: discovery's own setsid source's own
        // registration observes the real identity, committing to handoff.
        syscalls.observeSessionResults = [
            .pendingSetsid(terminalPID: 4242),
            .pendingSetsid(terminalPID: 4242),
            .identity(identity),
        ]
        // Keep the handoff pending after its initial registration read;
        // only the later simulated handoff event changes argv to token-absent.
        syscalls.processArgumentsResult = .success(
            makeArgumentVectorBuffer(argv: [attemptID.startupToken]))
        let processArgumentsSource = LocalFactSource(
            vocabulary: ColdStartObserverTests.ScriptedSyscalls.processArgumentsCallFactVocabulary())
        let processArgumentsRecorder = try processArgumentsSource.attach()
        syscalls.processArgumentsCallFactSink = processArgumentsSource.sink
        let settlementFactSource = LocalFactSource(
            vocabulary: FactVocabulary<String, ColdStartObserverFact>(
                describeScope: { $0 },
                describeFact: { "\($0)" },
                isClosing: { _, _ in false }
            ))
        let settlementFactRecorder = try settlementFactSource.attach()
        let settlementFactSink = settlementFactSource.sink
        let observer = ColdStartObserver(
            syscalls: syscalls, processWatchSourceMaker: recordingMaker.maker,
            factSink: { fact in settlementFactSink("coldStartObserverFact", fact) })

        // Act 1: the pre-emptive, independent setsid watch.
        await observer.beginSetsidWatch(
            terminalPID: 4242, socketPath: socketPath, bootID: "test-boot-id", attemptID: attemptID)
        let preemptiveSetsidSource = try #require(recordingMaker.createdSources.first)
        #expect(preemptiveSetsidSource.cancelCallCount == 0, "the pre-emptive source must still be active")

        // Act 2: discovery's own real flow reaches .pendingSetsid, its
        // setsid source observes the identity, and the handoff source reads
        // token-present argv. It remains unsettled waiting for another
        // handoff event.
        async let pendingOutcome = observer.observeColdStart(
            zmxDirectory: temporaryDirectory, socketPath: socketPath, bootID: "test-boot-id", attemptID: attemptID)

        // Consume the initial discovery fact and wait until the handoff
        // registration check has actually read token-present argv.
        _ = try await settlementFactRecorder.expectNext(in: "coldStartObserverFact", .socketCheckRan(.registration))
        _ = try await processArgumentsRecorder.expectNext(
            in: ColdStartObserverTests.ScriptedSyscalls.processArgumentsScope, 1)

        let createdSources = recordingMaker.createdSources
        #expect(createdSources.count == 3)
        #expect(preemptiveSetsidSource.cancelCallCount == 1, "the pre-emptive source must be cancelled, not leaked")
        let discoverySetsidSource = createdSources[1]
        #expect(discoverySetsidSource.cancelCallCount == 1)
        let handoffSource = createdSources[2]
        #expect(handoffSource.cancelCallCount == 0, "the handoff must remain pending during the stale callback")

        // Act 3: deliver the superseded setsid exit before handoff settles.
        preemptiveSetsidSource.simulateEvent(exitFired: true)

        // The guard's own disposition closes this negative proof. If only
        // `hasBegunHandoffWatch` is removed, this becomes `.applied` while
        // the token-present handoff is still pending.
        _ = try await settlementFactRecorder.expectNext(
            in: "coldStartObserverFact", .setsidSettlementProcessed(.ignoredAsStale))
        #expect(handoffSource.cancelCallCount == 0)

        // Act 4: allow the current handoff source to observe token absence
        // and settle normally.
        syscalls.processArgumentsResult = .success(makeEmptyArgumentVectorBuffer())
        handoffSource.simulateEvent(exitFired: false)
        _ = try await processArgumentsRecorder.expectNext(
            in: ColdStartObserverTests.ScriptedSyscalls.processArgumentsScope, 2)
        let outcome = await pendingOutcome
        #expect(outcome == .handedOff)

        // Assert ownership: each source is cancelled exactly once at real
        // handoff settlement, with no duplicate teardown from the stale exit.
        #expect(recordingMaker.createdSources.count == 3)
        #expect(discoverySetsidSource.cancelCallCount == 1)
        #expect(handoffSource.cancelCallCount == 1)
    }

    /// A3: proves settlement cancels an in-flight setsid watch's own
    /// source exactly once -- the teardown half of ownership, separate
    /// from the setsid-to-handoff transition the sibling test covers.
    @Test("external cancellation cancels the in-flight setsid watch's source exactly once")
    func externalCancellationCancelsInFlightSetsidSourceExactlyOnce() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-a3-teardown-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let socketPath = temporaryDirectory.appending(path: "session").path
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let recordingMaker = RecordingProcessWatchSourceMaker()
        let syscalls = ColdStartObserverTests.ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(try openRealDirectoryDescriptor(at: temporaryDirectory.path))
        syscalls.observeSessionResults = [.pendingSetsid(terminalPID: 4242)]
        syscalls.observeSessionFallback = .pendingSetsid(terminalPID: 4242)
        let observeSessionCallSource = LocalFactSource(
            vocabulary: ColdStartObserverTests.ScriptedSyscalls.observeSessionCallFactVocabulary())
        let observeSessionCallRecorder = try observeSessionCallSource.attach()
        syscalls.observeSessionCallFactSink = observeSessionCallSource.sink
        let observer = ColdStartObserver(syscalls: syscalls, processWatchSourceMaker: recordingMaker.maker)

        // Act
        async let outcome = observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: socketPath,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )

        // Wait for the setsid watch's own source to exist: call 1 is
        // discovery's own mandatory check (-> .pendingSetsid), call 2 is
        // the setsid watch's own mandatory check -- an event, never a
        // poll.
        try await observeSessionCallRecorder.expectNext(
            in: ColdStartObserverTests.ScriptedSyscalls.observeSessionScope, 1)
        try await observeSessionCallRecorder.expectNext(
            in: ColdStartObserverTests.ScriptedSyscalls.observeSessionScope, 2)

        await observer.cancel()
        _ = await outcome

        // Assert: exactly one source, cancelled exactly once.
        let createdSources = recordingMaker.createdSources
        #expect(createdSources.count == 1)
        #expect(createdSources.first?.cancelCallCount == 1)
    }

    /// A4 (important, advisor review 2026-10-01; test technique corrected
    /// by the Lead 2026-10-01 to avoid saturating a shared queue, then
    /// again 2026-10-01 for an `async let`/`cancel()` actor-entry race --
    /// moved to this sibling file for the repo's own line-length ceiling,
    /// matching the rest of this split): proves the watched directory's
    /// file descriptor stays open until the directory watch's own
    /// `DispatchSource` cancellation has actually completed, never before.
    /// `dispatch_source_cancel` is asynchronous (SDK source.h:512); its
    /// cancel handler is the documented boundary for when the handle is
    /// safe to close (source.h:449 -- closing earlier permits the
    /// descriptor's reuse while the source may still reference it).
    ///
    /// Injects a private, test-owned, serial `DispatchQueue` as the
    /// observer's `targetQueue` (same seam as A2's proof) and suspends it
    /// before activation, so cancellation can be requested but the cancel
    /// handler that must run the actual `close()` cannot.
    ///
    /// Before the first fix, `teardownWatches`/`discoverySettled` closed the
    /// descriptor as a plain, synchronous actor-isolated call -- wholly
    /// unaffected by the suspended queue, so it was already closed by the
    /// time `cancel()` returned, failing the first assertion below.
    ///
    /// R1 gate (Lead 2026-10-01, FAIL 1 fix 1): the second fix's own oracle
    /// was wrong, not A4 -- `dispatch_source_cancel` is asynchronous
    /// (source.h:512); libdispatch deregisters the source on its own
    /// manager thread first, and only then submits the cancel handler to
    /// the target queue, so `testQueue.sync {}` only proves blocks enqueued
    /// *before* it ran have completed. The cancel handler can be submitted
    /// after it, racing the two assertions below against each other rather
    /// than proving the fix. Replaced the queue-drain proxy with the real
    /// close itself, routed through `syscalls.closeWatchedDirectory` (the
    /// production cancel handler's own new call, symmetric with
    /// `openDirectoryForWatching`) and observed as a typed fact.
    @Test("the watched directory descriptor stays open until source cancellation actually completes")
    func directoryDescriptorStaysOpenUntilCancellationCompletes() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cold-start-observer-a4-fd-lifetime-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let watchedDescriptor = try openRealDirectoryDescriptor(at: temporaryDirectory.path)
        // R1 gate (Lead 2026-10-01, CI fix): the watched directory's own
        // identity, captured while the descriptor is definitely still open
        // and still refers to it. This suite is not MainActor-serialized and
        // runs in the shared concurrent fast lane, where another test can
        // open a file in the gap between this test's own close and its next
        // check, and the kernel can hand that file the exact same lowest-free
        // descriptor number this test just freed -- fd numbers are reused by
        // design, not leaked. Comparing identity instead of the bare number
        // is what makes the later assertion sound under that concurrency.
        var watchedDirectoryStatBeforeCancellation = stat()
        try #require(
            fstat(watchedDescriptor, &watchedDirectoryStatBeforeCancellation) == 0,
            "expected to fstat the freshly opened directory descriptor")

        let testQueue = DispatchQueue(label: "cold-start-observer-a4-test-queue", qos: .userInitiated)
        testQueue.suspend()

        let syscalls = ColdStartObserverTests.ScriptedSyscalls()
        syscalls.directoryOpenResult = .success(watchedDescriptor)
        let directoryOpenCallSource = LocalFactSource(
            vocabulary: ColdStartObserverTests.ScriptedSyscalls.directoryOpenCallFactVocabulary())
        let directoryOpenCallRecorder = try directoryOpenCallSource.attach()
        syscalls.directoryOpenCallFactSink = directoryOpenCallSource.sink
        let directoryCloseCallSource = LocalFactSource(
            vocabulary: ColdStartObserverTests.ScriptedSyscalls.directoryCloseCallFactVocabulary())
        let directoryCloseCallRecorder = try directoryCloseCallSource.attach()
        syscalls.directoryCloseCallFactSink = directoryCloseCallSource.sink
        let observer = ColdStartObserver(syscalls: syscalls, targetQueue: testQueue)

        // Act
        async let outcome = observer.observeColdStart(
            zmxDirectory: temporaryDirectory,
            socketPath: temporaryDirectory.appending(path: "session").path,
            bootID: "test-boot-id",
            attemptID: ColdRestoreAttemptID.generate()
        )
        // R1 gate failure 1 (Lead 2026-10-01): `async let`'s child task
        // reaching the actor is not ordered against this task's own next
        // `await` -- without this wait, `cancel()` can win the race to
        // enter the actor, settling via `preSettledOutcome` before
        // `beginDiscovery` ever runs, so the directory watch source (and
        // its cancel handler, the only thing that closes `watchedDescriptor`)
        // is never created. Waiting for this fact -- fired synchronously
        // from inside `beginDiscovery`'s own non-suspending body -- makes
        // the source's existence a guaranteed fact before `cancel()` is
        // ever sent, via the actor's own serial execution, not a timing
        // assumption.
        try await directoryOpenCallRecorder.expectNext(
            in: ColdStartObserverTests.ScriptedSyscalls.directoryOpenScope, 1)
        await observer.cancel()

        // Assert: cancellation was requested, but the queue that must run
        // the cancel handler is still suspended -- the descriptor must
        // still be open.
        #expect(fcntl(watchedDescriptor, F_GETFD) != -1, "the descriptor must stay open while cancellation is pending")

        // Free the queue so the cancel handler can actually run, then await
        // the real close as a fact instead of a queue-drain proxy for it.
        testQueue.resume()
        try await directoryCloseCallRecorder.expectNext(
            in: ColdStartObserverTests.ScriptedSyscalls.directoryCloseScope, watchedDescriptor)

        // Assert: the cancel handler closed exactly this descriptor,
        // exactly once.
        #expect(syscalls.directoryCloseCallCount == 1)

        // A bare "this number is now invalid" assertion is unsound here:
        // another concurrently running test may already have reused it for
        // an unrelated file by the time this check runs, in which case
        // `fstat` succeeds. Either outcome is acceptable proof that *our*
        // directory is gone: the descriptor is dead, or it now identifies
        // something else entirely.
        var watchedDirectoryStatAfterClose = stat()
        let statResultAfterClose = fstat(watchedDescriptor, &watchedDirectoryStatAfterClose)
        let statErrnoAfterClose = errno
        if statResultAfterClose == 0 {
            let identityChanged =
                watchedDirectoryStatAfterClose.st_dev != watchedDirectoryStatBeforeCancellation.st_dev
                || watchedDirectoryStatAfterClose.st_ino != watchedDirectoryStatBeforeCancellation.st_ino
            #expect(identityChanged, "a reused descriptor number must not still identify the watched directory")
        } else {
            #expect(statErrnoAfterClose == EBADF, "an fstat failure on a closed descriptor must be exactly EBADF")
        }

        // Cleanup: already settled by the explicit cancel() above.
        _ = await outcome
    }
}
