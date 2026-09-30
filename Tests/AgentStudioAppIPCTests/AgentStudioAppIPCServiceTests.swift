import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio

@Suite("AgentStudio App IPC service shell", .serialized)
struct AgentStudioAppIPCServiceTests {
    @Test("composes service from configuration and protocol ports")
    func composesServiceFromConfigurationAndProtocolPorts() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let runtimeId = UUIDv7.generate()
        let configuration = AgentStudioAppIPCConfiguration(
            runtimeId: runtimeId,
            accessMode: .agentStudioOnly
        )

        let eventBroker = IPCEventBroker()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .debug)
        let service = AgentStudioAppIPCService(
            configuration: configuration,
            ports: AgentStudioAppIPCPorts(
                queryPort: FakeQueryPort(),
                layoutPort: FakeLayoutPort(),
                runtimePort: FakeRuntimePort(),
                bridgePort: FakeBridgePort(),
                commandPort: FakeCommandPort(),
                uiPresentationPort: FakeUIPresentationPort(),
                sidebarPort: FakeSidebarPort(),
                sessionsPort: RecordingSessionsPort(),
                permissionApprovalPort: FakePermissionApprovalPort(),
                ownPaneScopePort: StaticOwnPaneScopePort(),
                agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
            ),
            methodRegistry: registry,
            eventBroker: eventBroker
        )

        #expect(service.configuration.runtimeId == runtimeId)
        #expect(service.configuration.accessMode == .agentStudioOnly)
        #expect(service.methodRegistry.capabilities.methods.count == 48)
        #expect(
            service.methodRegistry.capabilities.methods.filter { $0.name == "system.capabilities" }.count == 1
        )
        #expect(service.eventBroker === eventBroker)
    }

    @Test("server starts Unix socket and answers pre-auth ping")
    func serverStartsUnixSocketAndAnswersPreAuthPing() throws {
        let fixture = try LiveServerFixture()
        defer {
            fixture.cleanup()
        }
        try fixture.server.start(processIdentifier: 12_345, startedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(id: .number(1), method: "system.ping", params: .object([:]))
        )

        #expect(response.id == .number(1))
        guard case .object(let result)? = response.result else {
            Issue.record("expected object result")
            return
        }
        #expect(result["ok"] == .bool(true))
        #expect(result["runtimeId"] == .string(fixture.runtimeId.uuidString))

        let metadataData = try Data(contentsOf: fixture.paths.metadataURL)
        let metadata = try JSONDecoder.iso8601.decode(AgentStudioIPCRuntimeMetadata.self, from: metadataData)
        #expect(metadata.runtimeId == fixture.runtimeId)
        #expect(metadata.processIdentifier == 12_345)
        #expect(metadata.socketPath == fixture.paths.socketURL.path)
    }

    @Test("server authenticates and serves a command on the same socket")
    func serverAuthenticatesAndServesCommandOnSameSocket() async throws {
        let fixture = try LiveServerFixture()
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()
        let token = try fixture.issueTestCredential(
            for: .pane(
                paneId: fixture.boundPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var frameReader = TestFrameReader()

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(9),
                method: "system.ping",
                params: .object([:])
            )
        )
        let ping = try await frameReader.receiveResponseWithoutBlockingMainActor(connection: connection)
        try #require(ping.id == .number(9))
        try #require(ping.error == nil, "server must remain running immediately before auth.login")

        try await loginWithoutBlockingMainActor(
            connection: connection,
            token: token,
            requestId: 10,
            reader: &frameReader
        )

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(id: .number(11), method: "system.identify", params: .object([:]))
        )
        let identify = try await frameReader.receiveResponseWithoutBlockingMainActor(connection: connection)

        try #require(identify.id == .number(11))
        try #require(identify.error == nil)
        guard case .object(let result)? = identify.result else {
            Issue.record("expected identify result")
            return
        }
        #expect(result["runtimeId"] == .string(fixture.runtimeId.uuidString))
        #expect(result["accessMode"] == .string(IPCAccessMode.agentStudioOnly.rawValue))
    }

    @Test("server rejects authenticated commands before login")
    func serverRejectsAuthenticatedCommandsBeforeLogin() throws {
        let fixture = try LiveServerFixture()
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(id: .number(2), method: "terminal.status", params: .object([:]))
        )

        #expect(response.id == .number(2))
        #expect(response.error?.code == -32_001)
        #expect(response.error?.message == "unauthenticated")
    }

    @Test("debug unsafe no-auth reports an explicit unsafe debug principal")
    func debugUnsafeNoAuthReportsExplicitUnsafeDebugPrincipal() throws {
        let fixture = try LiveServerFixture(accessMode: .unsafeDebug, channel: .debug)
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(id: .number(60), method: "auth.status", params: .object([:]))
        )

        #expect(response.id == .number(60))
        #expect(response.error == nil)
        guard case .object(let result)? = response.result else {
            Issue.record("expected auth status result")
            return
        }
        #expect(result["authenticated"] == .bool(true))
        #expect(result["accessMode"] == .string(IPCAccessMode.unsafeDebug.rawValue))
    }

    @Test("debug unsafe no-auth authorizes terminal send without login")
    func debugUnsafeNoAuthAuthorizesTerminalSendWithoutLogin() throws {
        let paneId = UUID()
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)],
            runtimePort: FakeRuntimePort(successfulPaneId: paneId)
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(61),
                method: "terminal.send",
                params: .object([
                    "handle": .string("pane:1"),
                    "input": .string("echo unsafe-debug\n"),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ])
            )
        )

        #expect(response.id == .number(61))
        #expect(response.error == nil)
        let result = try decodeResponseResult(IPCTerminalSendInputResult.self, from: response)
        #expect(result.paneId == paneId)
        #expect(result.disposition == .accepted)
    }

    @Test("failed auth login prevents unsafe debug fallback on same socket")
    func failedAuthLoginPreventsUnsafeDebugFallbackOnSameSocket() throws {
        let paneId = UUID()
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)],
            runtimePort: FakeRuntimePort(successfulPaneId: paneId)
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let connection = try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path))
        defer {
            connection.close()
        }
        var reader = TestFrameReader()

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(62),
                method: "auth.login",
                params: .object(["token": .string("invalid-token")])
            )
        )
        let loginResponse = try reader.receiveResponse(connection: connection)
        #expect(loginResponse.id == .number(62))
        #expect(loginResponse.error?.code == -32_001)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(63),
                method: "terminal.send",
                params: .object([
                    "handle": .string("pane:1"),
                    "input": .string("echo should-not-run\n"),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ])
            )
        )
        let sendResponse = try reader.receiveResponse(connection: connection)
        #expect(sendResponse.id == .number(63))
        #expect(sendResponse.error?.code == -32_001)
        #expect(sendResponse.error?.message == "unauthenticated")
    }

    @Test("terminal wait forwards after sequence to runtime port")
    func terminalWaitForwardsAfterSequenceToRuntimePort() throws {
        let paneId = UUID()
        let runtimePort = RecordingWaitRuntimePort(successfulPaneId: paneId)
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)],
            runtimePort: runtimePort
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(64),
                method: "terminal.wait",
                params: .object([
                    "handle": .string("pane:1"),
                    "condition": .string(IPCTerminalWaitCondition.commandFinished.rawValue),
                    "timeoutSeconds": .number(1),
                    "afterSequence": .number(41),
                ])
            )
        )

        #expect(response.id == .number(64))
        #expect(response.error == nil)
        #expect(runtimePort.lastAfterSequence == 41)
        #expect(runtimePort.lastHandle == IPCHandle(kind: .pane, reference: .canonicalUUID(paneId)))
        let result = try decodeResponseResult(IPCTerminalWaitResult.self, from: response)
        #expect(result.paneId == paneId)
        #expect(result.condition == .commandFinished)
    }

    @Test("terminal wait rejects out-of-range timeout before runtime dispatch")
    func terminalWaitRejectsOutOfRangeTimeoutBeforeRuntimeDispatch() throws {
        let paneId = UUID()
        let runtimePort = RecordingWaitRuntimePort(successfulPaneId: paneId)
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)],
            runtimePort: runtimePort
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let response = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(65),
                method: "terminal.wait",
                params: .object([
                    "handle": .string("pane:1"),
                    "condition": .string(IPCTerminalWaitCondition.commandFinished.rawValue),
                    "timeoutSeconds": .number(86_400.001),
                ])
            )
        )

        #expect(response.id == .number(65))
        #expect(response.error?.code == -32_602)
        #expect(response.error?.message == "invalid params")
        #expect(response.result == nil)
        #expect(runtimePort.lastHandle == nil)
    }

    @Test("non-debug server channels ignore unsafe no-auth access mode")
    func nonDebugServerChannelsIgnoreUnsafeNoAuthAccessMode() throws {
        let fixture = try LiveServerFixture(accessMode: .unsafeDebug, channel: .beta)
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let status = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(id: .number(62), method: "auth.status", params: .object([:]))
        )
        #expect(status.error == nil)
        guard case .object(let statusResult)? = status.result else {
            Issue.record("expected auth status result")
            return
        }
        #expect(statusResult["authenticated"] == .bool(false))

        let version = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(63),
                method: "system.version",
                params: .object([:])
            )
        )
        #expect(version.error?.code == -32_001)
        #expect(version.error?.message == "unauthenticated")
    }

    @Test("explicit diagnostic credential can authenticate two connections")
    func explicitDiagnosticCredentialAuthenticatesTwoConnections() throws {
        let fixture = try LiveServerFixture(channel: .debug)
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()
        let token = fixture.installDebugCredential()

        for requestId in [65, 66] {
            let connection = try UnixSocketClient.connect(
                endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
            )
            defer { connection.close() }
            var reader = TestFrameReader()
            try login(connection: connection, token: token, requestId: requestId, reader: &reader)
            try sendRequest(
                connection: connection,
                request: JSONRPCClientRequest(
                    id: .number(requestId + 1),
                    method: "auth.status",
                    params: .object([:])
                )
            )
            let response = try reader.receiveResponse(connection: connection)
            #expect(response.error == nil)
        }
    }

    @Test("unsafe debug client can invoke semantic layout control methods")
    func unsafeDebugClientCanInvokeSemanticLayoutControlMethods() throws {
        let paneId = UUID()
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)]
        )
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()

        let split = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(71),
                method: "pane.split",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCPaneSplitParams(
                        handle: "pane:1", direction: .right, correlationId: UUIDv7.generate())
                )
            )
        )
        #expect(split.error == nil)
        let splitResult = try decodeResponseResult(IPCPaneSplitResult.self, from: split)
        #expect(splitResult.targetPaneId == paneId)
        #expect(splitResult.direction == .right)

        let close = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(74),
                method: "pane.close",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCPaneCloseParams(handle: "pane:1", correlationId: UUIDv7.generate())
                )
            )
        )
        #expect(close.error == nil)
        let closeResult = try decodeResponseResult(IPCPaneCloseResult.self, from: close)
        #expect(closeResult.paneId == paneId)

        let drawerAdd = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(75),
                method: "drawer.addPane",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCDrawerAddPaneParams(
                        parentPaneHandle: "pane:1", correlationId: UUIDv7.generate())
                )
            )
        )
        #expect(drawerAdd.error == nil)
        let drawerAddResult = try decodeResponseResult(IPCDrawerAddPaneResult.self, from: drawerAdd)
        #expect(drawerAddResult.parentPaneId == paneId)

        let drawerToggle = try sendRequest(
            socketPath: fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(76),
                method: "drawer.toggle",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCDrawerToggleParams(
                        parentPaneHandle: "pane:1", correlationId: UUIDv7.generate())
                )
            )
        )
        #expect(drawerToggle.error == nil)
        let drawerToggleResult = try decodeResponseResult(IPCDrawerToggleResult.self, from: drawerToggle)
        #expect(drawerToggleResult.parentPaneId == paneId)
    }

    @Test("server canonicalizes friendly pane ordinals before cross-pane command authorization")
    func serverCanonicalizesFriendlyPaneOrdinalsBeforeCrossPaneCommandAuthorization() throws {
        let scenario = try OrdinalCommandAuthorizationScenario.make()
        defer {
            scenario.fixture.cleanup()
        }
        try scenario.fixture.server.start()

        let token = try scenario.fixture.issueTestCredential(
            for: .pane(
                paneId: scenario.secondPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: scenario.fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var reader = TestFrameReader()
        try login(connection: connection, token: token, requestId: 40, reader: &reader)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(41),
                method: "command.execute",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCCommandExecutionRequest(
                        commandId: scenario.commandId,
                        correlationId: scenario.correlationId,
                        arguments: .pane(
                            IPCPaneCommandArguments(
                                workspaceWindowId: scenario.workspaceWindowId,
                                paneSelector: try IPCPaneSelector(rawValue: "pane:1")
                            )
                        )
                    )
                )
            )
        )

        // The friendly ordinal names another pane, so an own-pane command is
        // refused by name after the canonical identity is known.
        let response = try reader.receiveResponse(connection: connection)
        #expect(response.id == .number(41))
        #expect(response.error?.code == -32_011)
        #expect(response.error?.message == "not yet allowed")
        #expect(
            response.error?.data
                == .object([
                    "reason": .string("notYetAllowed"), "name": .string(scenario.commandId.rawValue),
                ]))
        guard case .pane(let preparedArguments)? = scenario.commandPort.preparedRequests.first?.arguments else {
            Issue.record("Expected the command port to receive canonical pane arguments")
            return
        }
        #expect(preparedArguments.paneSelector.rawValue == scenario.firstPaneId.uuidString)
        #expect(scenario.underlyingCommandPort.receivedExecutionRequests.isEmpty)
    }

    @Test("server stop closes existing authenticated socket sessions")
    func serverStopClosesExistingAuthenticatedSocketSessions() async throws {
        let fixture = try LiveServerFixture()
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()
        let token = try fixture.issueTestCredential(
            for: .pane(
                paneId: fixture.boundPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var reader = TestFrameReader()
        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(49),
                method: "system.ping",
                params: .object([:])
            )
        )
        let ping = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        try #require(ping.id == .number(49))
        try #require(ping.error == nil, "server must remain running immediately before auth.login")

        try await loginWithoutBlockingMainActor(
            connection: connection,
            token: token,
            requestId: 50,
            reader: &reader
        )

        fixture.server.stop()

        do {
            try sendRequest(
                connection: connection,
                request: JSONRPCClientRequest(id: .number(51), method: "system.identify", params: .object([:]))
            )
            let responseData = try connection.receive(maxBytes: 4096)
            if responseData.isEmpty {
                return
            }
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
            let frames = try decoder.append(responseData)
            let response = try JSONRPCCodec.decodeResponse(try #require(frames.first))
            #expect(response.error?.code == -32_001)
        } catch let error as UnixSocketTransportError {
            #expect(error.reason == .writeFailed || error.reason == .readFailed)
        }
    }

    @Test("pane invalidation closes existing bound principal socket sessions")
    func paneInvalidationClosesExistingBoundPrincipalSocketSessions() throws {
        let fixture = try LiveServerFixture()
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()
        let token = try fixture.issueTestCredential(
            for: .pane(
                paneId: fixture.boundPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer {
            connection.close()
        }
        var reader = TestFrameReader()
        try login(connection: connection, token: token, requestId: 52, reader: &reader)

        fixture.server.invalidatePrincipals(boundToPaneId: fixture.boundPaneId.uuidString)

        do {
            try sendRequest(
                connection: connection,
                request: JSONRPCClientRequest(id: .number(53), method: "system.identify", params: .object([:]))
            )
            let responseData = try connection.receive(maxBytes: 4096)
            #expect(responseData.isEmpty)
        } catch let error as UnixSocketTransportError {
            #expect(error.reason == .writeFailed || error.reason == .readFailed)
        }
    }

    @Test("authenticated pane requests recheck canonical membership")
    func authenticatedPaneRequestsRecheckCanonicalMembership() throws {
        let membership = PaneMembershipGate()
        let fixture = try LiveServerFixture(
            canonicalPaneMembership: { _, _ in membership.isMember }
        )
        defer { fixture.cleanup() }
        try fixture.server.start()
        let token = try fixture.issueTestCredential(
            for: .pane(
                paneId: fixture.boundPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer { connection.close() }
        var reader = TestFrameReader()
        try login(connection: connection, token: token, requestId: 60, reader: &reader)

        membership.setMember(false)
        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(id: .number(61), method: "system.version", params: .object([:]))
        )
        let response = try reader.receiveResponse(connection: connection)

        #expect(response.error?.code == -32_001)
        #expect(response.error?.message == "unauthenticated")
    }

    @Test("pane authentication uses canonical fixture credential metadata")
    func paneAuthenticationUsesCanonicalFixtureCredentialMetadata() throws {
        let fixture = try LiveServerFixture()
        defer {
            fixture.cleanup()
        }
        try fixture.server.start()
        let token = try fixture.issueTestCredential(
            for: .pane(
                paneId: fixture.boundPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: fixture.paths.socketURL.path)
        )
        defer { connection.close() }
        var reader = TestFrameReader()
        try login(connection: connection, token: token, requestId: 67, reader: &reader)
        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(id: .number(68), method: "system.identify", params: .object([:]))
        )
        let response = try reader.receiveResponse(connection: connection)
        #expect(response.error == nil)
    }
}

private final class PaneMembershipGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIsMember = true

    var isMember: Bool { lock.withLock { storedIsMember } }

    func setMember(_ isMember: Bool) {
        lock.withLock { storedIsMember = isMember }
    }
}

private final class PreparedCommandRecordingPort: AppIPCCommandPort, @unchecked Sendable {
    private let underlying: FakeCommandPort
    private let lock = NSLock()
    nonisolated(unsafe) private var preparedRequestsStorage: [IPCCommandExecutionRequest] = []

    nonisolated init(underlying: FakeCommandPort) {
        self.underlying = underlying
    }

    nonisolated var preparedRequests: [IPCCommandExecutionRequest] {
        lock.withLock { preparedRequestsStorage }
    }

    func prepareCommand(
        _ params: IPCCommandExecutionRequest,
        principal: IPCPrincipal,
        tools: AppIPCTargetResolutionTools
    ) async throws -> AppIPCPreparedCommand {
        let prepared = try await underlying.prepareCommand(params, principal: principal, tools: tools)
        lock.withLock { preparedRequestsStorage.append(prepared.request) }
        return prepared
    }

    func executeCommand(
        _ params: IPCCommandExecutionRequest, ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) async throws -> IPCCommandExecutionResult {
        try await underlying.executeCommand(params, ownPaneAssertion: ownPaneAssertion)
    }
}

private struct OrdinalCommandAuthorizationScenario {
    let firstPaneId: UUID
    let secondPaneId: UUID
    let workspaceWindowId: UUID
    let commandId: IPCCommandIdentifier
    let correlationId: UUID
    let commandPort: PreparedCommandRecordingPort
    let underlyingCommandPort: FakeCommandPort
    let fixture: LiveServerFixture

    static func make() throws -> Self {
        let firstPaneId = UUIDv7.generate()
        let secondPaneId = UUIDv7.generate()
        let workspaceWindowId = UUIDv7.generate()
        let commandId = IPCCommandIdentifier(rawValue: "fixtureOrdinalCommand")
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
                        workspaceWindowId: workspaceWindowId,
                        paneSelector: try IPCPaneSelector(rawValue: "pane:1")
                    )
                ),
                requiredPrivileges: [.appCommandExecute, .layoutMutate],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                result: result,
                exposure: .allChannels,
                agentEligibility: .ownPane
            )
        )
        let underlyingCommandPort = FakeCommandPort(
            commands: [descriptor],
            executionResultsByCommandId: [commandId.rawValue: result],
            requiredPermissionTargetByPrivilege: [
                .appCommandExecute: .pane(firstPaneId.uuidString),
                .layoutMutate: .pane(firstPaneId.uuidString),
            ]
        )
        let commandPort = PreparedCommandRecordingPort(underlying: underlyingCommandPort)
        return try Self(
            firstPaneId: firstPaneId,
            secondPaneId: secondPaneId,
            workspaceWindowId: workspaceWindowId,
            commandId: commandId,
            correlationId: correlationId,
            commandPort: commandPort,
            underlyingCommandPort: underlyingCommandPort,
            fixture: LiveServerFixture(
                panes: [
                    makePaneSummary(id: firstPaneId, ordinal: 1),
                    makePaneSummary(id: secondPaneId, ordinal: 2),
                ],
                commandPort: commandPort,
                commandComposition: IPCCommandMethodComposition(
                    compatibility: .current,
                    commands: [descriptor]
                )
            )
        )
    }
}
