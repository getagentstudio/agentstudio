import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio App IPC typed pane snapshot", .serialized)
struct AgentStudioAppIPCServiceContributionTests {
    @Test("system capabilities advertise the typed pane snapshot registration")
    func systemCapabilitiesAdvertiseTypedPaneSnapshot() throws {
        let fixture = try LiveServerFixture()
        defer { fixture.cleanup() }
        try fixture.server.start()
        let client = try authenticatedPaneClient(fixture: fixture)
        defer { client.connection.close() }

        try sendRequest(
            connection: client.connection,
            request: JSONRPCClientRequest(id: .number(79), method: "system.capabilities", params: .object([:]))
        )
        let response = try client.reader.receiveResponse(connection: client.connection)
        let result = try decodeResponseResult(IPCMethodCatalogResult.self, from: response)
        let paneSnapshot = result.methods.first { $0.name == "pane.snapshot" }

        #expect(response.error == nil)
        #expect(paneSnapshot?.requiredPrivileges == [.paneContextRead])
        #expect(paneSnapshot?.executionOwner == .queryReader)
        #expect(paneSnapshot?.dataScope == .paneContext)
    }

    @Test("typed pane snapshot canonicalizes a friendly handle before dispatch")
    func typedPaneSnapshotCanonicalizesFriendlyHandle() throws {
        let paneId = UUIDv7.generate()
        let queryPort = RecordingSnapshotQueryPort(
            runtimeId: UUIDv7.generate(), panes: [makePaneSummary(id: paneId, ordinal: 1)])
        let fixture = try LiveServerFixture(panes: queryPort.panes, queryPort: queryPort)
        defer { fixture.cleanup() }
        try fixture.server.start()
        let client = try authenticatedDiagnosticClient(fixture: fixture)
        defer { client.connection.close() }

        let response = try sendPaneSnapshot(client: client, handle: "pane:1")
        let result = try decodeResponseResult(IPCPaneSnapshotResult.self, from: response)

        #expect(response.error == nil)
        #expect(result.pane.id == paneId)
        #expect(queryPort.snapshotPaneIds == [paneId, paneId])
    }

    @Test("typed pane snapshot reaches a pane agent's own pane and refuses another pane by name")
    func typedPaneSnapshotAdmitsOnlyTheAgentsOwnPane() throws {
        let ownPaneId = UUIDv7.generate()
        let otherPaneId = UUIDv7.generate()
        let queryPort = RecordingSnapshotQueryPort(
            runtimeId: UUIDv7.generate(),
            panes: [makePaneSummary(id: ownPaneId, ordinal: 1), makePaneSummary(id: otherPaneId, ordinal: 2)]
        )
        let fixture = try LiveServerFixture(channel: .stable, panes: queryPort.panes, queryPort: queryPort)
        defer { fixture.cleanup() }
        try fixture.server.start()
        let client = try authenticatedPaneClient(fixture: fixture, boundPaneId: ownPaneId)
        defer { client.connection.close() }

        let own = try sendPaneSnapshot(client: client, handle: "pane:1")
        let other = try sendPaneSnapshot(client: client, handle: "pane:2")

        #expect(own.error == nil)
        #expect(try decodeResponseResult(IPCPaneSnapshotResult.self, from: own).pane.id == ownPaneId)
        #expect(other.result == nil)
        #expect(other.error?.code == -32_011)
        #expect(
            other.error?.data
                == .object(["reason": .string("notYetAllowed"), "name": .string("pane.snapshot")]))
    }

    @Test("typed pane snapshot rejects malformed parameters before dispatch")
    func typedPaneSnapshotRejectsMalformedParameters() throws {
        let scenario = try makeSnapshotScenario()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let client = try authenticatedDiagnosticClient(fixture: scenario.fixture)
        defer { client.connection.close() }

        try sendRequest(
            connection: client.connection,
            request: JSONRPCClientRequest(id: .number(85), method: "pane.snapshot", params: .object([:]))
        )
        let response = try client.reader.receiveResponse(connection: client.connection)

        #expect(response.error?.code == -32_602)
        #expect(response.error?.message == "invalid params")
        guard case .object(let correction)? = response.error?.data else {
            Issue.record("Expected structured schema correction data")
            return
        }
        #expect(correction["fieldPath"] == .string("$.handle"))
        #expect(correction["reason"] == .string("missingField"))
        #expect(correction["expected"] != nil)

        let privateValue = "fixture-private-value"
        try sendRequest(
            connection: client.connection,
            request: JSONRPCClientRequest(
                id: .number(86),
                method: "pane.snapshot",
                params: .object([
                    "handle": .string("pane:1"),
                    "privateField": .string(privateValue),
                ])
            )
        )
        let privateResponse = try client.reader.receiveResponse(connection: client.connection)
        let encodedCorrection = try JSONEncoder().encode(privateResponse.error?.data)
        let correctionText = try #require(String(data: encodedCorrection, encoding: .utf8))
        #expect(privateResponse.error?.code == -32_602)
        #expect(!correctionText.contains(privateValue))
        #expect(!correctionText.contains("privateField"))
        #expect(scenario.queryPort.snapshotPaneIds.isEmpty)
    }

    @Test("typed pane snapshot rejects a wrong target kind before dispatch")
    func typedPaneSnapshotRejectsWrongTargetKind() throws {
        let scenario = try makeSnapshotScenario()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let client = try authenticatedDiagnosticClient(fixture: scenario.fixture)
        defer { client.connection.close() }

        let response = try sendPaneSnapshot(
            client: client,
            handle: "workspace:\(UUIDv7.generate().uuidString)"
        )

        #expect(response.error?.code == -32_602)
        #expect(response.error?.message == "invalid params")
        guard case .object(let correction)? = response.error?.data else {
            Issue.record("Expected wrong-target schema correction")
            return
        }
        #expect(correction["fieldPath"] == .string("$.handle"))
        #expect(correction["reason"] == .string("invalidValue"))
        #expect(scenario.queryPort.snapshotPaneIds.isEmpty)
    }

    @Test("typed pane snapshot is unavailable before authentication")
    func typedPaneSnapshotRejectsPreAuthenticationInvocation() throws {
        let scenario = try makeSnapshotScenario()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()

        let response = try sendRequest(
            socketPath: scenario.fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(84), method: "pane.snapshot", params: .object(["handle": .string("pane:1")]))
        )

        #expect(response.error?.code == -32_001)
        #expect(response.error?.message == "unauthenticated")
        #expect(scenario.queryPort.snapshotPaneIds.isEmpty)
    }

    @Test("authorization denial permits membership lookup but prevents the snapshot handler read")
    func authorizationDenialOccursBetweenMembershipAndHandlerReads() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let queryPort = RecordingSnapshotQueryPort(
            runtimeId: fixture.runtimeId,
            panes: [makePaneSummary(id: fixture.paneId, ordinal: 1)]
        )
        let registrations = try fixture.registrations(queryPort: queryPort)
        let registration = try fixture.registration(named: "pane.snapshot", in: registrations)
        let principal = fixture.diagnosticPrincipal
        let tools = AppIPCTargetResolutionTools(canonicalizePaneHandle: { _ in
            _ = try await queryPort.snapshotPane(fixture.paneId, ownPaneAssertion: nil)
            return IPCHandle(kind: .pane, reference: .canonicalUUID(fixture.paneId))
        })

        await #expect(throws: TypedPaneSnapshotAuthorizationDenied.self) {
            try await registration.invoke(
                parameters: .object(["handle": .string("pane:1")]),
                connectionContext: fixture.connectionContext(principal: principal),
                targetResolutionTools: tools,
                authorize: { _, _ in throw TypedPaneSnapshotAuthorizationDenied() }
            )
        }
        #expect(queryPort.snapshotPaneIds == [fixture.paneId])
    }
}

