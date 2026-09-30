import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioAppIPC

@Suite("App IPC finite error corrections", .serialized)
struct AppIPCErrorCorrectionTests {
    @Test("runtime errors preserve codes and expose canonical data reasons")
    func runtimeErrorsPreserveCodesAndExposeCanonicalReasons() {
        let cases: [(AppIPCRuntimeError.Reason, Int, JSONValue?)] = [
            (.targetNotFound, -32_004, .object(["reason": .string("targetNotFound")])),
            (.noRuntime, -32_005, .object(["reason": .string("runtimeNotReady")])),
            (.runtimeNotReady, -32_005, .object(["reason": .string("runtimeNotReady")])),
            (.backendUnavailable, -32_005, .object(["reason": .string("runtimeNotReady")])),
            (.validationRejected, -32_007, .object(["reason": .string("invalidParams")])),
            (.timeout, -32_009, .object(["reason": .string("timeout")])),
            (.replayGap, -32_010, .object(["reason": .string("replayGap")])),
            (.unsupportedCommand, -32_003, nil),
        ]

        for (reason, expectedCode, expectedData) in cases {
            let requestError = AgentStudioAppIPCRequestError(AppIPCRuntimeError(reason: reason))

            #expect(requestError.code == expectedCode)
            #expect(requestError.data == expectedData)
        }
    }

    @Test("a pane agent's cross-pane command is refused by name before execution")
    func crossPaneCommandIsNotYetAllowedForPaneAgent() async throws {
        let boundPaneId = UUIDv7.generate()
        let targetPaneId = UUIDv7.generate()
        let commandId = IPCCommandIdentifier(rawValue: "fixtureCrossPaneCommand")
        let correlationId = UUIDv7.generate()
        let result = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(commandId: commandId, correlationId: correlationId)
        )
        let descriptor = try makeFakeCommandDescriptor(
            FakeCommandDescriptorInput(
                id: commandId,
                executionMode: .headless,
                arguments: .noArguments,
                requiredPrivileges: [.appCommandExecute, .layoutMutate],
                dataScope: .paneContext,
                allowedTargetKinds: [],
                result: result,
                exposure: .allChannels,
                agentEligibility: .ownPane
            )
        )
        let commandPort = FakeCommandPort(
            commands: [descriptor],
            executionResultsByCommandId: [commandId.rawValue: result],
            requiredPermissionTargetByPrivilege: [
                .appCommandExecute: .pane(targetPaneId.uuidString),
                .layoutMutate: .pane(targetPaneId.uuidString),
            ]
        )
        let fixture = try LiveServerFixture(
            panes: [
                makePaneSummary(id: boundPaneId, ordinal: 1),
                makePaneSummary(id: targetPaneId, ordinal: 2),
            ],
            commandPort: commandPort,
            commandComposition: IPCCommandMethodComposition(
                compatibility: .current,
                commands: [descriptor]
            )
        )
        defer { fixture.cleanup() }
        try fixture.server.start()
        let token = try fixture.issueTestCredential(
            for: .pane(
                paneId: boundPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer { connection.close() }
        var reader = TestFrameReader()
        try await loginWithoutBlockingMainActor(
            connection: connection, token: token, requestId: 1, reader: &reader)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(2),
                method: "command.execute",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCCommandExecutionRequest(
                        commandId: commandId,
                        correlationId: correlationId,
                        arguments: .noArguments
                    )
                )
            )
        )
        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)

        #expect(response.error?.code == -32_011)
        #expect(response.error?.message == "not yet allowed")
        #expect(
            try requireCorrection(response)
                == ["reason": .string("notYetAllowed"), "name": .string(commandId.rawValue)])
        #expect(commandPort.receivedExecutionRequests.isEmpty)
    }

    @Test("cross-pane denial of an established session method returns the canonical missing grant scope")
    func crossPaneDenialReturnsCanonicalMissingGrantScope() async throws {
        let boundPaneId = UUIDv7.generate()
        let targetPaneId = UUIDv7.generate()
        let fixture = try LiveServerFixture(
            panes: [makePaneSummary(id: boundPaneId, ordinal: 1), makePaneSummary(id: targetPaneId, ordinal: 2)]
        )
        defer { fixture.cleanup() }
        try fixture.server.start()
        let token = try fixture.issueTestCredential(
            for: .pane(paneId: boundPaneId, credentialRecordId: UUIDv7.generate(), status: .registered)
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer { connection.close() }
        var reader = TestFrameReader()
        try await loginWithoutBlockingMainActor(
            connection: connection, token: token, requestId: 1, reader: &reader)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(2),
                method: "session.query",
                params: .object(["handle": .string(targetPaneId.uuidString)])
            )
        )
        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)

        #expect(response.error?.code == -32_002)
        #expect(response.error?.message == "missing grant")
        let correction = try requireCorrection(response)
        #expect(correction["reason"] == .string("missingGrant"))
        #expect(correction["fieldPath"] == .string("$.authorization"))
        let requiredScope = try decodeJSONValue(
            IPCPermissionScope.self,
            from: try #require(correction["requiredScope"])
        )
        #expect(
            requiredScope
                == IPCPermissionScope(
                    privilege: .sessionStateRead,
                    target: .pane(targetPaneId.uuidString),
                    dataScope: .sessionState
                )
        )
    }

    @Test("unknown method returns a finite correction without reflecting input")
    func unknownMethodReturnsControlledCorrection() async throws {
        let fixture = try LiveServerFixture(accessMode: .unsafeDebug, channel: .debug)
        defer { fixture.cleanup() }
        try fixture.server.start()
        let rawMethod = "private.future.method.DO_NOT_REFLECT"

        let response = try await sendRequestWithoutBlockingCooperativePool(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(id: .number(3), method: rawMethod, params: .object([:]))
        )

        #expect(response.error?.code == -32_601)
        #expect(response.error?.message == "method not found")
        let correction = try requireCorrection(response)
        #expect(
            correction == [
                "reason": .string("unknownMethod"),
                "fieldPath": .string("$.method"),
                "catalogMethod": .string("system.capabilities"),
            ])
        let encoded = try encodedError(response)
        #expect(!encoded.contains(rawMethod))
    }

    @Test("unknown command is distinct from known unavailable command")
    func unknownCommandHasControlledCatalogCorrection() async throws {
        let scenario = try makeCommandScenario()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let unknownId = "privateFutureCommandDoNotReflect"

        let unknown = try await sendCommand(
            fixture: scenario.fixture,
            commandId: unknownId,
            paneId: scenario.paneId,
            requestId: 4
        )
        #expect(unknown.error?.code == -32_003)
        let correction = try requireCorrection(unknown)
        #expect(
            correction == [
                "reason": .string("unknownCommand"),
                "fieldPath": .string("$.commandId"),
                "catalogMethod": .string("command.list"),
            ])
        let encodedUnknown = try encodedError(unknown)
        #expect(!encodedUnknown.contains(unknownId))

        let knownUnavailable = try await sendCommand(
            fixture: scenario.fixture,
            commandId: scenario.commandId.rawValue,
            paneId: scenario.paneId,
            requestId: 5
        )
        #expect(knownUnavailable.error?.code == -32_005)
        let unavailableCorrection = try requireCorrection(knownUnavailable)
        #expect(unavailableCorrection["reason"] != .string("unknownCommand"))
        #expect(scenario.commandPort.receivedExecutionRequests.count == 1)
    }

    @Test("wrong command target kind is structured and rejected before the port")
    func wrongCommandTargetKindRejectsBeforeEffect() async throws {
        let scenario = try makeCommandScenario()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()

        let response = try await sendRequestWithoutBlockingCooperativePool(
            socketPath: scenario.fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(6),
                method: "command.execute",
                params: .object([
                    "commandId": .string(scenario.commandId.rawValue),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                    "arguments": .object([
                        "kind": .string("pane"),
                        "workspaceWindowId": .string(UUIDv7.generate().uuidString),
                        "paneSelector": .string("workspace:\(UUIDv7.generate().uuidString)"),
                    ]),
                ])
            )
        )

        #expect(response.error?.code == -32_602)
        let correction = try requireCorrection(response)
        #expect(correction["fieldPath"] != nil)
        #expect(correction["reason"] != nil)
        #expect(correction["expected"] != nil)
        #expect(scenario.commandPort.receivedExecutionRequests.isEmpty)
    }
}

