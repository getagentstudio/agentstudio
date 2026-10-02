import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

/// `joinConnectionHandlers()` is the completion contract `AppDelegate`'s
/// production shutdown path relies on: it must not return while a connection
/// handler is still doing real work, and it must leave nothing tracked once
/// it does.
@Suite("App IPC connection handler lifecycle")
struct AgentStudioAppIPCConnectionHandlerLifecycleTests {
    @Test("a throwing live-server scope joins a handler before returning its error")
    func throwingFixtureScopeJoinsItsHeldHandler() async throws {
        let paneId = UUIDv7.generate()
        let port = SuspendingTerminalWaitPort()
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)],
            runtimePort: port
        )
        do {
            try await withLiveServer(
                makeFixture: { fixture },
                body: { fixture in
                    try fixture.server.start()
                    let connection = try await valueFromDedicatedThread {
                        try UnixSocketClient.connect(endpoint: .init(path: fixture.paths.socketURL.path))
                    }
                    defer { connection.close() }
                    try await valueFromDedicatedThread {
                        try sendRequest(
                            connection: connection,
                            request: JSONRPCClientRequest(
                                id: .number(1), method: "terminal.wait",
                                params: .object([
                                    "handle": .string("pane:1"),
                                    "condition": .string(IPCTerminalWaitCondition.commandFinished.rawValue),
                                    "timeoutSeconds": .number(60),
                                ])
                            )
                        )
                    }
                    _ = await port.waitUntilEntered()
                    throw FixtureScopeTestError.bodyFailed
                })
            Issue.record("Expected the fixture body's error")
        } catch FixtureScopeTestError.bodyFailed {
            // The fixture must preserve the original body error after joining.
        }

        let handlerCountAtScopeReturn = fixture.server.trackedConnectionHandlerCount
        let observedCancellationAtScopeReturn = port.observedCancellation
        #expect(handlerCountAtScopeReturn == 0)
        #expect(observedCancellationAtScopeReturn)
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
    }

    @Test("joinConnectionHandlers waits for a handler held inside a request, then clears its entry")
    func joinWaitsForAHeldHandlerThenClearsItsEntry() async throws {
        let paneId = UUIDv7.generate()
        let port = SuspendingTerminalWaitPort()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    accessMode: .unsafeDebug,
                    channel: .debug,
                    panes: [makePaneSummary(id: paneId, ordinal: 1)],
                    runtimePort: port
                )
            },
            body: { fixture in
                try fixture.server.start()

                // Sent from its own Task, off the cooperative pool: this request
                // parks inside the port until cancellation reaches it, so it must
                // not block the test's own async execution while it's held.
                let heldRequest = Task {
                    try await sendRequestWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path,
                        request: JSONRPCClientRequest(
                            id: .number(1),
                            method: "terminal.wait",
                            params: .object([
                                "handle": .string("pane:1"),
                                "condition": .string(IPCTerminalWaitCondition.commandFinished.rawValue),
                                "timeoutSeconds": .number(60),
                            ])
                        )
                    )
                }

                // Event-driven: resolves once the port has genuinely parked a
                // continuation, whether this call's own registration or the entry
                // itself won that race — waitUntilEntered is a latched fact, not an
                // observation of which side arrived first.
                _ = await port.waitUntilEntered()
                #expect(fixture.server.trackedConnectionHandlerCount == 1)

                await fixture.server.joinConnectionHandlers()

                #expect(port.observedCancellation)
                #expect(fixture.server.trackedConnectionHandlerCount == 0)

                // Nothing left to cancel or await: a second join is a no-op over an
                // empty tracked set.
                await fixture.server.joinConnectionHandlers()
                #expect(fixture.server.trackedConnectionHandlerCount == 0)

                _ = try? await heldRequest.value
            })
    }

    /// waitUntilEntered() awaits a latched fact — "has this fresh port's
    /// handler entered" — not which side of a race arrived first, so both
    /// orderings must resolve the same way. This exercises the waiter-first
    /// ordering causally: waitUntilAWaiterHasRegistered() is a deterministic
    /// barrier proving the wait genuinely parked before entry happens, not a
    /// hope that the scheduler picked that order.
    @Test("waitUntilEntered resolves once entry follows an already-registered waiter")
    func waitUntilEnteredResolvesWhenEntryFollowsARegisteredWaiter() async throws {
        let port = SuspendingTerminalWaitPort()
        let handle = IPCHandle(kind: .pane, reference: .canonicalUUID(UUIDv7.generate()))

        let waitObservationTask = Task { await port.waitUntilEntered() }
        _ = await port.waitUntilAWaiterHasRegistered()

        let entryTask = Task {
            try? await port.waitForTerminal(
                handle,
                condition: .commandFinished,
                timeout: .seconds(60),
                afterSequence: nil,
                ownPaneAssertion: nil
            )
        }

        #expect(await waitObservationTask.value)

        entryTask.cancel()
        _ = await entryTask.value
        #expect(port.observedCancellation)
    }

    /// Exercises the entry-first ordering causally: the second call on a
    /// port whose handler has already entered cannot observe anything but
    /// the latched fact — hasEntered only ever transitions false -> true, so
    /// by the time this call begins entry has unambiguously already
    /// happened, independent of what the first call raced against.
    @Test("waitUntilEntered resolves once entry has already happened before the call")
    func waitUntilEnteredResolvesWhenEntryPrecedesTheCall() async throws {
        let port = SuspendingTerminalWaitPort()
        let handle = IPCHandle(kind: .pane, reference: .canonicalUUID(UUIDv7.generate()))

        let waitTask = Task {
            try await port.waitForTerminal(
                handle,
                condition: .commandFinished,
                timeout: .seconds(60),
                afterSequence: nil,
                ownPaneAssertion: nil
            )
        }

        // This call's own branch is scheduler-dependent and unasserted; only
        // its completion (entry has now unambiguously happened) matters.
        _ = await port.waitUntilEntered()

        let lateObservation = await port.waitUntilEntered()
        #expect(lateObservation)

        waitTask.cancel()
        _ = try? await waitTask.value
        #expect(port.observedCancellation)
    }
}

