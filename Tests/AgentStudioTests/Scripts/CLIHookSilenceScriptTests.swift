import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Real CLI hook silence", .serialized)
struct CLIHookSilenceScriptTests {
    @Test(
        "every provider hook exits zero with empty process streams",
        arguments: HookSilenceInvocation.matrix.filter { $0.condition != .slow })
    func everyHookIsSilent(invocation: HookSilenceInvocation) async throws {
        try await assertHookProcessSilence(invocation: invocation)
    }

    @Test(
        "a slow app cannot hold a hook past its product-owned bound",
        arguments: HookSilenceInvocation.matrix.filter { $0.condition == .slow })
    func slowAppStillProducesSilentExit(invocation: HookSilenceInvocation) async throws {
        try await assertHookProcessSilence(invocation: invocation)
    }

    private func assertHookProcessSilence(invocation: HookSilenceInvocation) async throws {
        let executable = try hookSilenceExecutableURL()
        let fixture = try HookSilenceProcessFixture(condition: invocation.condition)
        defer { fixture.removeFiles() }
        if invocation.condition != .down { try fixture.start() }
        let payload = try invocation.payload()
        let payloadURL = try fixture.writePayload(payload)
        if invocation.storeSetting == .fresh {
            let initialStore = try await valueFromDedicatedThread { try fixture.storeOutcome() }
            #expect(!initialStore.exists)
            #expect(initialStore.creatorFiles.isEmpty)
        }
        let environment = fixture.environment(executable: executable, storeSetting: invocation.storeSetting)
        let output: ExitedProcessOutput
        do {
            output = try await runProcessToExit(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", #"input=$1; executable=$2; shift 2; exec "$executable" "$@" < "$input""#,
                    "hook-silence-test", payloadURL.path, executable.path,
                    "hook", invocation.provider, invocation.event,
                ], environment: environment)
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
        let storeOutcome = try await valueFromDedicatedThread { try fixture.storeOutcome() }
        #expect(output.terminationStatus == 0)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError.isEmpty)
        if invocation.storeSetting == .fresh {
            #expect(storeOutcome.exists == invocation.expectsPublishedStore)
            #expect(storeOutcome.creatorFiles.isEmpty)
        }
        if invocation.condition == .outsidePane {
            #expect(fixture.requests.isEmpty)
        } else if invocation.isProjected, invocation.condition != .down {
            #expect(fixture.requests.first?.method == "auth.login")
            if invocation.condition != .slow {
                #expect(fixture.requests.contains { $0.method == "session.event" })
            }
        }
    }
}

enum HookSilenceCondition: CaseIterable, Sendable {
    case up
    case down
    case slow
    case refusing
    case outsidePane
}

enum HookSilenceStoreSetting: CaseIterable, Sendable {
    case unset
    case fresh
}

struct HookSilenceInvocation: Sendable {
    let provider: String
    let event: String
    let condition: HookSilenceCondition
    let storeSetting: HookSilenceStoreSetting

    static var matrix: [Self] {
        let verbs =
            ClaudeCodeHookEvent.allCases.map { (provider: "claude", event: $0.rawValue) }
            + CodexHookEventName.allCases.map { (provider: "codex", event: $0.rawValue) }
        let ordinaryCases: [Self] = verbs.flatMap { verb in
            HookSilenceCondition.allCases.flatMap { condition in
                let settings: [HookSilenceStoreSetting] =
                    condition == .slow ? [.unset] : HookSilenceStoreSetting.allCases
                return settings.map { setting in
                    Self(provider: verb.provider, event: verb.event, condition: condition, storeSetting: setting)
                }
            }
        }
        // Preserve every existing slow case; add only one fresh-store timeout per provider.
        let slowFreshCases: [Self] = [
            Self(
                provider: "claude", event: ClaudeCodeHookEvent.sessionStart.rawValue, condition: .slow,
                storeSetting: .fresh),
            Self(
                provider: "codex", event: CodexHookEventName.sessionStart.rawValue, condition: .slow,
                storeSetting: .fresh),
        ]
        return ordinaryCases + slowFreshCases
    }

    var isProjected: Bool {
        if provider == "claude" { return true }
        guard let name = CodexHookEventName(rawValue: event) else { return false }
        return CodexHookProjection.isProjected(name)
    }

    var expectsPublishedStore: Bool {
        guard isProjected else { return false }
        switch condition {
        case .up, .refusing: return true
        case .down, .slow, .outsidePane: return false
        }
    }

    func payload() throws -> String {
        let session = UUIDv7.generate().uuidString
        let document: [String: String] = [
            "session_id": session, "hook_event_name": event,
            "prompt_id": UUIDv7.generate().uuidString,
            "turn_id": UUIDv7.generate().uuidString,
            "tool_use_id": UUIDv7.generate().uuidString,
            "agent_id": UUIDv7.generate().uuidString,
            "tool_name": "Bash", "codex_version": CodexHookProjection.defaultProviderVersion,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        guard let text = String(data: encoded, encoding: .utf8) else { throw HookSilenceFixtureError.invalidPayload }
        return text
    }
}

private func hookSilenceExecutableURL() throws -> URL {
    guard let buildDirectory = ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"] else {
        throw HookSilenceFixtureError.missingBuildDirectory
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let buildURL =
        buildDirectory.hasPrefix("/") ? URL(fileURLWithPath: buildDirectory) : root.appending(path: buildDirectory)
    return buildURL.appending(path: "debug/agentstudio-cli")
}

/// A protocol peer controls only the external app condition. The actual built
/// CLI owns projection, deadline, streams and exit behavior. The slow peer never
/// replies: only the CLI closing its connection releases that worker. Thus the
/// test waits for the product's bound, never a test sleep or timing budget.
private final class HookSilenceProcessFixture: @unchecked Sendable {
    private let condition: HookSilenceCondition
    private let rootURL: URL
    private let socketPath: String
    private let listener: UnixSocketListener
    private let paneID = UUIDv7.generate()
    private let runtimeID = UUIDv7.generate()
    private let principalID = UUIDv7.generate()
    private let lock = NSLock()
    private var observedRequests: [JSONRPCRequest] = []
    private var connections: [UnixSocketConnection] = []
    private var workers: [DedicatedThreadCompletion] = []
    private var isClosing = false

