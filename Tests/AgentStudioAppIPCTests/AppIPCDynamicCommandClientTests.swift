import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Dispatch
import Foundation
import Testing

@Suite("Live dynamic command ClientCore integration", .serialized)
struct AppIPCDynamicCommandClientTests {
    @Test("ClientCore lists served bytes and executes the raw envelope without a discovered invocation builder")
    func clientListsAndExecutesRawCommand() async throws {
        try await DynamicCommandScenario.withScope(body: { scenario in
            try scenario.fixture.server.start()
            let descriptors = try IPCCompiledInvocationResolver().resolve(
                arguments: ["command.execute"], authenticated: false,
                inputs: .init(examples: .init(illustrativeIdentifier: scenario.correlationId)))
            let client = AgentStudioIPCClient(
                configuration: .init(socketPath: scenario.fixture.paths.socketURL.path), descriptors: descriptors)
            let bytes = try await valueFromDedicatedThread { try client.discoverCommandBytes(requestID: 20) }
            let commands = try JSONDecoder().decode(IPCCommandCatalogResult.self, from: bytes)
            #expect(commands.commands.contains { $0.id == scenario.commandId })
            let descriptor = try #require(descriptors.first { $0.metadata.name == "command.execute" })
            let request = IPCRawCommandExecutionRequest(
                commandId: scenario.commandId, correlationId: scenario.correlationId, arguments: [:])
            let invocation = try IPCDescriptorInvocation(
                descriptor: descriptor,
                normalizedParameters: descriptor.normalizeParameters(JSONEncoder().encode(request)),
                presentation: .tooling)
            let response = try requireSuccess(
                try await client.callWithoutBlockingCooperativePool(invocation, requestID: 30))
            let result = try JSONDecoder().decode(IPCCommandExecutionResult.self, from: response.normalizedResult.data)
            #expect(result.commandId == scenario.commandId)
            #expect(result.correlationId == scenario.correlationId)
            #expect(scenario.commandPort.receivedExecutionRequests.count == 1)
            #expect(scenario.commandPort.receivedExecutionRequests.first?.commandId == scenario.commandId)
            #expect(scenario.commandPort.receivedExecutionRequests.first?.correlationId == scenario.correlationId)
        })
    }

    @Test("server rejects a command result whose correlation differs from its request")
    func serverRejectsMismatchedCommandResultIdentity() async throws {
        try await DynamicCommandScenario.withScope(
            resultCorrelationId: UUIDv7.generate(),
            body: { scenario in
                try scenario.fixture.server.start()
                let client = AgentStudioIPCClient(
                    configuration: AgentStudioIPCClientConfiguration(socketPath: scenario.fixture.paths.socketURL.path),
                    descriptors: []
                )
                let descriptor = try IPCAnyMethodDescriptor(erasing: IPCCommandMethodComposition.compiledExecute())
                let request = IPCRawCommandExecutionRequest(
                    commandId: scenario.commandId, correlationId: scenario.correlationId, arguments: [:])
                let invocation = try IPCDescriptorInvocation(
                    descriptor: descriptor,
                    normalizedParameters: descriptor.normalizeParameters(JSONEncoder().encode(request)),
                    presentation: .tooling)

                switch try await client.callWithoutBlockingCooperativePool(invocation, requestID: 40) {
                case .success:
                    Issue.record("Mismatched command result must not cross the server boundary")
                case .remoteFailure(let failure):
                    #expect(failure.code == -32_602)
                }
                #expect(scenario.commandPort.receivedExecutionRequests.count == 1)
            })
    }

    @Test("raw server requests reject unknown identity and wrong variant before execution")
    func rawServerRequestsRejectInvalidCommandSelectionBeforePort() async throws {
        try await DynamicCommandScenario.withScope(body: { scenario in
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
            #expect(wrongVariantResponse.error?.message == "invalid arguments")
            #expect(scenario.commandPort.receivedExecutionRequests.isEmpty)
        })
    }