private enum FixtureScopeTestError: Error {
    case bodyFailed
}

/// A runtime port whose `waitForTerminal` parks on a continuation until the
/// awaiting task is cancelled, so a `terminal.wait` request can hold a
/// connection handler open on command. Unlike the production runtime
/// adapter's own `waitForTerminal` (bounded only by its own timeout, not by
/// task cancellation — see the accompanying report), this fake is explicitly
/// cancellation-aware, so it proves `joinConnectionHandlers()`'s own
/// cancel-then-await mechanism in isolation.
final class SuspendingTerminalWaitPort: AppIPCRuntimePort, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var pendingWaitContinuation: CheckedContinuation<IPCTerminalWaitResult, Error>?
    nonisolated(unsafe) private var entrySignalContinuation: CheckedContinuation<Bool, Never>?
    nonisolated(unsafe) private var hasEntered = false
    nonisolated(unsafe) private var cancelled = false
    nonisolated(unsafe) private var waiterRegisteredSignalContinuation: CheckedContinuation<Bool, Never>?
    nonisolated(unsafe) private var hasRegisteredWaiter = false

    nonisolated init() {}

    nonisolated var observedCancellation: Bool {
        lock.withLock { cancelled }
    }

    /// Waits for the latched fact "this fresh port's handler has entered" —
    /// not for which side of a race arrived first. Both orderings resolve to
    /// `true`: a call that registers before entry is resumed by
    /// `markEntered()`, and a call that starts after entry already happened
    /// observes the latch directly. `hasEntered` only ever transitions
    /// false -> true, so there is nothing to race once it is set.
    nonisolated func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alreadyEntered = lock.withLock { () -> Bool in
                if hasEntered { return true }
                entrySignalContinuation = continuation
                hasRegisteredWaiter = true
                let waiterSignal = waiterRegisteredSignalContinuation
                waiterRegisteredSignalContinuation = nil
                waiterSignal?.resume(returning: true)
                return false
            }
            if alreadyEntered {
                continuation.resume(returning: true)
            }
        }
    }

    /// Confirms a `waitUntilEntered()` call has genuinely stored its
    /// continuation, so a test can construct the waiter-first ordering
    /// deterministically instead of hoping the scheduler picks it.
    nonisolated func waitUntilAWaiterHasRegistered() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alreadyRegistered = lock.withLock { () -> Bool in
                if hasRegisteredWaiter { return true }
                waiterRegisteredSignalContinuation = continuation
                return false
            }
            if alreadyRegistered {
                continuation.resume(returning: true)
            }
        }
    }

    nonisolated private func markEntered() {
        let waitingSignal = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            hasEntered = true
            let signal = entrySignalContinuation
            entrySignalContinuation = nil
            return signal
        }
        waitingSignal?.resume(returning: true)
    }

    nonisolated func terminalStatus(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws
        -> IPCTerminalStatusResult
    {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    nonisolated func terminalSnapshot(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws
        -> IPCTerminalSnapshotResult
    {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    nonisolated func sendTerminalInput(
        to _: IPCHandle,
        input _: String,
        correlationId _: UUID?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalSendInputResult {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    nonisolated func waitForTerminal(
        _: IPCHandle,
        condition _: IPCTerminalWaitCondition,
        timeout _: Duration,
        afterSequence _: UInt64?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalWaitResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pendingWaitContinuation = continuation }
                markEntered()
            }
        } onCancel: {
            let pending = lock.withLock { () -> CheckedContinuation<IPCTerminalWaitResult, Error>? in
                cancelled = true
                let continuation = pendingWaitContinuation
                pendingWaitContinuation = nil
                return continuation
            }
            pending?.resume(throwing: CancellationError())
        }
    }
}
