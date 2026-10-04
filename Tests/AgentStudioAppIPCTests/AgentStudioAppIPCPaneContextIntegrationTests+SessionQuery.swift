import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

extension AgentStudioAppIPCPaneContextIntegrationTests {
    @Test("session.query and pane.context.get share needsYou for an open nonblocking ask")
    func queryAndContextShareOpenAskStatus() async throws {
        try await withPaneContextIPCDomain { domain in
            let writer = try await domain.bind()
            let adapter = Self.sessionAdapter(domain)
            try await withPaneContextWire(domain: domain, sessionsPort: adapter) { _, client in
                let parameters = domain.sendParameters(
                    writer: writer,
                    shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking))
                let sent = try await client.send(parameters)
                #expect(sent == .created(id: parameters.messageId))
                let queryResponse = try await client.response(
                    method: "session.query", params: IPCSessionQueryParams(handle: "self"))
                let query = try paneContextWireResult(IPCSessionQueryResult.self, from: queryResponse)
                let context = try await client.detail()
                #expect(query.paneId == domain.paneId)
                #expect(query.sourceHealth == .live)
                #expect(query.session?.status == .needsYou(reason: .question))
                #expect(query.session == context.session)
                #expect(context.messages.map(\.id) == [parameters.messageId])
            }
        }
    }

    @Test("StopFailure is failed on both surfaces and SessionEnd retains idle ended")
    func queryAndContextShareFailureAndEnd() async throws {
        try await withPaneContextIPCDomain { domain in
            let adapter = Self.sessionAdapter(domain)
            try await withPaneContextWire(domain: domain, sessionsPort: adapter) { _, client in
                for hookName in ["SessionStart", "UserPromptSubmit", "StopFailure", "SessionEnd"] {
                    let params = try await Self.projectedSessionEvent(hookName)
                    let name = params.event.name
                    let eventResponse = try await client.response(method: "session.event", params: params)
                    let event = try paneContextWireResult(IPCSessionEventResult.self, from: eventResponse)
                    #expect(event.disposition == .admitted)
                    if name == .turnFailed || name == .sessionEnd {
                        let response = try await client.response(
                            method: "session.query", params: IPCSessionQueryParams(handle: "self"))
                        let query = try paneContextWireResult(IPCSessionQueryResult.self, from: response)
                        let context = try await client.detail()
                        let expected: IPCPaneSessionStatus =
                            name == .turnFailed
                            ? .failed(category: "authentication_failed") : .idle(state: .ended)
                        #expect(query.session?.status == expected)
                        #expect(query.session == context.session)
                        #expect(query.sourceHealth == (name == .sessionEnd ? .ended : .live))
                    }
                }
            }
        }
    }

    @Test("an unbound pane returns a required null session on the real socket")
    func queryUnboundSessionIsExplicitNull() async throws {
        try await withPaneContextIPCDomain { domain in
            try await withPaneContextWire(domain: domain, sessionsPort: Self.sessionAdapter(domain)) { _, client in
                let response = try await client.response(
                    method: "session.query", params: IPCSessionQueryParams(handle: "self"))
                let query = try paneContextWireResult(IPCSessionQueryResult.self, from: response)
                #expect(query.sourceHealth == .unbound)
                #expect(query.session == nil)
                if case .object(let fields)? = response.result {
                    #expect(Set(fields.keys) == ["paneId", "sourceHealth", "session"])
                    #expect(fields["session"] == .null)
                } else {
                    Issue.record("Expected session query result object")
                }
                let context = try await client.detail()
                #expect(context.session == nil)
            }
        }
    }

    private static func projectedSessionEvent(_ hookName: String) async throws -> IPCSessionEventParams {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let payload = try await withoutBlockingCooperativePool {
            let data = try Data(
                contentsOf: repositoryRoot.appending(
                    path: "Tests/AgentStudioIPCClientTests/Fixtures/claude-code-2.1.286/\(hookName).json"))
            guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
                throw ClaudeCodeHookInvocationError.reportRejected
            }
            // The captured end belongs to a different recorded session; all four
            // real documents must address this test's one provider conversation.
            fields["session_id"] = .string("query-status")
            return try JSONDecoder().decode(
                ClaudeCodeHookPayload.self, from: JSONEncoder().encode(JSONValue.object(fields)))
        }
        let projection = ClaudeCodeHookProjection.project(
            sourceOccurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            announcedEvent: hookName, payload: payload,
            providerVersion: ClaudeCodeProviderIdentity.supportedExactVersion,
            correlationIdentifier: UUIDv7.generate(), freshOccurrenceIdentifier: { UUIDv7.generate() })
        guard case .projected(let params) = projection else { throw ClaudeCodeHookInvocationError.reportRejected }
        return params
    }

    private static func sessionAdapter(_ domain: PaneContextIPCDomainCompanion) -> AgentStudioIPCSessionsAdapter {
        AgentStudioIPCSessionsAdapter(
            ingestion: domain.ingestion,
            providerRegistry: .init(profiles: [.claudeCodeCommandLine]), now: { domain.time.now })
    }
}
