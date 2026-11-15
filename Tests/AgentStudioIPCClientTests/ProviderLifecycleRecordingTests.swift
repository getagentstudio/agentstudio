import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Darwin
import Foundation
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Closed-app lifecycle recording")
struct ProviderLifecycleRecordingTests {
    @Test(
        "real never-connected hooks retain original params on both routes", arguments: ["SessionStart", "SessionEnd"],
        [false, true])
    func failedConnectPersistsOriginalEvent(eventName: String, tokenless: Bool) async throws {
        for refused in [false, true] {
            let observed = try await valueFromDedicatedThread {
                try collectLifecycleHook(eventName: eventName, tokenless: tokenless, refused: refused)
            }
            #expect(observed.exitCode == 0)
            #expect(observed.unexpectedWaitCount == 0)
            #expect(observed.entries.count == 1)
            guard case .sessionLifecycle(let row) = try #require(observed.entries.first) else {
                Issue.record("Missing lifecycle kind")
                return
            }
            #expect(row.paneID == observed.paneID)
            #expect(UUIDv7.isV7(row.messageID))
            #expect(row.reportedAt == Date(timeIntervalSince1970: 1))
            let original = try #require(observed.attempts.first)
            #expect(try JSONDecoder().decode(IPCSessionEventParams.self, from: Data(row.payloadJSON.utf8)) == original)
        }
    }

    @Test("Claude's real failed socket path queues only foreground lifecycle events", arguments: [false, true])
    func claudeLifecycleAndBackground(background: Bool) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try LifecycleHookFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.storeURL, channel: .debug).get()
            defer { try? writer.close() }
            var environment = fixture.environment
            if background { environment["CLAUDE_CODE_SESSION_KIND"] = "bg" }
            let timing = LifecycleDeadlineTiming()
            let code = ClaudeCodeHookInvocation.handle(
                .init(
                    arguments: ["hook", "claude", "SessionEnd"], environment: environment,
                    standardInput: { fixture.payload(eventName: "SessionEnd") }, identifierGenerator: UUIDv7.generate,
                    diagnosticSink: { _ in }, deadline: CallDeadline(limit: .seconds(2), timing: timing)))
            return LifecycleRecordingObservation(
                exitCode: code, paneID: fixture.paneID, sessionID: fixture.sessionID,
                entries: try writer.readOutbox(after: 0).get().entries, attempts: [],
                unexpectedWaitCount: timing.unexpectedWaitCount)
        }
        #expect(observed.exitCode == 0)
        #expect(observed.unexpectedWaitCount == 0)
        #expect(observed.entries.count == (background ? 0 : 1))
        if !background {
            guard case .sessionLifecycle(let row) = try #require(observed.entries.first) else {
                Issue.record("Claude emitted another outbox kind")
                return
            }
            let params = try JSONDecoder().decode(IPCSessionEventParams.self, from: Data(row.payloadJSON.utf8))
            #expect(params.provider.identifier == "claude-code")
            #expect(params.event.name == .sessionEnd)
            #expect(params.event.conversationId == observed.sessionID)
        }
    }
}

private func collectLifecycleHook(eventName: String, tokenless: Bool, refused: Bool) throws
    -> LifecycleRecordingObservation
{
    let fixture = try LifecycleHookFileFixture()
    defer { fixture.remove() }
    var environment = fixture.environment
    if tokenless { environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN") }
    let socket = refused ? makeBoundButUnlistenedSocketPath() : nil
    defer { if let socket { unlink(socket.path) } }
    if let socket {
        guard socket.bound == 0 else { throw LifecycleFixtureFailure.socketUnavailable }
        environment["AGENTSTUDIO_IPC_SOCKET"] = socket.path
    }
    let attempted = Mutex<[IPCSessionEventParams]>([])
    let wallTime = Mutex(Date(timeIntervalSince1970: 1.0006))
    let timing = LifecycleDeadlineTiming()
    let live = ProviderHookDelivery.liveIPC(exampleIdentifierProvider: UUIDv7.generate)
    let delivery = ProviderHookDelivery(
        deliver: { params, configuration, deadline in
            attempted.withLock { $0.append(params) }
            try live.deliver(params, configuration, deadline)
        },
        recordRefusal: { params, configuration, deadline in try live.recordRefusal(params, configuration, deadline) },
        reportStatus: { params, configuration, deadline in
            if case .hook(let event, let provider, _) = params.report {
                attempted.withLock {
                    $0.append(
                        .init(handle: "self", provider: provider, event: event, correlationId: params.correlationId))
                }
            }
            try live.reportStatus(params, configuration, deadline)
        })
    let code = ProviderHookInvocation.runCodexHook(
        .init(
            eventName: eventName, environment: environment,
            standardInput: {
                wallTime.withLock { $0 = Date(timeIntervalSince1970: 100) }
                return fixture.payload(eventName: eventName)
            },
            correlationIdProvider: UUIDv7.generate, delivery: delivery, standardErrorSink: { _ in },
            deadline: CallDeadline(limit: .seconds(2), timing: timing), wallNow: { wallTime.withLock { $0 } }))
    let reader = try CLIStore.openReader(url: fixture.storeURL, expectedChannel: .debug).get()
    defer { try? reader.close() }
    return .init(
        exitCode: code, paneID: fixture.paneID, sessionID: fixture.sessionID,
        entries: try reader.readOutbox(after: 0).get().entries, attempts: attempted.withLock { $0 },
        unexpectedWaitCount: timing.unexpectedWaitCount)
}

private struct LifecycleRecordingObservation: Sendable {
    let exitCode: Int32?
    let paneID: UUID
    let sessionID: String
    let entries: [CLIOutboxEntry]
    let attempts: [IPCSessionEventParams]
    let unexpectedWaitCount: Int
}

enum LifecycleFixtureFailure: Error { case socketUnavailable, invalidUTF8, hookDidNotReturn }

struct LifecycleHookFileFixture: Sendable {
    let rootURL: URL
    let storeURL: URL
    let paneID = UUIDv7.generate()
    let workspaceID = UUIDv7.generate()
    let sessionID = UUIDv7.generate().uuidString

    init() throws {
        rootURL = URL(fileURLWithPath: "/tmp").appending(path: "r3-hook-\(UUIDv7.generate())")
        storeURL = rootURL.appending(path: "cli.sqlite")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        [
            "AGENTSTUDIO_CLI_STORE": storeURL.path, "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
            "AGENTSTUDIO_PANE_ID": paneID.uuidString, "AGENTSTUDIO_WORKSPACE_ID": workspaceID.uuidString,
            "AGENTSTUDIO_PANE_TOKEN": "fixture-token",
            "AGENTSTUDIO_IPC_SOCKET": rootURL.appending(path: "missing.sock").path,
        ]
    }

    func payload(eventName: String) -> Data {
        Data("{\"session_id\":\"\(sessionID)\",\"hook_event_name\":\"\(eventName)\"}".utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }
}
