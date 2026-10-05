import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@MainActor
@Suite("Real CLI hook silence", .serialized)
struct CLIHookSilenceScriptTests {

    @Test(
        "a held or trickling real input pipe exhausts one hook total and exits silently without submission",
        arguments: ["claude", "codex"], [false, true])
    func heldStandardInputExhaustsHookTotal(provider: String, hasPartialInput: Bool) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try HookSilenceProcessFixture(condition: .up)
            defer { fixture.removeFiles() }
            let pipe = Pipe()
            defer {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            if hasPartialInput {
                try pipe.fileHandleForWriting.write(contentsOf: Data("{\"session_id\":\"unfinished".utf8))
            }
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flagsBefore = Darwin.fcntl(descriptor, F_GETFL)
            let timing = HookInputDeadlineTiming(inputDescriptor: descriptor, readsPartialInput: hasPartialInput)
            let streams = Mutex<[String]>([])
            let ordinaryInputReads = Mutex(0)
            let event = "SessionStart"
            let status = AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: ["hook", provider, event],
                    environment: fixture.environment(
                        executable: URL(fileURLWithPath: "/fixture/agentstudio-cli"), storeSetting: .fresh),
                    executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                    standardInput: {
                        ordinaryInputReads.withLock { $0 += 1 }
                        return Data()
                    },
                    identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: { line in streams.withLock { $0.append(line) } },
                    standardErrorSink: { line in streams.withLock { $0.append(line) } },
                    standardInputFileDescriptor: descriptor, deadlineTiming: timing))
            return HookInputObservation(
                exitCode: status, streamLines: streams.withLock { $0 }, waitBudgets: timing.waits,
                controlledElapsed: timing.elapsed, inputFlagsRestored: Darwin.fcntl(descriptor, F_GETFL) == flagsBefore,
                storeOutcome: try fixture.storeOutcome(), ordinaryInputReadCount: ordinaryInputReads.withLock { $0 },
                inputWaitEvents: timing.inputWaitEvents)
        }
        #expect(observed.exitCode == 0)
        #expect(observed.streamLines.isEmpty)
        #expect(observed.controlledElapsed == CLIPolicy.hookCallLimit)
        #expect(observed.waitBudgets == (hasPartialInput ? [.seconds(2), .seconds(1)] : [.seconds(2)]))
        #expect(observed.inputFlagsRestored)
        #expect(!observed.storeOutcome.exists)
        #expect(observed.storeOutcome.creatorFiles.isEmpty)
        #expect(observed.ordinaryInputReadCount == 0)
        #expect(observed.inputWaitEvents.allSatisfy { $0 == Int16(POLLIN) })
    }

    @Test("outside-pane hooks leave even a held input pipe unread", arguments: ["claude", "codex"])
    func outsidePaneNeverWaitsForInput(provider: String) async throws {
        let observed = await valueFromDedicatedThread {
            let pipe = Pipe()
            defer {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            let timing = HookInputDeadlineTiming(
                inputDescriptor: pipe.fileHandleForReading.fileDescriptor, readsPartialInput: false)
            let streams = Mutex<[String]>([])
            let ordinaryInputReads = Mutex(0)
            let status = AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: ["hook", provider, "SessionStart"],
                    environment: [:], executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                    standardInput: {
                        ordinaryInputReads.withLock { $0 += 1 }
                        return Data()
                    },
                    identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: { line in streams.withLock { $0.append(line) } },
                    standardErrorSink: { line in streams.withLock { $0.append(line) } },
                    standardInputFileDescriptor: pipe.fileHandleForReading.fileDescriptor, deadlineTiming: timing))
            return OutsidePaneInputObservation(
                exitCode: status, streamLines: streams.withLock { $0 }, waitBudgets: timing.waits,
                controlledElapsed: timing.elapsed, ordinaryInputReadCount: ordinaryInputReads.withLock { $0 },
                inputWaitEvents: timing.inputWaitEvents)
        }
        #expect(observed.exitCode == 0)
        #expect(observed.streamLines.isEmpty)
        #expect(observed.waitBudgets.isEmpty)
        #expect(observed.controlledElapsed == .zero)
        #expect(observed.ordinaryInputReadCount == 0)
        #expect(observed.inputWaitEvents.isEmpty)
    }

    @Test(
        "input and authentication share the ingress total without touching a CLI store",
        arguments: ["claude", "codex"])
    func inputAndNetworkShareOneHookTotal(provider: String) async throws {
        let fixture = try HookSilenceProcessFixture(condition: .slow)
        defer { fixture.removeFiles() }
        let observed: HookTotalObservation
        do {
            observed = try await valueFromDedicatedThread {
                try fixture.start()
                let pipe = Pipe()
                defer { try? pipe.fileHandleForReading.close() }
                let event = "SessionStart"
                let payload = try JSONSerialization.data(withJSONObject: [
                    "session_id": UUIDv7.generate().uuidString,
                    "conversation_id": UUIDv7.generate().uuidString,
                    "generation_id": UUIDv7.generate().uuidString,
                    "hook_event_name": event,
                ])
                try pipe.fileHandleForWriting.write(contentsOf: payload)
                try pipe.fileHandleForWriting.close()
                let timing = HookInputDeadlineTiming(
                    inputDescriptor: pipe.fileHandleForReading.fileDescriptor,
                    readsPartialInput: true, completedInput: true)
                let streams = Mutex<[String]>([])
                let ordinaryInputReads = Mutex(0)
                let status = AgentStudioIPCClientCommandLineRunner.run(
                    props: .init(
                        arguments: ["hook", provider, event],
                        environment: fixture.environment(
                            executable: URL(fileURLWithPath: "/fixture/agentstudio-cli"), storeSetting: .fresh),
                        executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                        standardInput: {
                            ordinaryInputReads.withLock { $0 += 1 }
                            return Data()
                        },
                        identifierGenerator: { UUIDv7.generate() },
                        standardOutputSink: { line in streams.withLock { $0.append(line) } },
                        standardErrorSink: { line in streams.withLock { $0.append(line) } },
                        standardInputFileDescriptor: pipe.fileHandleForReading.fileDescriptor, deadlineTiming: timing))
                return HookTotalObservation(
                    exitCode: status, streamLines: streams.withLock { $0 }, controlledElapsed: timing.elapsed,
                    networkWaitBudgets: timing.networkWaits, ordinaryInputReadCount: ordinaryInputReads.withLock { $0 },
                    inputWaitEvents: timing.inputWaitEvents)
            }
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
        let store = try await valueFromDedicatedThread { try fixture.storeOutcome() }
        #expect(observed.exitCode == 0)
        #expect(observed.streamLines.isEmpty)
        #expect(observed.controlledElapsed == CLIPolicy.hookCallLimit)
        #expect(!observed.networkWaitBudgets.isEmpty)
        #expect(observed.networkWaitBudgets.allSatisfy { $0 == .seconds(1) })
        #expect(observed.ordinaryInputReadCount == 0)
        #expect(observed.inputWaitEvents.allSatisfy { $0 == Int16(POLLIN) })
        #expect(!fixture.requests.contains { $0.method == "session.event" })
        #expect(!store.exists)
        #expect(store.creatorFiles.isEmpty)
    }

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
            #expect(!initialStore.directoryExists)
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
            #expect(!storeOutcome.exists)
            #expect(!storeOutcome.directoryExists)
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

func hookSilenceExecutableURL() throws -> URL {
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
final class HookSilenceProcessFixture: @unchecked Sendable {
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
    private var advertisedReadThrough: IPCCLIStoreReadThrough?

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

    var storeURL: URL { rootURL.appending(path: "store/cli.sqlite") }

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
        let directoryExists = FileManager.default.fileExists(atPath: directoryURL.path)
        let files =
            directoryExists
            ? try FileManager.default.contentsOfDirectory(atPath: directoryURL.path) : []
        return HookSilenceStoreOutcome(
            exists: FileManager.default.fileExists(atPath: storeURL.path), directoryExists: directoryExists,
            creatorFiles: files.filter { $0.contains(".creating-") })
    }

    func advertiseReadThrough(_ mark: IPCCLIStoreReadThrough) {
        lock.withLock { advertisedReadThrough = mark }
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
                                        accessMode: .automationSameUser,
                                        cliStoreReadThrough: lock.withLock { advertisedReadThrough })
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

/// A controlled readiness dependency advances only when the real reader waits.
/// The pipe writer stays open; no task, sleeper or detached read needs joining.
private final class HookInputDeadlineTiming: CallDeadlineTiming, Sendable {
    private struct State: Sendable {
        let origin = ContinuousClock.now
        var elapsed: Duration = .zero
        var waits: [Duration] = []
        var inputReadCount = 0
        var networkWaits: [Duration] = []
        var inputWaitEvents: [Int16] = []
    }

    private let state = Mutex(State())
    private let readsPartialInput: Bool
    private let inputDescriptor: Int32
    private let completedInput: Bool

    init(inputDescriptor: Int32, readsPartialInput: Bool, completedInput: Bool = false) {
        self.inputDescriptor = inputDescriptor
        self.readsPartialInput = readsPartialInput
        self.completedInput = completedInput
    }

    var waits: [Duration] { state.withLock { $0.waits } }
    var elapsed: Duration { state.withLock { $0.elapsed } }
    var networkWaits: [Duration] { state.withLock { $0.networkWaits } }
    var inputWaitEvents: [Int16] { state.withLock { $0.inputWaitEvents } }

    func now() -> ContinuousClock.Instant { state.withLock { $0.origin.advanced(by: $0.elapsed) } }

    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) throws -> CallDeadlineReadiness {
        state.withLock { observation in
            observation.waits.append(timeout)
            if fileDescriptor != inputDescriptor {
                observation.networkWaits.append(timeout)
                if events == Int16(POLLOUT) { return .ready(events) }
                observation.elapsed += timeout
                return .timedOut
            }
            observation.inputWaitEvents.append(events)
            observation.inputReadCount += 1
            if readsPartialInput && observation.inputReadCount == 1 {
                // Known written bytes are ready. One second belongs to input;
                // the next readiness wait must receive only the remaining second.
                observation.elapsed += .seconds(1)
                return .ready(Int16(POLLIN))
            }
            if completedInput { return .ready(Int16(POLLIN)) }
            observation.elapsed += timeout
            return .timedOut
        }
    }
}

private struct HookTotalObservation: Sendable {
    let exitCode: Int32
    let streamLines: [String]
    let controlledElapsed: Duration
    let networkWaitBudgets: [Duration]
    let ordinaryInputReadCount: Int
    let inputWaitEvents: [Int16]
}

private struct HookInputObservation: Sendable {
    let exitCode: Int32
    let streamLines: [String]
    let waitBudgets: [Duration]
    let controlledElapsed: Duration
    let inputFlagsRestored: Bool
    let storeOutcome: HookSilenceStoreOutcome
    let ordinaryInputReadCount: Int
    let inputWaitEvents: [Int16]
}

private struct OutsidePaneInputObservation: Sendable {
    let exitCode: Int32
    let streamLines: [String]
    let waitBudgets: [Duration]
    let controlledElapsed: Duration
    let ordinaryInputReadCount: Int
    let inputWaitEvents: [Int16]
}

struct HookSilenceStoreOutcome: Sendable {
    let exists: Bool
    let directoryExists: Bool
    let creatorFiles: [String]
}
