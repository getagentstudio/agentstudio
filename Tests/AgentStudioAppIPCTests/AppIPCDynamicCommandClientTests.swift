import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Dispatch
import Foundation
import Testing

@Suite("Live dynamic command ClientCore integration", .serialized)
struct AppIPCDynamicCommandClientTests {
    @Test("ClientCore discovers lists and executes one live typed command")
    func clientDiscoversListsAndExecutesTypedCommand() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let client = AgentStudioIPCClient(
            configuration: AgentStudioIPCClientConfiguration(socketPath: scenario.fixture.paths.socketURL.path),
            descriptors: []
        )

        let methodCatalog = try await client.discoverCatalogWithoutBlockingCooperativePool(requestID: 10)
        let discovery = try IPCCommandDiscovery(methodCatalog: methodCatalog)
        let listResponse = try requireSuccess(
            try await client.callWithoutBlockingCooperativePool(
                discovery.commandListInvocation, requestID: 20))
        let commandCatalog = try discovery.decodeCommandCatalog(from: listResponse.normalizedResult)
        let invocation = try commandCatalog.makeInvocation(
            commandId: scenario.commandId,
            correlationId: scenario.correlationId,
            arguments: .noArguments
        )
        let executeResponse = try requireSuccess(
            try await client.callWithoutBlockingCooperativePool(invocation, requestID: 30))
        let result = try commandCatalog.decodeResult(executeResponse.normalizedResult, for: invocation)

