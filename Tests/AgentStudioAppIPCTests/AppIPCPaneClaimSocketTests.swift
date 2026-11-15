import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC pane claim socket boundary")
struct AppIPCPaneClaimSocketTests {
    @Test(
        "rejected or absent login can report status, but pre-auth state and subsequent protected calls stay unchanged",
        arguments: [false, true])
    func rejectedLoginAndAbsentToken(rejected: Bool) async throws {
        let pane = UUIDv7.generate()
        let workspace = UUIDv7.generate()
        let port = RecordingSessionsPort()
        let admission = AppIPCPaneClaimAdmission(membershipRefusal: { claim in
            claim.paneId == pane && claim.workspaceId == workspace ? nil : .otherWorkspace
        })
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(channel: .stable, sessionsPort: port, paneClaimAdmission: admission) },
            body: { fixture in
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                var reader = TestFrameReader()
                if rejected {
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: JSONRPCClientRequest(
                            id: .number(1), method: "auth.login",
                            params: .object(["token": .string("deliberately-unrecognized-fixture-token")])))
                    let login = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    #expect(login.error?.code == -32_001)
                    #expect(login.result == nil)
                }
                let params = IPCSessionStatusParams(
                    paneClaim: .init(paneId: pane, workspaceId: workspace),
                    tokenOutcome: rejected ? .rejected : .absent, report: .refusal(reason: .noSessionId),
                    correlationId: UUIDv7.generate())
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(
                        id: .number(2), method: "session.status", params: JSONRPCCodec.encodeJSONValue(params)))
                let status = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(status.error == nil)
                #expect(await port.statusPaneIds == [pane])
                for (id, method) in [(3, "session.query"), (4, "session.event"), (5, "pane.context.get")] {
                    try await sendRequestWithoutBlockingCooperativePool(
                        connection: connection,
                        request: JSONRPCClientRequest(id: .number(id), method: method, params: .object([:])))
                    let denied = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                    #expect(denied.error?.code == -32_001)
                    #expect(denied.error?.data == .object(["reason": .string("intentRequiresToken")]))
                    #expect(denied.result == nil)
                }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(id: .number(6), method: "auth.status", params: .object([:])))
                let auth = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                let authStatus = try decodeResponseResult(IPCAuthStatusResult.self, from: auth)
                #expect(authStatus == .unauthenticated)
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(id: .number(7), method: "system.ping", params: .object([:])))
                let ping = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(ping.error == nil)
                #expect(await port.eventPaneIds.isEmpty)
                #expect(await port.queryPaneIds.isEmpty)
            })
    }

    @Test("a recognized pane token keeps the identity method and authenticated pre-auth status")
    func recognizedTokenRetainsIdentity() async throws {
        let pane = UUIDv7.generate()
        let port = RecordingSessionsPort()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    channel: .stable, panes: [makePaneSummary(id: pane, ordinal: 1)], sessionsPort: port)
            },
            body: { fixture in
                try fixture.server.start()
                let token = try fixture.issueTestCredential(
                    for: .pane(
                        paneId: pane, credentialRecordId: UUIDv7.generate(), status: .registered))
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                var reader = TestFrameReader()
                try await loginWithoutBlockingMainActor(
                    connection: connection, token: token, requestId: 1, reader: &reader)
                let params = IPCSessionEventParams(
                    handle: "self",
                    provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
                    event: .init(
                        name: .turnStart, conversationId: "verified", turnId: nil, requestId: nil,
                        toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()), correlationId: UUIDv7.generate()
                )
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(
                        id: .number(2), method: "session.event", params: JSONRPCCodec.encodeJSONValue(params)))
                let event = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(event.error == nil)
                #expect(await port.eventPaneIds == [pane])
                #expect(await port.statusPaneIds.isEmpty)
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(id: .number(3), method: "auth.status", params: .object([:])))
                let auth = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                let status = try decodeResponseResult(IPCAuthStatusResult.self, from: auth)
                guard case .authenticated = status else {
                    Issue.record("Token authentication was lost")
                    return
                }
            })
    }
}