private final class TypedPaneSnapshotClient {
    let connection: UnixSocketConnection
    var reader = TestFrameReader()

    init(connection: UnixSocketConnection) {
        self.connection = connection
    }
}

private struct TypedPaneSnapshotScenario {
    let paneId: UUID
    let queryPort: RecordingSnapshotQueryPort
    let fixture: LiveServerFixture
}

private func makeSnapshotScenario() throws -> TypedPaneSnapshotScenario {
    let paneId = UUIDv7.generate()
    let queryPort = RecordingSnapshotQueryPort(
        runtimeId: UUIDv7.generate(), panes: [makePaneSummary(id: paneId, ordinal: 1)])
    return try TypedPaneSnapshotScenario(
        paneId: paneId,
        queryPort: queryPort,
        fixture: LiveServerFixture(panes: queryPort.panes, queryPort: queryPort)
    )
}

private func authenticatedPaneClient(
    fixture: LiveServerFixture,
    boundPaneId: UUID? = nil
) throws -> TypedPaneSnapshotClient {
    let token = try fixture.issueTestCredential(
        for: .pane(
            paneId: boundPaneId ?? fixture.boundPaneId,
            credentialRecordId: UUIDv7.generate(),
            status: .registered
        )
    )
    let connection = try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path))
    let client = TypedPaneSnapshotClient(connection: connection)
    try login(connection: connection, token: token, requestId: 80, reader: &client.reader)
    return client
}

private func authenticatedDiagnosticClient(
    fixture: LiveServerFixture
) throws -> TypedPaneSnapshotClient {
    let token = fixture.installDebugCredential()
    let connection = try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path))
    let client = TypedPaneSnapshotClient(connection: connection)
    try login(connection: connection, token: token, requestId: 80, reader: &client.reader)
    return client
}

private func sendPaneSnapshot(
    client: TypedPaneSnapshotClient,
    handle: String
) throws -> JSONRPCResponseMessage {
    try sendRequest(
        connection: client.connection,
        request: JSONRPCClientRequest(
            id: .number(81), method: "pane.snapshot", params: .object(["handle": .string(handle)]))
    )
    return try client.reader.receiveResponse(connection: client.connection)
}

private struct TypedPaneSnapshotAuthorizationDenied: Error {}