        #expect(methodCatalog.methods.contains { $0.name == "command.list" })
        #expect(methodCatalog.methods.contains { $0.name == "command.execute" })
        #expect(result.commandId == scenario.commandId)
        #expect(result.correlationId == scenario.correlationId)
        #expect(scenario.commandPort.receivedExecutionRequests.count == 1)
        #expect(scenario.commandPort.receivedExecutionRequests.first?.commandId == scenario.commandId)
        #expect(scenario.commandPort.receivedExecutionRequests.first?.correlationId == scenario.correlationId)
    }

    @Test("unknown identity and wrong variant are refused before the command port")
    func discoveryRefusesUnknownIdentityAndWrongVariantBeforePort() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let client = AgentStudioIPCClient(
            configuration: AgentStudioIPCClientConfiguration(socketPath: scenario.fixture.paths.socketURL.path),
            descriptors: []
        )
        let discovery = try IPCCommandDiscovery(
            methodCatalog: try await client.discoverCatalogWithoutBlockingCooperativePool())
        let listResponse = try requireSuccess(
            try await client.callWithoutBlockingCooperativePool(
                discovery.commandListInvocation, requestID: 10))
        let commandCatalog = try discovery.decodeCommandCatalog(from: listResponse.normalizedResult)

        #expect(throws: IPCCommandDiscoveryError.self) {
            _ = try commandCatalog.makeInvocation(
                commandId: IPCCommandIdentifier(rawValue: "futureCommand"),
                correlationId: UUIDv7.generate(),
                arguments: .noArguments
            )
        }
        #expect(throws: IPCCommandDiscoveryError.self) {
            _ = try commandCatalog.makeInvocation(
                commandId: scenario.commandId,
                correlationId: UUIDv7.generate(),
                arguments: .repository(IPCRepositoryCommandArguments(repoId: UUIDv7.generate()))
            )
        }
        #expect(scenario.commandPort.receivedExecutionRequests.isEmpty)
    }

    @Test("server rejects a command result whose correlation differs from its request")
    func serverRejectsMismatchedCommandResultIdentity() async throws {
        let scenario = try DynamicCommandScenario.make(resultCorrelationId: UUIDv7.generate())
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let client = AgentStudioIPCClient(
            configuration: AgentStudioIPCClientConfiguration(socketPath: scenario.fixture.paths.socketURL.path),
            descriptors: []
        )
        let discovery = try IPCCommandDiscovery(
            methodCatalog: try await client.discoverCatalogWithoutBlockingCooperativePool())
        let listResponse = try requireSuccess(
            try await client.callWithoutBlockingCooperativePool(discovery.commandListInvocation))
        let commandCatalog = try discovery.decodeCommandCatalog(from: listResponse.normalizedResult)
        let invocation = try commandCatalog.makeInvocation(
            commandId: scenario.commandId,
            correlationId: scenario.correlationId,
            arguments: .noArguments
        )

        switch try await client.callWithoutBlockingCooperativePool(invocation, requestID: 40) {
        case .success:
            Issue.record("Mismatched command result must not cross the server boundary")
        case .remoteFailure(let failure):
            #expect(failure.code == -32_602)
        }
        #expect(scenario.commandPort.receivedExecutionRequests.count == 1)
    }

    @Test("raw server requests reject unknown identity and wrong variant before execution")
    func rawServerRequestsRejectInvalidCommandSelectionBeforePort() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()

        let unknownResponse = try await sendRequestWithoutBlockingCooperativePool(
            socketPath: scenario.fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(45),
                method: "command.execute",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCCommandExecutionRequest(
                        commandId: IPCCommandIdentifier(rawValue: "futureCommand"),
                        correlationId: UUIDv7.generate(),
                        arguments: .noArguments
                    )
                )
            )
        )
        #expect(unknownResponse.error?.code == -32_003)
        #expect(unknownResponse.error?.message == "unsupported capability")
        #expect(scenario.commandPort.receivedExecutionRequests.isEmpty)

        let wrongVariantResponse = try await sendRequestWithoutBlockingCooperativePool(
            socketPath: scenario.fixture.paths.socketURL.path,
            request: JSONRPCClientRequest(
                id: .number(46),
                method: "command.execute",
                params: try JSONRPCCodec.encodeJSONValue(
                    IPCCommandExecutionRequest(
                        commandId: scenario.commandId,
                        correlationId: UUIDv7.generate(),
                        arguments: .repository(
                            IPCRepositoryCommandArguments(repoId: UUIDv7.generate())
                        )
                    )
                )
            )
        )
        #expect(wrongVariantResponse.error?.code == -32_602)
        #expect(wrongVariantResponse.error?.message == "invalid params")
        #expect(scenario.commandPort.receivedExecutionRequests.isEmpty)
    }

    @Test("one authenticated socket can list and execute after its single login")
    func oneAuthenticatedConnectionSupportsMultipleCommandCalls() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let token = scenario.fixture.installDebugCredential()
        let connection = try UnixSocketClient.connect(
            endpoint: UnixSocketEndpoint(path: scenario.fixture.paths.socketURL.path))
        defer { connection.close() }
        var reader = TestFrameReader()
        try await loginWithoutBlockingMainActor(
            connection: connection, token: token, requestId: 50, reader: &reader)

        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(id: .number(51), method: "command.list", params: .object([:]))
        )
        let listResponse = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        let catalog = try decodeResponseResult(IPCCommandCatalogResult.self, from: listResponse)
        #expect(catalog.commands.map(\.id) == [scenario.commandId])

        let request = IPCCommandExecutionRequest(
            commandId: scenario.commandId,
            correlationId: scenario.correlationId,
            arguments: .noArguments
        )
        try sendRequest(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(52),
                method: "command.execute",
                params: try JSONRPCCodec.encodeJSONValue(request)
            )
        )
        let executeResponse = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        let result = try decodeResponseResult(IPCCommandExecutionResult.self, from: executeResponse)

        #expect(result.commandId == scenario.commandId)
        #expect(result.correlationId == scenario.correlationId)
        #expect(scenario.commandPort.receivedExecutionRequests == [request])
    }

    @Test("built CLI lists and executes through the live dynamic registry")
    func builtCLIListsAndExecutesLiveCommand() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let executableURL = try cliExecutableURL()
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTSTUDIO_IPC_SOCKET"] = scenario.fixture.paths.socketURL.path
        environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")

        let list = try await runCLI(
            executableURL: executableURL,
            arguments: ["command.list"],
            environment: environment
        )
        #expect(list.exitCode == 0)
        #expect(list.standardError.isEmpty)
        let commandCatalog = try JSONDecoder().decode(IPCCommandCatalogResult.self, from: list.standardOutput)
        #expect(commandCatalog.commands.map(\.id) == [scenario.commandId])

        let request = IPCCommandExecutionRequest(
            commandId: scenario.commandId,
            correlationId: scenario.correlationId,
            arguments: .noArguments
        )
        let requestJSON = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        let execute = try await runCLI(
            executableURL: executableURL,
            arguments: ["command.execute", "--json", requestJSON],
            environment: environment
        )
        #expect(execute.exitCode == 0)
        #expect(execute.standardError.isEmpty)
        let result = try JSONDecoder().decode(IPCCommandExecutionResult.self, from: execute.standardOutput)
        #expect(result.commandId == scenario.commandId)
        #expect(result.correlationId == scenario.correlationId)
        #expect(scenario.commandPort.receivedExecutionRequests == [request])
    }

    @Test("built CLI reports terminal wait timeout by its documented reason")
    func builtCLIRendersTerminalWaitTimeout() async throws {
        let paneId = UUIDv7.generate()
        let fixture = try LiveServerFixture(
            accessMode: .unsafeDebug,
            channel: .debug,
            panes: [makePaneSummary(id: paneId, ordinal: 1)]
        )
        defer { fixture.cleanup() }
        try fixture.server.start()

        let result = try await runCLI(
            executableURL: cliExecutableURL(),
            arguments: [
                "terminal.wait",
                "--handle", paneId.uuidString,
                "--condition", "titleChanged",
                "--timeout-seconds", "1",
            ],
            environment: makeCLIEnvironment(socketPath: fixture.paths.socketURL.path)
        )
        let structuredError = try requireStructuredCLIError(result)
        let errorObject = try #require(
            JSONSerialization.jsonObject(with: result.standardError) as? [String: Any]
        )

        #expect(structuredError.reason == "timeout")
        #expect(Set(errorObject.keys) == ["reason"])
        #expect(errorObject["reason"] as? String == "timeout")
    }

    @Test("built CLI renders an unknown dynamic command correction without reflecting its identifier")
    func builtCLIRendersUnknownDynamicCommandCorrection() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let executableURL = try cliExecutableURL()
        let environment = makeCLIEnvironment(for: scenario)
        let privateMarker = "PRIVATE-COMMAND-ID-MUST-NOT-REFLECT"

        let unknown = try await runCLI(
            executableURL: executableURL,
            arguments: [
                "command.execute", "--json",
                try commandRequestJSON(
                    commandId: IPCCommandIdentifier(rawValue: privateMarker),
                    correlationId: UUIDv7.generate(),
                    arguments: .noArguments
                ),
            ],
            environment: environment
        )
        let unknownError = try requireStructuredCLIError(unknown)
        #expect(unknownError.reason == "unknownCommand")
        #expect(unknownError.fieldPath == "$.commandId")
        #expect(unknownError.catalogMethod == "command.list")
        #expect(unknownError.expected == "an identifier advertised by command.list")
        let standardError = try #require(String(data: unknown.standardError, encoding: .utf8))
        #expect(!standardError.contains(privateMarker))
    }

    @Test("built CLI renders a selected-command argument correction without reflecting argument values")
    func builtCLIRendersWrongDynamicCommandVariantCorrection() async throws {
        let scenario = try DynamicCommandScenario.make(includesRepositoryAlternative: true)
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let executableURL = try cliExecutableURL()
        let privateRepositoryIdentifier = UUIDv7.generate()
        let wrongVariant = try await runCLI(
            executableURL: executableURL,
            arguments: [
                "command.execute", "--json",
                try commandRequestJSON(
                    commandId: scenario.commandId,
                    correlationId: UUIDv7.generate(),
                    arguments: .repository(IPCRepositoryCommandArguments(repoId: privateRepositoryIdentifier))
                ),
            ],
            environment: makeCLIEnvironment(for: scenario)
        )
        let wrongVariantError = try requireStructuredCLIError(wrongVariant)
        #expect(wrongVariantError.reason == "invalidParams")
        #expect(wrongVariantError.fieldPath == "$.arguments.kind")
        #expect(wrongVariantError.expected == "an argument variant advertised for the selected command")
        #expect(wrongVariantError.catalogMethod == "command.list")
        let standardError = try #require(String(data: wrongVariant.standardError, encoding: .utf8))
        #expect(!standardError.contains(privateRepositoryIdentifier.uuidString))
    }

    @Test("built CLI renders known unavailable command correction")
    func builtCLIRendersUnavailableDynamicCommandCorrection() async throws {
        let unavailableScenario = try DynamicCommandScenario.make(resultAvailable: false)
        defer { unavailableScenario.fixture.cleanup() }
        try unavailableScenario.fixture.server.start()
        let executableURL = try cliExecutableURL()
        let unavailable = try await runCLI(
            executableURL: executableURL,
            arguments: [
                "command.execute", "--json",
                try commandRequestJSON(
                    commandId: unavailableScenario.commandId,
                    correlationId: unavailableScenario.correlationId,
                    arguments: .noArguments
                ),
            ],
            environment: makeCLIEnvironment(for: unavailableScenario)
        )
        let unavailableError = try requireStructuredCLIError(unavailable)
        #expect(unavailableError.reason == "stateUnavailable")
        #expect(unavailableError.fieldPath == "$.commandId")
        #expect(unavailableError.expected == nil)
        #expect(unavailableError.catalogMethod == nil)
    }

    @Test("built CLI renders foreign capabilities as unsupported version")
    func builtCLIRendersUnsupportedVersionFromLiveSocket() async throws {
        let endpoint = UnixSocketEndpoint(path: temporaryDynamicCommandSocketPath())
        let listener = UnixSocketListener(endpoint: endpoint)
        let privateCompatibilityMarker = "PRIVATE-FOREIGN-CATALOG-MUST-NOT-REFLECT"
        let foreignCatalog = IPCMethodCatalogResult(
            compatibility: IPCProtocolCatalogCompatibility(
                wireProtocolIdentifier: "foreign-wire-\(privateCompatibilityMarker)",
                catalogIdentifier: "foreign-catalog-\(privateCompatibilityMarker)"
            ),
            methods: []
        )
        try listener.start { connection in
            defer { connection.close() }
            var decoder = NDJSONFrameDecoder(maxFrameBytes: 1_048_576)
            let request = try receiveListenerHandlerRequest(connection: connection, decoder: &decoder)
            #expect(request.method == "system.capabilities")
            try connection.send(
                dynamicCommandResponseFrame(id: request.id, result: foreignCatalog)
            )
        }
        defer { listener.stop() }

        let result = try await runCLI(
            executableURL: cliExecutableURL(),
            arguments: ["system.capabilities"],
            environment: makeCLIEnvironment(socketPath: endpoint.path)
        )
        let structuredError = try requireStructuredCLIError(result)
        #expect(structuredError.reason == "unsupportedVersion")
        #expect(structuredError.fieldPath == "$.compatibility")
        #expect(structuredError.expected?.isEmpty == false)
        let standardError = try #require(String(data: result.standardError, encoding: .utf8))
        #expect(!standardError.contains(privateCompatibilityMarker))
    }

    @Test("built CLI renders a missing required method parameter as invalid params")
    func builtCLIRendersMissingRequiredParameter() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()

        let result = try await runCLI(
            executableURL: cliExecutableURL(),
            arguments: ["terminal.send", "--handle", "self"],
            environment: makeCLIEnvironment(for: scenario)
        )
        let structuredError = try requireStructuredCLIError(result)
        #expect(structuredError.reason == "invalidParams")
        #expect(structuredError.fieldPath == "$.input")
        #expect(structuredError.expected?.isEmpty == false)
        #expect(structuredError.catalogMethod == nil)
    }

    @Test("built CLI preserves an App IPC missing grant scope")
    func builtCLIRendersCanonicalMissingGrantScope() async throws {
        let scenario = try PaneAgentCredentialScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()

        // An established session method keeps the grant-based admission, so a
        // cross-pane query still carries the canonical required scope.
        let result = try await runCLI(
            executableURL: cliExecutableURL(),
            arguments: ["session.query", "--handle", scenario.otherPaneId.uuidString],
            environment: scenario.cliEnvironment
        )
        let structuredError = try requireStructuredCLIError(result)
        #expect(structuredError.reason == "missingGrant")
        #expect(structuredError.fieldPath == "$.authorization")
        #expect(
            structuredError.requiredScope
                == IPCPermissionScope(
                    privilege: .sessionStateRead,
                    target: .pane(scenario.otherPaneId.uuidString),
                    dataScope: .sessionState
                ))
        #expect(structuredError.catalogMethod == nil)
    }

    @Test("built CLI reports a pane agent's refused command as not yet allowed")
    func builtCLIRendersNotYetAllowedCommand() async throws {
        let scenario = try PaneAgentCredentialScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()

        let result = try await runCLI(
            executableURL: cliExecutableURL(),
            arguments: [
                "command.execute", "--json",
                try commandRequestJSON(
                    commandId: scenario.commandId,
                    correlationId: scenario.correlationId,
                    arguments: .noArguments
                ),
            ],
            environment: scenario.cliEnvironment
        )
        let structuredError = try requireStructuredCLIError(result)
        #expect(structuredError.reason == "notYetAllowed")
        #expect(structuredError.refusedName == scenario.commandId.rawValue)
        #expect(structuredError.requiredScope == nil)
        #expect(scenario.commandPort.receivedExecutionRequests.isEmpty)
    }

    @Test("built CLI names a pane agent's refused method")
    func builtCLIRendersNotYetAllowedMethodName() async throws {
        let scenario = try PaneAgentCredentialScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()

        let result = try await runCLI(
            executableURL: cliExecutableURL(),
            arguments: ["bridge.diff.getPackage", "--handle", "self"],
            environment: scenario.cliEnvironment
        )
        let structuredError = try requireStructuredCLIError(result)
        #expect(structuredError.reason == "notYetAllowed")
        #expect(structuredError.refusedName == "bridge.diff.getPackage")
        #expect(structuredError.requiredScope == nil)
    }

    @Test("built CLI renders an unknown method correction without reflecting its identifier")
    func builtCLIRendersUnknownMethodCorrection() async throws {
        let scenario = try DynamicCommandScenario.make()
        defer { scenario.fixture.cleanup() }
        try scenario.fixture.server.start()
        let privateMethodMarker = "private.future.method.DO_NOT_REFLECT"

        let result = try await runCLI(
            executableURL: cliExecutableURL(),
            arguments: [privateMethodMarker],
            environment: makeCLIEnvironment(for: scenario)
        )
        let structuredError = try requireStructuredCLIError(result)
        #expect(structuredError.reason == "unknownMethod")
        #expect(structuredError.fieldPath == "$.method")
        #expect(structuredError.catalogMethod == "system.capabilities")
        let standardError = try #require(String(data: result.standardError, encoding: .utf8))
        #expect(!standardError.contains(privateMethodMarker))
    }
}

