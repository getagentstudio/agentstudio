import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio App IPC service auth modes", .serialized)
struct AgentStudioAppIPCServiceAuthModeTests {
    @Test("authenticated diagnostic credential invokes a debug-testing method")
    func authenticatedDiagnosticInvokesDebugTestingMethod() async throws {
        let workspaceWindowId = UUIDv7.generate()
        let correlationId = UUIDv7.generate()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    channel: .debug,
                    uiPresentationPort: FakeUIPresentationPort(workspaceWindowId: workspaceWindowId)
                )
            },
            body: { fixture in
                try fixture.server.start()
                let token = fixture.installDebugCredential()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer {
                    connection.close()
                }
                var reader = TestFrameReader()

                try await loginWithoutBlockingMainActor(
                    connection: connection, token: token, requestId: 10, reader: &reader)
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(
                        id: .number(11),
                        method: "ui.commandBar.open",
                        params: try JSONRPCCodec.encodeJSONValue(
                            IPCCommandBarOpenParams(
                                workspaceWindowId: workspaceWindowId,
                                scope: .commands,
                                correlationId: correlationId
                            )
                        )
                    )
                )
                let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                let result = try decodeResponseResult(IPCCommandBarOpenResult.self, from: response)

                #expect(response.error == nil)
                #expect(result.workspaceWindowId == workspaceWindowId)
                #expect(result.scope == .commands)
                #expect(result.correlationId == correlationId)
            })
    }

    @Test("debug server requires an explicit diagnostic credential")
    func debugServerRequiresExplicitDiagnosticCredential() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(channel: .debug) },
            body: { fixture in
                try fixture.server.start()

                let response = try await sendRequestWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path,
                    request: JSONRPCClientRequest(
                        id: .number(1), method: "auth.login",
                        params: .object([
                            "token": .string("unregistered-diagnostic-token")
                        ]))
                )
                #expect(response.error?.code == -32_001)
            })
    }

    @Test("non-debug server channels do not admit diagnostic credentials")
    func nonDebugServerChannelsDoNotAdmitDiagnosticCredentials() async throws {
        for channel in [AgentStudioIPCChannel.stable, .beta] {
            try await withLiveServer(
                makeFixture: { try LiveServerFixture(channel: channel) },
                body: { fixture in
                    try fixture.server.start()
                    let token = fixture.installDebugCredential()

                    let response = try await sendRequestWithoutBlockingCooperativePool(
                        socketPath: fixture.paths.socketURL.path,
                        request: JSONRPCClientRequest(
                            id: .number(2), method: "auth.login",
                            params: .object([
                                "token": .string(token.rawValue)
                            ]))
                    )
                    #expect(response.error?.code == -32_001)
                })
        }
    }
}