private struct ErrorCommandScenario {
    let fixture: LiveServerFixture
    let commandPort: FakeCommandPort
    let commandId: IPCCommandIdentifier
    let paneId: UUID
}

private func makeCommandScenario() throws -> ErrorCommandScenario {
    let commandId = IPCCommandIdentifier(rawValue: "fixturePaneCommand")
    let paneId = UUIDv7.generate()
    let correlationId = UUIDv7.generate()
    let result = IPCCommandExecutionResult.applied(
        IPCCommandAppliedResult(commandId: commandId, correlationId: correlationId)
    )
    let descriptor = try makeFakeCommandDescriptor(
        FakeCommandDescriptorInput(
            id: commandId,
            executionMode: .headless,
            arguments: .pane(
                IPCPaneCommandArguments(
                    workspaceWindowId: UUIDv7.generate(),
                    paneSelector: try IPCPaneSelector(rawValue: paneId.uuidString)
                )
            ),
            requiredPrivileges: [.appCommandExecute],
            dataScope: .unspecified,
            allowedTargetKinds: [.pane],
            result: result
        )
    )
    let commandPort = FakeCommandPort(commands: [descriptor])
    let composition = try IPCCommandMethodComposition(
        compatibility: .current,
        commands: [descriptor]
    )
    return try ErrorCommandScenario(
        fixture: LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)],
            commandPort: commandPort,
            commandComposition: composition
        ),
        commandPort: commandPort,
        commandId: commandId,
        paneId: paneId
    )
}

private func sendCommand(
    fixture: LiveServerFixture,
    commandId: String,
    paneId: UUID,
    requestId: Int
) async throws -> JSONRPCResponseMessage {
    try await sendRequestWithoutBlockingCooperativePool(
        socketPath: fixture.paths.socketURL.path,
        request: JSONRPCClientRequest(
            id: .number(requestId),
            method: "command.execute",
            params: .object([
                "commandId": .string(commandId),
                "correlationId": .string(UUIDv7.generate().uuidString),
                "arguments": .object([
                    "kind": .string("pane"),
                    "workspaceWindowId": .string(UUIDv7.generate().uuidString),
                    "paneSelector": .string(paneId.uuidString),
                ]),
            ])
        )
    )
}

private func requireCorrection(
    _ response: JSONRPCResponseMessage
) throws -> [String: JSONValue] {
    guard case .object(let correction)? = response.error?.data else {
        Issue.record("Expected finite structured correction data")
        return [:]
    }
    return correction
}

private func encodedError(_ response: JSONRPCResponseMessage) throws -> String {
    let data = try JSONEncoder().encode(response.error)
    return try #require(String(data: data, encoding: .utf8))
}
