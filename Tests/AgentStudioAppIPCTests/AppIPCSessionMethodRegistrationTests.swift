import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC session method registrations")
struct AppIPCSessionMethodRegistrationTests {
    @Test("each session registration hands its port the canonical pane")
    func registrationsResolveTheCanonicalPane() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingSessionsPort()
        let registrations = try fixture.registrations(sessionsPort: port)
        let principal = fixture.diagnosticPrincipal
        let correlationId = UUIDv7.generate()

        _ = try await fixture.registration(named: "session.report", in: registrations).invoke(
            parameters: try fixture.jsonValue(
                IPCSessionReportParams(
                    handle: "self", kind: .needsYou, explanation: "waiting", correlationId: correlationId
                )
            ),
            connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, request in
                #expect(request.requiredPrivileges == [.sessionReportWrite])
                #expect(request.dataScope == .sessionReport)
                #expect(request.target == .pane(fixture.paneId.uuidString))
            }
        )
        _ = try await fixture.registration(named: "session.message", in: registrations).invoke(
            parameters: try fixture.jsonValue(
                IPCSessionMessageParams(handle: "self", text: "hello", correlationId: correlationId)
            ),
            connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, _ in }
        )
        _ = try await fixture.registration(named: "session.event", in: registrations).invoke(
            parameters: try fixture.jsonValue(
                Self.eventParams(handle: "self", correlationId: correlationId)
            ),
            connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, _ in }
        )
        _ = try await fixture.registration(named: "session.query", in: registrations).invoke(
            parameters: try fixture.jsonValue(IPCSessionQueryParams(handle: "self")),
            connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, request in
                #expect(request.requiredPrivileges == [.sessionStateRead])
                #expect(request.dataScope == .sessionState)
            }
        )

        #expect(await port.reportPaneIds == [fixture.paneId])
        #expect(await port.messagePaneIds == [fixture.paneId])
        #expect(await port.eventPaneIds == [fixture.paneId])
        #expect(await port.queryPaneIds == [fixture.paneId])
        #expect(await port.reportedExplanations == ["waiting"])
    }

    @Test("a pane principal reporting into another pane is denied before the port runs")
    func paneprincipalCannotTargetAnotherPane() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingSessionsPort()
        let registrations = try fixture.registrations(sessionsPort: port)
        let otherPaneId = UUIDv7.generate()
        let panePrincipal = IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: fixture.runtimeId,
            accessMode: .agentStudioOnly,
            kind: .spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: fixture.workspaceId),
            approvalAuthority: .noApprovalAuthority
        )
        let authorizationService = try Self.authorizationService(registrations: registrations)

        await #expect(throws: AuthorizationError.self) {
            _ = try await fixture.registration(named: "session.report", in: registrations).invoke(
                parameters: try fixture.jsonValue(
                    IPCSessionReportParams(
                        handle: otherPaneId.uuidString,
                        kind: .done,
                        explanation: nil,
                        correlationId: UUIDv7.generate()
                    )
                ),
                connectionContext: fixture.connectionContext(principal: panePrincipal, channel: .stable),
                targetResolutionTools: fixture.targetResolutionTools(),
                authorize: { principal, request in
                    try await authorizationService.authorize(principal: principal, request: request)
                }
            )
        }
        #expect(await port.reportPaneIds.isEmpty)
    }

    @Test("a pane principal reporting into its own pane needs no extra grant")
    func paneprincipalReportsIntoItsOwnPane() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingSessionsPort()
        let registrations = try fixture.registrations(sessionsPort: port)
        let panePrincipal = IPCPrincipal(
            principalId: UUIDv7.generate(),
            runtimeId: fixture.runtimeId,
            accessMode: .agentStudioOnly,
            kind: .spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: fixture.workspaceId),
            approvalAuthority: .noApprovalAuthority
        )
        let authorizationService = try Self.authorizationService(registrations: registrations)

        _ = try await fixture.registration(named: "session.report", in: registrations).invoke(
            parameters: try fixture.jsonValue(
                IPCSessionReportParams(
                    handle: "self", kind: .done, explanation: nil, correlationId: UUIDv7.generate()
                )
            ),
            connectionContext: fixture.connectionContext(principal: panePrincipal, channel: .stable),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { principal, request in
                try await authorizationService.authorize(principal: principal, request: request)
            }
        )

        #expect(await port.reportPaneIds == [fixture.paneId])
    }

    @Test("a missing correlation is rejected as invalid parameters")
    func missingCorrelationIsInvalid() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let port = RecordingSessionsPort()
        let registrations = try fixture.registrations(sessionsPort: port)

        await #expect(throws: IPCSchemaValidationError.self) {
            _ = try await fixture.registration(named: "session.message", in: registrations).invoke(
                parameters: .object(["handle": .string("self"), "text": .string("hello")]),
                connectionContext: fixture.connectionContext(principal: fixture.diagnosticPrincipal),
                targetResolutionTools: fixture.targetResolutionTools(),
                authorize: { _, _ in }
            )
        }
        #expect(await port.messagePaneIds.isEmpty)
    }

    private static func authorizationService(
        registrations: [AnyAppIPCMethodRegistration]
    ) throws -> AuthorizationService {
        AuthorizationService(
            methodRegistry: try makeTestAppIPCMethodRegistry(
                registrations: registrations, recognizedCommands: [], channel: .stable),
            grantLedger: GrantLedger(),
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
    }

    private static func eventParams(handle: String, correlationId: UUID) -> IPCSessionEventParams {
        IPCSessionEventParams(
            handle: handle,
            provider: IPCSessionProviderIdentity(identifier: "unknown-agent", version: "0.0.1", mode: "interactive"),
            event: IPCSessionEventIdentity(
                name: .sessionStart,
                conversationId: "conversation-1",
                turnId: nil,
                requestId: nil,
                toolId: nil,
                subagentId: nil,
                occurrenceId: UUIDv7.generate()
            ),
            correlationId: correlationId
        )
    }
}