    init(condition: HookSilenceCondition) throws {
        self.condition = condition
        rootURL = URL(fileURLWithPath: "/tmp/hook-silence-\(UUIDv7.generate().uuidString)", isDirectory: true)
        socketPath = rootURL.appending(path: "app.sock").path
        listener = UnixSocketListener(endpoint: UnixSocketEndpoint(path: socketPath))
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    var requests: [JSONRPCRequest] { lock.withLock { observedRequests } }

    func writePayload(_ payload: String) throws -> URL {
        let url = rootURL.appending(path: "hook-input.json")
        try Data(payload.utf8).write(to: url)
        return url
    }

    private var storeURL: URL { rootURL.appending(path: "store/cli.sqlite") }

    func environment(executable: URL, storeSetting: HookSilenceStoreSetting) -> [String: String] {
        var result = ["AGENTSTUDIO_CLI": executable.path, "AGENTSTUDIO_IPC_SOCKET": socketPath]
        if condition != .outsidePane { result["AGENTSTUDIO_PANE_TOKEN"] = "hook-silence-fixture-token" }
        if storeSetting == .fresh {
            result["AGENTSTUDIO_CLI_STORE"] = storeURL.path
            result["AGENTSTUDIO_CLI_STORE_CHANNEL"] = "debug"
        }
        return result
    }

    func storeOutcome() throws -> HookSilenceStoreOutcome {
        let directoryURL = storeURL.deletingLastPathComponent()
        let files =
            FileManager.default.fileExists(atPath: directoryURL.path)
            ? try FileManager.default.contentsOfDirectory(atPath: directoryURL.path) : []
        return HookSilenceStoreOutcome(
            exists: FileManager.default.fileExists(atPath: storeURL.path),
            creatorFiles: files.filter { $0.contains(".creating-") })
    }

    func start() throws {
        try listener.start { [self] connection in
            lock.withLock {
                guard !isClosing else {
                    connection.close()
                    return
                }
                connections.append(connection)
                let completion = DedicatedThreadCompletion()
                workers.append(completion)
                // The accept handler is already off-pool; submit before any Task hop.
                Thread.detachNewThread { [self] in
                    defer { completion.finish() }
                    defer { connection.close() }
                    do {
                        var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
                        while true {
                            let data = try connection.receive(maxBytes: 16_384)
                            guard !data.isEmpty else { return }
                            let frames = try decoder.append(data)
                            for frame in frames {
                                let request = try JSONRPCCodec.decodeRequest(frame)
                                lock.withLock { observedRequests.append(request) }
                                // Keep the auth reply withheld until the real CLI's call bound
                                // closes the socket. There is no release timer in this fixture.
                                if condition == .slow { continue }
                                let response: JSONRPCResponse
                                if request.method == "auth.login" {
                                    let status = IPCAuthStatusResult.authenticated(
                                        principalId: principalID, runtimeId: runtimeID,
                                        accessMode: .automationSameUser)
                                    response = .success(
                                        id: request.id, result: try JSONRPCCodec.encodeJSONValue(status))
                                } else if request.method == "session.event", condition != .refusing {
                                    guard let params = request.params else {
                                        throw HookSilenceFixtureError.missingEvent
                                    }
                                    let event = try JSONDecoder().decode(
                                        IPCSessionEventParams.self,
                                        from: JSONEncoder().encode(params))
                                    let result = IPCSessionEventResult(
                                        paneId: paneID, disposition: .admitted, correlationId: event.correlationId)
                                    response = .success(
                                        id: request.id, result: try JSONRPCCodec.encodeJSONValue(result))
                                } else {
                                    response = .failure(
                                        id: request.id,
                                        error: JSONRPCErrorPayload(
                                            code: -32_001, message: "unauthenticated",
                                            data: .object(["reason": .string("unauthenticated")])))
                                }
                                try connection.send(
                                    NDJSONFrameEncoder.encode(
                                        JSONRPCCodec.encodeResponse(response),
                                        maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
                            }
                        }
                    } catch {}
                }
            }
        }
    }

    func shutdown() async {
        await valueFromDedicatedThread { self.listener.stop() }
        let owned = lock.withLock {
            isClosing = true
            return (connections, workers)
        }
        for connection in owned.0 { connection.close() }
        for worker in owned.1 { await worker.wait() }
    }

    func removeFiles() { try? FileManager.default.removeItem(at: rootURL) }
}

private enum HookSilenceFixtureError: Error {
    case missingBuildDirectory
    case invalidPayload
    case missingEvent
}

private struct HookSilenceStoreOutcome: Sendable {
    let exists: Bool
    let creatorFiles: [String]
}
