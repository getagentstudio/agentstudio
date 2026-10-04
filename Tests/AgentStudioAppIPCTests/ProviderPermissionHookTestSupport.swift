import AgentStudioCore
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

enum PermissionHookTestProvider: String, CaseIterable, Sendable {
    case claude
    case codex

    var identifier: String { self == .claude ? "claude-code" : "codex" }
    var version: String { self == .claude ? "2.1.286" : "0.154.0" }
}

enum PermissionHookTestFailure: CaseIterable {
    case missingPolicy
    case malformedPayload
    case wrongCredential
}

struct PermissionHookTestContext: Sendable {
    let cli: S5PaneCLIContext
    let provider: PermissionHookTestProvider
    let conversationId: String
    let payload: Data
    let clients: PermissionHookTestClients

    var domain: PaneContextIPCDomainCompanion { cli.domain }
    var port: S5RecordingPaneContextPort { cli.port }
    var paneId: PaneId { .init(existingUUID: domain.paneId) }
    var uiAdapter: PaneContextUIAdapter { .init(service: domain.service) }

    func openApproval() async throws -> AgentMessageDetail {
        let result = await uiAdapter.readDetail(.init(paneId: paneId, page: .first))
        guard case .detail(let detail) = result else {
            throw PermissionHookTestError.detailUnavailable
        }
        let message = try #require(
            detail.messages.first {
                if case .ask(.approval, _, .blocking, .open) = $0.shape { return true }
                return false
            })
        if case .ask(_, let form, .blocking(let deadline), _) = message.shape {
            #expect(deadline.timeIntervalSince(domain.time.now) == 60)
            #expect(
                form
                    == .choice(
                        options: [
                            .init(id: try AskChoiceId("Allow"), label: "Allow"),
                            .init(id: try AskChoiceId("Deny"), label: "Deny"),
                            .init(id: try AskChoiceId("Ask"), label: "Ask"),
                        ], allowsMultiple: false))
        }
        return message
    }

    func decision(in output: ClientCommandLineOutcome) throws -> PermissionHookDecisionValue? {
        guard !output.standardOutput.isEmpty else { return nil }
        let value = try JSONDecoder().decode(
            PermissionHookTestDecisionDocument.self, from: Data(output.standardOutput.utf8))
        #expect(value.hookSpecificOutput.hookEventName == "PermissionRequest")
        return value.hookSpecificOutput.decision
    }

    func startHook(
        failure: PermissionHookTestFailure? = nil,
        eventDelivery: ProviderHookDelivery? = nil
    ) -> Task<ClientCommandLineOutcome, Never> {
        var environment = cli.callEnvironment(store: nil, useStore: false)
        // Both ambient identities intentionally disagree with the hook document.
        environment["CLAUDE_CODE_SESSION_ID"] = "inherited-claude"
        environment["CODEX_THREAD_ID"] = "inherited-codex"
        if failure == .wrongCredential { environment["AGENTSTUDIO_PANE_TOKEN"] = "invalid-credential" }
        let callEnvironment = environment
        let input = failure == .malformedPayload ? Data("not json".utf8) : payload
        var arguments = ["hook", provider.rawValue, "PermissionRequest"]
        if provider == .claude { arguments += ["--provider-version", provider.version] }
        if failure != .missingPolicy { arguments += ["--permission-policy", "wait"] }
        let callArguments = arguments
        let task = Task {
            let output = await valueFromDedicatedThread {
                let collector = PermissionHookOutputCollector()
                let props = AgentStudioIPCClientCommandLineRunner.Props(
                    arguments: callArguments, environment: callEnvironment,
                    executablePath: cli.executableURL.path, bundleExecutableURL: nil,
                    standardInput: { input }, identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: collector.appendOutput, standardErrorSink: collector.appendError,
                    now: { domain.time.now })
                let status: Int32
                if let eventDelivery {
                    status =
                        ProviderPermissionHookInvocation.handle(
                            props: props, sourceOccurredAt: domain.time.now, startedAt: ContinuousClock.now,
                            eventDelivery: eventDelivery) ?? 0
                } else {
                    status = AgentStudioIPCClientCommandLineRunner.run(props: props)
                }
                return collector.outcome(status)
            }
            domain.facts.sink(domain.paneId, .clientExited)
            return output
        }
        clients.register(task)
        return task
    }
}

func withPermissionHookTestContext(
    provider: PermissionHookTestProvider,
    liveSessions: Bool = false,
    _ body: (PermissionHookTestContext) async throws -> Void
) async throws {
    try await withS5PaneCLIContext(liveSessions: liveSessions) { cli in
        let conversationId = UUIDv7.generate().uuidString
        _ = try await cli.domain.bind(
            conversationId: conversationId,
            provider: .init(
                providerIdentifier: provider.identifier, exactVersion: provider.version, operatingMode: "interactive"))
        let payload = try JSONEncoder().encode(
            JSONValue.object([
                "session_id": .string(conversationId), "hook_event_name": .string("PermissionRequest"),
                "tool_name": .string("tool-proof"), "tool_input": .object(["command": .string("operation-proof")]),
                "turn_id": .string("same-turn"), "prompt_id": .string("same-turn"),
            ]))
        let clients = PermissionHookTestClients()
        let context = PermissionHookTestContext(
            cli: cli, provider: provider, conversationId: conversationId, payload: payload, clients: clients)
        do {
            try await body(context)
            await clients.finish(service: cli.domain.service)
        } catch {
            cli.domain.access.releaseHeldWork()
            await clients.finish(service: cli.domain.service)
            throw error
        }
    }
}

final class PermissionHookTestClients: Sendable {
    private let tasks = Mutex<[Task<ClientCommandLineOutcome, Never>]>([])
    func register(_ task: Task<ClientCommandLineOutcome, Never>) { tasks.withLock { $0.append(task) } }
    func finish(service: PaneContextService) async {
        await service.stop()
        for task in tasks.withLock({ $0 }) { _ = await task.value }
    }
}

private final class PermissionHookOutputCollector: Sendable {
    private struct Streams: Sendable {
        var output: [String] = []
        var error: [String] = []
    }
    private let streams = Mutex(Streams())
    func appendOutput(_ text: String) { streams.withLock { $0.output.append(text) } }
    func appendError(_ text: String) { streams.withLock { $0.error.append(text) } }
    func outcome(_ status: Int32) -> ClientCommandLineOutcome {
        streams.withLock {
            .init(exitCode: status, standardOutput: $0.output.joined(), standardError: $0.error.joined())
        }
    }
}

private struct PermissionHookTestDecisionDocument: Decodable {
    let hookSpecificOutput: PermissionHookTestSpecificDecision
}

private struct PermissionHookTestSpecificDecision: Decodable {
    let hookEventName: String
    let decision: PermissionHookDecisionValue
}

private enum PermissionHookTestError: Error { case detailUnavailable }