private struct DynamicCommandScenario {
    let commandId: IPCCommandIdentifier
    let correlationId: UUID
    let commandPort: FakeCommandPort
    let fixture: LiveServerFixture

    static func make(
        resultCorrelationId: UUID? = nil,
        resultAvailable: Bool = true,
        includesRepositoryAlternative: Bool = false
    ) throws -> Self {
        let commandId = IPCCommandIdentifier(rawValue: "fixture.liveCommand")
        let repositoryCommandId = IPCCommandIdentifier(rawValue: "fixture.repositoryCommand")
        let correlationId = UUIDv7.generate()
        let descriptorResult = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(commandId: commandId, correlationId: correlationId))
        let repositoryDescriptorResult = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(commandId: repositoryCommandId, correlationId: correlationId))
        let descriptor = try makeFakeCommandDescriptor(
            FakeCommandDescriptorInput(
                id: commandId,
                executionMode: .headless,
                arguments: .noArguments,
                requiredPrivileges: [.appCommandExecute],
                dataScope: .unspecified,
                allowedTargetKinds: [],
                result: descriptorResult
            )
        )
        let commands: [IPCCommandDescriptor]
        if includesRepositoryAlternative {
            let repositoryDescriptor = try makeFakeCommandDescriptor(
                FakeCommandDescriptorInput(
                    id: repositoryCommandId,
                    executionMode: .headless,
                    arguments: .repository(IPCRepositoryCommandArguments(repoId: UUIDv7.generate())),
                    requiredPrivileges: [.appCommandExecute],
                    dataScope: .unspecified,
                    allowedTargetKinds: [],
                    result: repositoryDescriptorResult
                )
            )
            commands = [descriptor, repositoryDescriptor]
        } else {
            commands = [descriptor]
        }
        let runtimeResult = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(
                commandId: commandId,
                correlationId: resultCorrelationId ?? correlationId
            ))
        let commandPort = FakeCommandPort(
            commands: commands,
            executionResultsByCommandId: resultAvailable ? [commandId.rawValue: runtimeResult] : [:]
        )
        let composition = try IPCCommandMethodComposition(
            compatibility: .current,
            commands: commands
        )
        return try Self(
            commandId: commandId,
            correlationId: correlationId,
            commandPort: commandPort,
            fixture: LiveServerFixture(
                accessMode: .unsafeDebug,
                channel: .debug,
                commandPort: commandPort,
                commandComposition: composition
            )
        )
    }
}

