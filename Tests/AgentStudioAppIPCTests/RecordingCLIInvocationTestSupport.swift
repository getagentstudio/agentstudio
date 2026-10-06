import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization

struct RecordingCLIInvocationRequest: Sendable {
    enum Execution: Sendable {
        case inProcess
        case subprocess(URL)
    }

    let arguments: [String]
    var standardInput = Data()
    var authenticated = true
    var includesLiveCommand = false
    var commandArgumentExample: IPCCommandArguments = .noArguments
    var panes: [IPCPaneSummary] = []
    var runtimePort: (any AppIPCRuntimePort)?
    var correlationId = UUIDv7.generate()
    var execution: Execution = .inProcess
}

struct RecordedCLIInvocation: Sendable {
    let outcome: ClientCommandLineOutcome
    let requests: [JSONRPCRequest]
    let acceptedConnections: Int
    let executedCommands: [IPCCommandExecutionRequest]
}

struct ClientCommandLineOutcome: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

let recordedCLILiveCommandID = IPCCommandIdentifier(rawValue: "fixture.fastCLIHelp")

/// Forwards to the real server, records parsed wire requests, and joins every
/// pump before returning the observations to the test task.
func runRecordedCLIInvocation(_ request: RecordingCLIInvocationRequest) async throws -> RecordedCLIInvocation {
    let recorder = CLIRequestRecorder()
    let proxyPath = "/tmp/asipc-skip-\(UUIDv7.generate().uuidString).sock"
    let proxy = UnixSocketListener(endpoint: UnixSocketEndpoint(path: proxyPath))
    let pumps = RecordingProxyPumpOwner()
    let commandPort = try request.includesLiveCommand ? makeRecordingCLICommandPort(request) : nil
    let outcome = try await withLiveServer(
        makeFixture: { try makeRecordingCLIFixture(request, commandPort: commandPort) },
        releaseHeldWork: {
            proxy.stop()
            await pumps.closeAndJoin()
            try? FileManager.default.removeItem(atPath: proxyPath)
        },
        body: { fixture in
            try fixture.server.start()
            try proxy.start { clientConnection in
                recorder.recordConnection()
                guard
                    let serverConnection = try? UnixSocketClient.connect(
                        endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path))
                else {
                    clientConnection.close()
                    return
                }
                pumps.admit(client: clientConnection, server: serverConnection, recorder: recorder)
            }
            var environment = ["AGENTSTUDIO_IPC_SOCKET": proxyPath]
            if request.authenticated {
                environment["AGENTSTUDIO_PANE_TOKEN"] = fixture.installDebugCredential().rawValue
            }
            switch request.execution {
            case .inProcess:
                return await runClientCommandLineOffCooperativePool(
                    arguments: request.arguments, environment: environment,
                    standardInput: request.standardInput, correlationId: request.correlationId)
            case .subprocess(let executableURL):
                // Data and paths are argv, never interpolated into shell code.
                let output = try await runProcessToExit(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c", #"input=$1; executable=$2; shift 2; printf "%s" "$input" | "$executable" "$@""#,
                        "agentstudio-test",
                        (String(bytes: request.standardInput, encoding: .utf8) ?? "Invalid UTF-8 stdin"),
                        executableURL.path,
                    ] + request.arguments,
                    environment: environment)
                return ClientCommandLineOutcome(
                    exitCode: output.terminationStatus,
                    standardOutput: String(bytes: output.standardOutput, encoding: .utf8) ?? "Invalid UTF-8 stdout",
                    standardError: String(bytes: output.standardError, encoding: .utf8) ?? "Invalid UTF-8 stderr")
            }
        })
    return recorder.snapshot(outcome: outcome, executedCommands: commandPort?.receivedExecutionRequests ?? [])
}

private func makeRecordingCLIFixture(
    _ request: RecordingCLIInvocationRequest, commandPort: FakeCommandPort?
) throws -> LiveServerFixture {
    let accessMode: IPCAccessMode = request.authenticated ? .agentStudioOnly : .unsafeDebug
    guard let commandPort else {
        return try LiveServerFixture(
            accessMode: accessMode, channel: .debug, panes: request.panes,
            runtimePort: request.runtimePort ?? FakeRuntimePort())
    }
    return try LiveServerFixture(
        accessMode: accessMode, channel: .debug, panes: request.panes,
        runtimePort: request.runtimePort ?? FakeRuntimePort(), commandPort: commandPort,
        commandComposition: IPCCommandMethodComposition(compatibility: .current, commands: commandPort.commands))
}

