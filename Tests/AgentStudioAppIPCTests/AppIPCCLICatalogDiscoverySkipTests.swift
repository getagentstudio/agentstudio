import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Dispatch
import Foundation
import Synchronization
import Testing

/// The provider hooks and the model verbs run several times a turn under short
/// timeouts, so what matters is not only that they answer but that they do not
/// pull the whole self-describing catalog first. A proxy in front of the real
/// server records exactly which methods the client asks for.
///
/// The client runs in process rather than as a spawned binary. The dispatch
/// under test is `AgentStudioIPCClientCommandLineRunner`, which is the whole of
/// what the shipped CLI does; `main.swift` only binds it to argv and stdio.
/// `AppIPCDynamicCommandClientTests` keeps the subprocess cases that prove the
/// built binary itself runs.
@Suite("App IPC CLI catalog discovery skip", .serialized)
struct AppIPCCLICatalogDiscoverySkipTests {
    @Test("a session verb reaches the server without fetching the catalog")
    func sessionVerbSkipsCatalogDiscovery() async throws {
        let observed = try await runClientThroughRecordingProxy(arguments: ["message", "hi"])

        #expect(!observed.contains("system.capabilities"))
        #expect(observed.contains("session.message"))
    }

    @Test("a session method named outright also skips the catalog")
    func namedSessionMethodSkipsCatalogDiscovery() async throws {
        let observed = try await runClientThroughRecordingProxy(
            arguments: ["session.query", "--handle", "self"])

        #expect(!observed.contains("system.capabilities"))
        #expect(observed.contains("session.query"))
    }

    @Test("a bare --json on a parameterless method means no parameters")
    func bareJSONFlagMeansNoParameters() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(accessMode: .unsafeDebug, channel: .debug) },
            body: { fixture in
                try fixture.server.start()
                var environment = ProcessInfo.processInfo.environment
                environment["AGENTSTUDIO_IPC_SOCKET"] = fixture.paths.socketURL.path
                environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")

                let bare = await runClientCommandLineOffCooperativePool(
                    arguments: ["system.ping", "--json"], environment: environment)
                let plain = await runClientCommandLineOffCooperativePool(
                    arguments: ["system.ping"], environment: environment)

                #expect(bare.exitCode == 0, "stderr: \(bare.standardError)")
                #expect(bare.standardOutput == plain.standardOutput)
            })
    }

    @Test("command.execute still resolves its arguments from the live catalog")
    func commandExecuteStillDiscovers() async throws {
        let observed = try await runClientThroughRecordingProxy(
            arguments: ["command.execute", "--json", #"{"commandId":"x","correlationId":"y"}"#])

        #expect(observed.contains("system.capabilities"))
    }
}

/// Runs the CLI dispatch against a proxy that forwards to the real server and
/// records every request method the client sends.
private func runClientThroughRecordingProxy(arguments: [String]) async throws -> [String] {
    let recorder = RequestMethodRecorder()
    let proxyPath = "/tmp/asipc-skip-\(UUIDv7.generate().uuidString).sock"
    let proxy = UnixSocketListener(endpoint: UnixSocketEndpoint(path: proxyPath))
    let pumps = RecordingProxyPumpOwner()
    return try await withLiveServer(
        makeFixture: { try LiveServerFixture(accessMode: .unsafeDebug, channel: .debug) },
        releaseHeldWork: {
            proxy.stop()
            await pumps.closeAndJoin()
            try? FileManager.default.removeItem(atPath: proxyPath)
        },
        body: { fixture in
            try fixture.server.start()
            try proxy.start { clientConnection in
                guard
                    let serverConnection = try? UnixSocketClient.connect(
                        endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path))
                else {
                    clientConnection.close()
                    return
                }
                pumps.admit(client: clientConnection, server: serverConnection, recorder: recorder)
            }

            var environment = ProcessInfo.processInfo.environment
            environment["AGENTSTUDIO_IPC_SOCKET"] = proxyPath
            environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")
            _ = await runClientCommandLineOffCooperativePool(arguments: arguments, environment: environment)
            return recorder.methods()
        })
}

private struct ClientCommandLineOutcome {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// Drives the CLI dispatch on a libdispatch thread and suspends the caller.
///
/// The dispatch is synchronous and blocks on socket reads. Swift Testing runs
/// each test body as a task on the cooperative executor, whose width is the
/// machine's core count, and `AgentStudioAppIPCServer` answers every accepted
/// connection from a `Task` on that same pool. Blocking the test's own thread
/// would starve the server that has to answer this very request, which is how a
/// three-core CI runner deadlocked the fast lane. libdispatch grows threads on
/// demand, so the block lands somewhere that can afford it.
private func runClientCommandLineOffCooperativePool(
    arguments: [String],
    environment: [String: String]
) async -> ClientCommandLineOutcome {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let standardOutput = CommandLineOutputCollector()
            let standardError = CommandLineOutputCollector()
            let exitCode = AgentStudioIPCClientCommandLineRunner.run(
                props: AgentStudioIPCClientCommandLineRunner.Props(
                    arguments: arguments,
                    environment: environment,
                    executablePath: ProcessInfo.processInfo.arguments.first ?? "",
                    bundleExecutableURL: Bundle.main.executableURL,
                    standardInput: { Data() },
                    identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: { standardOutput.append($0) },
                    standardErrorSink: { standardError.append($0) }
                )
            )
            continuation.resume(
                returning: ClientCommandLineOutcome(
                    exitCode: exitCode,
                    standardOutput: standardOutput.joined(),
                    standardError: standardError.joined()
                )
            )
        }
    }
}

private func pumpRecordingRequests(
    from source: UnixSocketConnection,
    to destination: UnixSocketConnection,
    recorder: RequestMethodRecorder
) -> Task<Void, Never> {
    Task {
        await valueFromDedicatedThread {
            var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
            while true {
                guard let data = try? source.receive(maxBytes: 16_384), !data.isEmpty else { break }
                if let frames = try? decoder.append(data) {
                    for frame in frames {
                        if let request = try? JSONRPCCodec.decodeRequest(frame) {
                            recorder.record(request.method)
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

    func admit(client: UnixSocketConnection, server: UnixSocketConnection, recorder: RequestMethodRecorder) {
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

private final class RequestMethodRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ method: String) {
        lock.withLock { recorded.append(method) }
    }

    func methods() -> [String] {
        lock.withLock { recorded }
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