private struct PaneAgentCredentialScenario {
    let commandId: IPCCommandIdentifier
    let correlationId: UUID
    let otherPaneId: UUID
    let commandPort: FakeCommandPort
    let fixture: LiveServerFixture
    let authenticationToken: String

    var cliEnvironment: [String: String] {
        var environment = makeCLIEnvironment(socketPath: fixture.paths.socketURL.path)
        environment["AGENTSTUDIO_PANE_TOKEN"] = authenticationToken
        return environment
    }

    static func make() throws -> Self {
        let commandId = IPCCommandIdentifier(rawValue: "fixture.notYetAllowedCommand")
        let correlationId = UUIDv7.generate()
        let descriptorResult = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(commandId: commandId, correlationId: correlationId)
        )
        let descriptor = try makeFakeCommandDescriptor(
            FakeCommandDescriptorInput(
                id: commandId,
                executionMode: .headless,
                arguments: .noArguments,
                requiredPrivileges: [.appCommandExecute],
                dataScope: .unspecified,
                allowedTargetKinds: [],
                result: descriptorResult
            )
        )
        let commandPort = FakeCommandPort(commands: [descriptor])
        let composition = try IPCCommandMethodComposition(
            compatibility: .current,
            commands: [descriptor]
        )
        let boundPaneId = UUIDv7.generate()
        let otherPaneId = UUIDv7.generate()
        let fixture = try LiveServerFixture(
            panes: [makePaneSummary(id: boundPaneId, ordinal: 1), makePaneSummary(id: otherPaneId, ordinal: 2)],
            commandPort: commandPort,
            commandComposition: composition
        )
        let authenticationToken = try fixture.issueTestCredential(
            for: .pane(
                paneId: boundPaneId,
                credentialRecordId: UUIDv7.generate(),
                status: .registered
            )
        )
        return Self(
            commandId: commandId,
            correlationId: correlationId,
            otherPaneId: otherPaneId,
            commandPort: commandPort,
            fixture: fixture,
            authenticationToken: authenticationToken.rawValue
        )
    }
}