    @Test("one authenticated socket can list and execute after its single login")
    func oneAuthenticatedConnectionSupportsMultipleCommandCalls() async throws {
        try await DynamicCommandScenario.withScope(body: { scenario in
            try scenario.fixture.server.start()
            let token = scenario.fixture.installDebugCredential()
            let connection = try await connectWithoutBlockingCooperativePool(
                socketPath: scenario.fixture.paths.socketURL.path)
            defer { connection.close() }
            var reader = TestFrameReader()
            try await loginWithoutBlockingMainActor(
                connection: connection, token: token, requestId: 50, reader: &reader)

            try await sendRequestWithoutBlockingCooperativePool(
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
            try await sendRequestWithoutBlockingCooperativePool(
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
        })
    }

    @Test("built CLI lists and executes through the live dynamic registry")
    func builtCLIListsAndExecutesLiveCommand() async throws {
        try await DynamicCommandScenario.withScope(body: { scenario in
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
        })
    }

    @Test("built CLI reports terminal wait timeout by its documented reason")
    func builtCLIRendersTerminalWaitTimeout() async throws {
        let paneId = UUIDv7.generate()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    accessMode: .unsafeDebug,
                    channel: .debug,
                    panes: [makePaneSummary(id: paneId, ordinal: 1)]
                )
            },
            body: { fixture in
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
            })
    }

    @Test("built CLI preserves the app unknown-command identifier and visible suggestions")
    func builtCLIRendersUnknownDynamicCommandCorrection() async throws {
        try await DynamicCommandScenario.withScope(body: { scenario in
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
            #expect(unknownError.fieldPath == nil)
            #expect(unknownError.catalogMethod == nil)
            #expect(unknownError.commandId == privateMarker)
            #expect(unknownError.closestMatches == [scenario.commandId.rawValue])
            let standardError = try #require(String(data: unknown.standardError, encoding: .utf8))
            #expect(standardError.contains(privateMarker))
        })
    }

    @Test("built CLI renders a selected-command argument correction without reflecting argument values")
    func builtCLIRendersWrongDynamicCommandVariantCorrection() async throws {
        try await DynamicCommandScenario.withScope(
            includesRepositoryAlternative: true,
            body: { scenario in
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
                #expect(wrongVariantError.reason == "invalidArguments")
                #expect(wrongVariantError.fieldPath == "$.arguments.kind")
                #expect(wrongVariantError.expected == "one admitted argument kind: noArguments")
                #expect(wrongVariantError.catalogMethod == nil)
                let standardError = try #require(String(data: wrongVariant.standardError, encoding: .utf8))
                #expect(!standardError.contains(privateRepositoryIdentifier.uuidString))
            })
    }

    @Test("built CLI renders known unavailable command correction")
    func builtCLIRendersUnavailableDynamicCommandCorrection() async throws {
        try await DynamicCommandScenario.withScope(
            resultAvailable: false,
            body: { unavailableScenario in
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
            })
    }

    @Test("built CLI renders a missing required method parameter as invalid params")
    func builtCLIRendersMissingRequiredParameter() async throws {
        try await DynamicCommandScenario.withScope(body: { scenario in
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
        })
    }

    @Test("built CLI preserves an App IPC missing grant scope")
    func builtCLIRendersCanonicalMissingGrantScope() async throws {
        try await PaneAgentCredentialScenario.withScope(body: { scenario in
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
        })
    }

    @Test("built CLI reports a pane agent's refused command as not yet allowed")
    func builtCLIRendersNotYetAllowedCommand() async throws {
        try await PaneAgentCredentialScenario.withScope(body: { scenario in
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
        })
    }

    @Test("built CLI names a pane agent's refused method")
    func builtCLIRendersNotYetAllowedMethodName() async throws {
        try await PaneAgentCredentialScenario.withScope(body: { scenario in
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
        })
    }

    @Test("built CLI renders an unknown method correction without reflecting its identifier")
    func builtCLIRendersUnknownMethodCorrection() async throws {
        try await DynamicCommandScenario.withScope(body: { scenario in
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
            #expect(structuredError.catalogMethod == nil)
            // PD choice 4 ranks entry names; it specifies no eligibility filter.
            let suggestedMethods: [String] = [
                "bridge.telemetry.flush", "bridge.telemetry.snapshot", "bridge.diff.scrollToFile",
            ]
            let expectedCorrection: String =
                "a compiled method or model invocation; see agentstudio help; closest methods: "
                + suggestedMethods.joined(separator: ", ")
            #expect(structuredError.expected == expectedCorrection)
            let index = IPCBuiltInMethodIndex()
            #expect(suggestedMethods.allSatisfy { index.entry(named: $0) != nil })
            let standardOutput = try #require(String(data: result.standardOutput, encoding: .utf8))
            let standardError = try #require(String(data: result.standardError, encoding: .utf8))
            #expect(!standardOutput.contains(privateMethodMarker))
            #expect(!standardError.contains(privateMethodMarker))
        })
    }
}

private struct DynamicCommandScenario {
    let commandId: IPCCommandIdentifier
    let correlationId: UUID
    let commandPort: FakeCommandPort
    let fixture: LiveServerFixture

    static func withScope<Result>(
        resultCorrelationId: UUID? = nil,
        resultAvailable: Bool = true,
        includesRepositoryAlternative: Bool = false, body: (Self) async throws -> Result
    ) async throws -> Result {
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
        return try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    accessMode: .unsafeDebug,
                    channel: .debug,
                    commandPort: commandPort,
                    commandComposition: composition
                )
            },
            body: { fixture in
                let scenario = Self(
                    commandId: commandId,
                    correlationId: correlationId,
                    commandPort: commandPort,
                    fixture: fixture
                )
                return try await body(scenario)
            })
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

    static func withScope<Result>(body: (Self) async throws -> Result) async throws -> Result {
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
        return try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    panes: [
                        makePaneSummary(id: boundPaneId, ordinal: 1), makePaneSummary(id: otherPaneId, ordinal: 2),
                    ],
                    commandPort: commandPort,
                    commandComposition: composition
                )
            },
            body: { fixture in
                let authenticationToken = try fixture.issueTestCredential(
                    for: .pane(
                        paneId: boundPaneId,
                        credentialRecordId: UUIDv7.generate(),
                        status: .registered
                    )
                )
                let scenario = Self(
                    commandId: commandId,
                    correlationId: correlationId,
                    otherPaneId: otherPaneId,
                    commandPort: commandPort,
                    fixture: fixture,
                    authenticationToken: authenticationToken.rawValue
                )
                return try await body(scenario)
            })
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
    let commandId: String?
    let closestMatches: [String]?
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
