import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@Suite("App IPC terminal wait clamp", .serialized)
struct AppIPCTerminalWaitClampTests {
    @Test(
        "a CLI subprocess receives the effective timeout and clamp flag",
        arguments: [0.0, AppPolicies.IPC.maximumTerminalWaitSeconds, AppPolicies.IPC.maximumTerminalWaitSeconds + 1])
    func subprocessReceivesClampReceipt(requestedSeconds: Double) async throws {
        let paneId = UUIDv7.generate()
        let runtime = ClampRecordingRuntimePort(paneId: paneId)
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: [
                    "terminal.wait", "--handle", "pane:1", "--condition", "commandFinished", "--timeout-seconds",
                    String(requestedSeconds), "--after-sequence", "41",
                ],
                panes: [makePaneSummary(id: paneId, ordinal: 1)], runtimePort: runtime,
                execution: .subprocess(try cliExecutableURL())))
        let effective = min(requestedSeconds, AppPolicies.IPC.maximumTerminalWaitSeconds)

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", "terminal.wait"])
        let wire = try JSONDecoder().decode(JSONValue.self, from: Data(observed.outcome.standardOutput.utf8))
        guard case .object(let fields) = wire else {
            Issue.record("wait receipt must be a flat object")
            return
        }
        #expect(fields["timeoutSeconds"] == .number(effective))
        #expect(fields["wasClamped"] == .bool(requestedSeconds > effective))
        #expect(fields["paneId"] == .string(paneId.uuidString))
        #expect(fields["condition"] == .string("commandFinished"))
        let invocation = runtime.invocation
        #expect(invocation.timeout == .seconds(effective))
        #expect(invocation.afterSequence == 41)
        #expect(invocation.handle == IPCHandle(kind: .pane, reference: .canonicalUUID(paneId)))
        let request = try #require(observed.requests.first { $0.method == "terminal.wait" })
        guard case .object(let parameters) = request.params else {
            Issue.record("wait parameters must be an object")
            return
        }
        #expect(parameters["timeoutSeconds"] == .number(requestedSeconds))
    }

    @Test("negative timeout fails locally without reaching the runtime")
    func negativeTimeoutIsRefusedLocally() async throws {
        let paneId = UUIDv7.generate()
        let runtime = ClampRecordingRuntimePort(paneId: paneId)
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: [
                    "terminal.wait", "--handle", "pane:1", "--condition", "commandFinished", "--timeout-seconds", "-1",
                ],
                panes: [makePaneSummary(id: paneId, ordinal: 1)], runtimePort: runtime))

        #expect(observed.outcome.exitCode != 0)
        #expect(observed.requests.isEmpty)
        #expect(observed.acceptedConnections == 0)
        #expect(runtime.invocation.timeout == nil)
    }
}

/// The runtime observation completes immediately; timeout is data under test,
/// never a correctness budget or wall-clock wait in this test.
private final class ClampRecordingRuntimePort: AppIPCRuntimePort, Sendable {
    private struct Invocation: Sendable {
        var handle: IPCHandle?
        var timeout: Duration?
        var afterSequence: UInt64?
    }
    private let recorded = Mutex(Invocation())
    private let paneId: UUID

    nonisolated init(paneId: UUID) { self.paneId = paneId }

    nonisolated var invocation: (handle: IPCHandle?, timeout: Duration?, afterSequence: UInt64?) {
        recorded.withLock { ($0.handle, $0.timeout, $0.afterSequence) }
    }

    func terminalStatus(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalStatusResult {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    func terminalSnapshot(_: IPCHandle, ownPaneAssertion _: AppIPCOwnPaneAssertion?) throws -> IPCTerminalSnapshotResult
    {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    func sendTerminalInput(
        to _: IPCHandle, input _: String, correlationId _: UUID?, ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalSendInputResult {
        throw AppIPCRuntimeError(reason: .noRuntime)
    }

    func waitForTerminal(
        _ handle: IPCHandle, condition: IPCTerminalWaitCondition, timeout: Duration, afterSequence: UInt64?,
        ownPaneAssertion _: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalWaitResult {
        recorded.withLock { $0 = Invocation(handle: handle, timeout: timeout, afterSequence: afterSequence) }
        return IPCTerminalWaitResult(
            paneId: paneId, condition: condition, eventName: .terminalCommandFinished, commandId: nil,
            correlationId: nil, exitCode: 0, duration: nil, healthy: nil)
    }
}