private func requireSuccess(
    _ result: IPCDescriptorClientCallResult
) throws -> IPCDescriptorClientResponse {
    switch result {
    case .success(let response):
        return response
    case .remoteFailure(let failure):
        Issue.record("Expected successful live ClientCore call, received \(failure.code)")
        throw DynamicCommandClientTestError.remoteFailure
    }
}

private enum DynamicCommandClientTestError: Error {
    case remoteFailure
}

private struct StructuredCLIError: Decodable {
    let reason: String
    let fieldPath: String?
    let expected: String?
    let catalogMethod: String?
    let requiredScope: IPCPermissionScope?
    let refusedName: String?
}

private func makeCLIEnvironment(for scenario: DynamicCommandScenario) -> [String: String] {
    makeCLIEnvironment(socketPath: scenario.fixture.paths.socketURL.path)
}

private func makeCLIEnvironment(socketPath: String) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["AGENTSTUDIO_IPC_SOCKET"] = socketPath
    environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")
    return environment
}

private func commandRequestJSON(
    commandId: IPCCommandIdentifier,
    correlationId: UUID,
    arguments: IPCCommandArguments
) throws -> String {
    let request = IPCCommandExecutionRequest(
        commandId: commandId,
        correlationId: correlationId,
        arguments: arguments
    )
    return try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
}

private func requireStructuredCLIError(_ result: CLIProcessResult) throws -> StructuredCLIError {
    #expect(result.exitCode != 0)
    #expect(result.standardOutput.isEmpty)
    return try JSONDecoder().decode(StructuredCLIError.self, from: result.standardError)
}

private func temporaryDynamicCommandSocketPath() -> String {
    "/tmp/asipc-cli-errors-\(UUIDv7.generate().uuidString).sock"
}

private func dynamicCommandResponseFrame<Result: Encodable>(
    id: JSONRPCIdentifier?,
    result: Result
) throws -> Data {
    try NDJSONFrameEncoder.encode(
        JSONRPCCodec.encodeResponse(
            .success(id: id, result: try JSONRPCCodec.encodeJSONValue(result))
        ),
        maxFrameBytes: 1_048_576
    )
}
