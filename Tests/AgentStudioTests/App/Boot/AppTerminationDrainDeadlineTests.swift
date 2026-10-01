import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// `applicationShouldTerminate` returns `.terminateLater`, so the AppKit quit
/// completes only when the reply fires. A drain stage that never finishes must
/// therefore not be able to withhold it.
@MainActor
@Suite("App termination drain deadline", .serialized)
struct AppTerminationDrainDeadlineTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("the AppKit reply fires when a drain stage never completes")
    func replyFiresWhenTheDrainNeverCompletes() async {
        let recorder = TerminationReplyRecorder()
        // A drain that can only be released by the test, so nothing but the
        // deadline can produce the reply.
        let neverCompletingDrain = ReleasableGate()

        await replyToApplicationTerminationAfterBoundedDrain(
            timeout: .seconds(2),
            delay: .immediate,
            drain: { await neverCompletingDrain.wait() },
            reply: { recorder.record($0) }
        )

        #expect(recorder.outcomes == [.timedOut])
        neverCompletingDrain.release()
    }

    @Test("a drain that finishes reports completion and replies once")
    func replyReportsCompletionForAFinishedDrain() async {
        let recorder = TerminationReplyRecorder()
        // A deadline the test holds open, so a completing drain is the only
        // way the reply can be produced.
        let withheldDeadline = ReleasableGate()

        await replyToApplicationTerminationAfterBoundedDrain(
            timeout: .seconds(2),
            delay: AsyncDelay { _ in await withheldDeadline.wait() },
            drain: {},
            reply: { recorder.record($0) }
        )

        #expect(recorder.outcomes == [.completed])
        withheldDeadline.release()
    }
    @Test("a termination reply that returns finishes the quit exactly once, after the reply")
    func returningReplyFinishesTheQuitOnce() {
        let stages = TerminationStageRecorder()

        // A reply that returns is AppKit cancelling a quit it was asked to commit.
        replyToTerminationFinishingIfCancelled(
            reply: { stages.record("reply") },
            finishCancelledTermination: { stages.record("finish") }
        )

        #expect(stages.names == ["reply", "finish"])
    }

    @Test("finishing a cancelled termination runs will-terminate work and exits once")
    func cancelledTerminationExitsOnce() {
        let delegate = AppDelegate()
        var exitStatuses: [Int32] = []
        delegate.exitProcess = { exitStatuses.append($0) }

        delegate.finishTerminationCancelledAfterDrain()

        #expect(exitStatuses == [EXIT_SUCCESS])
    }

    @Test("the workspace flush completes even when the IPC drain never does")
    func workspaceFlushSurvivesAnUnfinishedIPCDrain() async {
        let stages = TerminationStageRecorder()
        let neverCompletingIPCDrain = ReleasableGate()

        let outcome = await runBoundedIPCDrainAfterWorkspaceFlush(
            timeout: .seconds(2),
            delay: .immediate,
            workspaceFlush: { stages.record("workspaceFlush") },
            ipcDrain: {
                stages.record("ipcDrainStarted")
                await neverCompletingIPCDrain.wait()
                stages.record("ipcDrainCompleted")
            }
        )

        #expect(outcome == .timedOut)
        // The flush is durable before the drain is even attempted, so the
        // drain overrunning its bound cannot cost the workspace layout.
        #expect(stages.names.first == "workspaceFlush")
        #expect(!stages.names.contains("ipcDrainCompleted"))
        neverCompletingIPCDrain.release()
    }

    @Test("no IPC request is accepted once the stop stage has run")
    func ipcStopRefusesFurtherRequests() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let beforeStop = try await harness.response(method: "system.ping", params: .object([:]))
            #expect(beforeStop.error == nil)

            await harness.appDelegate.stopAcceptingAppIPCConnections()

            // Connecting must fail outright rather than be refused after login:
            // the listener is closed, so there is no path by which a late
            // command.execute or Bridge open reaches the app and mutates state the
            // workspace flush is about to write.
            let endpoint = UnixSocketEndpoint(path: harness.socketPath)
            await #expect(throws: (any Error).self) {
                try await withoutBlockingCooperativePool { try UnixSocketClient.connect(endpoint: endpoint).close() }
            }
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("a still-open connection does not delay the workspace flush, and the real credential drain still closes it")
    func stillOpenConnectionDoesNotDelayTheWorkspaceFlush() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let endpoint = UnixSocketEndpoint(path: harness.socketPath)
            let connection = try await withoutBlockingCooperativePool {
                try UnixSocketClient.connect(endpoint: endpoint)
            }
            let loginRequest = try JSONRPCClientRequest(
                id: .number(1),
                method: "auth.login",
                params: .object(["token": .string(harness.token.rawValue)])
            )
            try await withoutBlockingCooperativePool {
                try connection.send(
                    try NDJSONFrameEncoder.encode(
                        try JSONRPCCodec.encodeRequest(loginRequest), maxFrameBytes: 65_536))
            }
            // Causal barrier: bytes back prove the server's handler accepted
            // the connection, processed this request, and looped back to its
            // next blocking read. The connection is still open and the
            // handler still tracked when the drain below begins — a real
            // in-flight handler, not a synthetic stand-in.
            let responseBytes = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try connection.receive(maxBytes: 4096))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            #expect(!responseBytes.isEmpty)
            #expect(harness.appDelegate.appIPCServer?.trackedConnectionHandlerCount == 1)

            // The real production ordering: ingress stop precedes the
            // flush-then-drain bound below, and closing this connection here
            // is what unblocks its handler's blocking read — drain no longer
            // re-closes connections as a safety net, so this call is load
            // bearing, not incidental.
            await harness.appDelegate.stopAcceptingAppIPCConnections()

            // A deadline that cannot fire on its own: `.completed` below can
            // only be produced by the real drain finishing, never by winning
            // a race against the wall clock — the timeout argument is
            // unreachable, not a correctness budget.
            let withheldDeadline = ReleasableGate()
            let stages = TerminationStageRecorder()
            let outcome = await runBoundedIPCDrainAfterWorkspaceFlush(
                timeout: .seconds(2),
                delay: AsyncDelay { _ in await withheldDeadline.wait() },
                workspaceFlush: { stages.record("workspaceFlush") },
                ipcDrain: {
                    stages.record("ipcDrainStarted")
                    // The real production function: its joinConnectionHandlers()
                    // observes the handler this connection's closure above
                    // already unblocked, rather than that join outliving the
                    // deadline this call is bounded by.
                    await harness.appDelegate.drainAppIPCCredentialPersistence()
                    stages.record("ipcDrainCompleted")
                }
            )
            withheldDeadline.release()

            #expect(outcome == .completed)
            #expect(stages.names == ["workspaceFlush", "ipcDrainStarted", "ipcDrainCompleted"])
            #expect(harness.appDelegate.appIPCServer == nil)
            connection.close()
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("a completing IPC drain still runs after the workspace flush")
    func ipcDrainRunsAfterTheWorkspaceFlush() async {
        let stages = TerminationStageRecorder()
        let withheldDeadline = ReleasableGate()

        let outcome = await runBoundedIPCDrainAfterWorkspaceFlush(
            timeout: .seconds(2),
            delay: AsyncDelay { _ in await withheldDeadline.wait() },
            workspaceFlush: { stages.record("workspaceFlush") },
            ipcDrain: { stages.record("ipcDrain") }
        )

        #expect(outcome == .completed)
        #expect(stages.names == ["workspaceFlush", "ipcDrain"])
        withheldDeadline.release()
    }
}

@MainActor
private final class TerminationStageRecorder {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }
}

@MainActor
private final class TerminationReplyRecorder {
    private(set) var outcomes: [TerminationDrainOutcome] = []

    func record(_ outcome: TerminationDrainOutcome) {
        outcomes.append(outcome)
    }
}

/// Suspends until the test releases it, with no timer of its own, so a case
/// proves the deadline rather than a race between two sleeps. Every gate is
/// released before its test returns, so no task outlives the case.
private final class ReleasableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = lock.withLock { () -> Bool in
                guard !isReleased else { return true }
                self.continuation = continuation
                return false
            }
            if shouldResumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isReleased = true
            let stored = continuation
            continuation = nil
            return stored
        }
        pending?.resume()
    }
}

extension AsyncDelay {
    /// Fires the deadline without spending wall-clock time.
    fileprivate static let immediate = Self { _ in }
}