private func makeRecordingCLICommandPort(_ request: RecordingCLIInvocationRequest) throws -> FakeCommandPort {
    let result = IPCCommandExecutionResult.applied(
        .init(commandId: recordedCLILiveCommandID, correlationId: request.correlationId))
    let descriptor = try makeFakeCommandDescriptor(
        .init(
            id: recordedCLILiveCommandID, executionMode: .headless, arguments: request.commandArgumentExample,
            requiredPrivileges: [.appCommandExecute], dataScope: .unspecified, allowedTargetKinds: [], result: result))
    return FakeCommandPort(
        commands: [descriptor], executionResultsByCommandId: [recordedCLILiveCommandID.rawValue: result])
}

/// Blocking socket IO runs on a dedicated thread. Only observations return;
/// Swift Testing assertions belong to the original test task.
func runClientCommandLineOffCooperativePool(
    arguments: [String], environment: [String: String],
    standardInput: Data = Data(), correlationId: UUID = UUIDv7.generate()
) async -> ClientCommandLineOutcome {
    await valueFromDedicatedThread {
        let standardOutput = CommandLineOutputCollector()
        let standardError = CommandLineOutputCollector()
        let exitCode = AgentStudioIPCClientCommandLineRunner.run(
            props: .init(
                arguments: arguments, environment: environment,
                executablePath: ProcessInfo.processInfo.arguments.first ?? "",
                bundleExecutableURL: Bundle.main.executableURL,
                standardInput: { standardInput }, identifierGenerator: { correlationId },
                standardOutputSink: { standardOutput.append($0) },
                standardErrorSink: { standardError.append($0) }))
        return ClientCommandLineOutcome(
            exitCode: exitCode, standardOutput: standardOutput.joined(), standardError: standardError.joined())
    }
}

private func pumpRecordingRequests(
    from source: UnixSocketConnection,
    to destination: UnixSocketConnection,
    recorder: CLIRequestRecorder
) -> Task<Void, Never> {
    Task {
        await valueFromDedicatedThread {
            var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
            while true {
                guard let data = try? source.receive(maxBytes: 16_384), !data.isEmpty else { break }
                if let frames = try? decoder.append(data) {
                    for frame in frames {
                        if let request = try? JSONRPCCodec.decodeRequest(frame) {
                            recorder.record(request)
                        }
                    }
                }
                guard (try? destination.send(data)) != nil else { break }
            }
            destination.close()
        }
    }
}

private func pumpResponses(from source: UnixSocketConnection, to destination: UnixSocketConnection) -> Task<Void, Never>
{
    Task {
        await valueFromDedicatedThread {
            while true {
                guard let data = try? source.receive(maxBytes: 16_384), !data.isEmpty else { break }
                guard (try? destination.send(data)) != nil else { break }
            }
            destination.close()
        }
    }
}

/// Owns both directions until their blocking reads have actually returned.
/// Closing the sockets, rather than cancelling their Tasks alone, unblocks IO.
private final class RecordingProxyPumpOwner: Sendable {
    private struct State {
        var isClosing = false
        var connections: [UnixSocketConnection] = []
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func admit(client: UnixSocketConnection, server: UnixSocketConnection, recorder: CLIRequestRecorder) {
        state.withLock { state in
            guard !state.isClosing else {
                client.close()
                server.close()
                return
            }
            state.connections.append(contentsOf: [client, server])
            state.tasks.append(pumpRecordingRequests(from: client, to: server, recorder: recorder))
            state.tasks.append(pumpResponses(from: server, to: client))
        }
    }

    func closeAndJoin() async {
        let owned = state.withLock { state in
            state.isClosing = true
            let owned = (connections: state.connections, tasks: state.tasks)
            state.connections.removeAll()
            state.tasks.removeAll()
            return owned
        }
        for connection in owned.connections { connection.close() }
        for task in owned.tasks { task.cancel() }
        for task in owned.tasks { await task.value }
    }
}

private final class CLIRequestRecorder: Sendable {
    private struct State {
        var requests: [JSONRPCRequest] = []
        var acceptedConnections = 0
    }

    private let state = Mutex(State())

    func recordConnection() {
        state.withLock { $0.acceptedConnections += 1 }
    }

    func record(_ request: JSONRPCRequest) {
        state.withLock { $0.requests.append(request) }
    }

    func snapshot(outcome: ClientCommandLineOutcome, executedCommands: [IPCCommandExecutionRequest])
        -> RecordedCLIInvocation
    {
        state.withLock {
            RecordedCLIInvocation(
                outcome: outcome, requests: $0.requests, acceptedConnections: $0.acceptedConnections,
                executedCommands: executedCommands)
        }
    }
}

/// Stands in for one of the process's own streams. The sinks the runner writes
/// through are the same ones `main.swift` points at `print` and `stderr`, so a
/// collected line is a line the binary would have emitted.
private final class CommandLineOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func joined() -> String {
        lock.withLock { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
    }
}
