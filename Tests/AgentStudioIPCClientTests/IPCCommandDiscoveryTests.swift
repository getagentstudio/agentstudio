import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Live command catalog discovery")
struct IPCCommandDiscoveryTests {
    @Test("validated capabilities and command.list produce a descriptor-bound invocation")
    func validDiscoveryCreatesDescriptorBoundInvocation() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let discovery = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)

        #expect(discovery.commandListInvocation.descriptor.metadata.name == "command.list")
        #expect(discovery.commandListInvocation.presentation == .tooling)

        let discoveredCatalog = try discovery.decodeCommandCatalog(
            from: JSONEncoder().encode(fixture.commandComposition.catalogResult)
        )
        let invocation = try discoveredCatalog.makeInvocation(
            commandId: fixture.noArgumentsCommandId,
            correlationId: fixture.correlationId,
            arguments: .noArguments
        )

        #expect(invocation.descriptor.metadata.name == "command.execute")
        #expect(invocation.descriptor.metadata.commandRelationship == .appCommandParameter(field: "commandId"))
        #expect(invocation.descriptor.metadata.correlationPolicy == .required)
        #expect(
            try JSONDecoder().decode(
                IPCCommandExecutionRequest.self,
                from: invocation.normalizedParameters.data
            )
                == IPCCommandExecutionRequest(
                    commandId: fixture.noArgumentsCommandId,
                    correlationId: fixture.correlationId,
                    arguments: .noArguments
                )
        )
    }

    @Test("open command IDs and closed argument variants are both enforced by the live catalog")
    func commandIdentityAndArgumentVariantMustMatchOneLiveDescriptor() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let catalog = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
            .decodeCommandCatalog(from: JSONEncoder().encode(fixture.commandComposition.catalogResult))

        let unknownIdentifier = try captureIPCCommandDiscoveryError {
            _ = try catalog.makeInvocation(
                commandId: IPCCommandIdentifier(rawValue: "future.private.command"),
                correlationId: fixture.correlationId,
                arguments: .noArguments
            )
        }
        let wrongVariant = try captureIPCCommandDiscoveryError {
            _ = try catalog.makeInvocation(
                commandId: fixture.noArgumentsCommandId,
                correlationId: fixture.correlationId,
                arguments: try fixture.paneArguments()
            )
        }

        #expect(unknownIdentifier.reason == .unknownCommandIdentifier)
        #expect(unknownIdentifier.fieldPath == "$.commandId")
        #expect(wrongVariant.reason == .argumentVariantNotAllowed)
        #expect(wrongVariant.fieldPath == "$.arguments.kind")
    }

    @Test(
        "a recognized hidden command whose arguments no advertised command takes is framed for the app to refuse",
        arguments: HiddenCommandCase.allCases
    )
    func recognizedHiddenCommandIsFramedForTheApp(hiddenCase: HiddenCommandCase) throws {
        let hiddenCommandId = IPCCommandIdentifier(rawValue: "fixture.hidden")
        let fixture = try IPCCommandDiscoveryFixture.make(recognizedUnexposedCommands: [
            IPCRecognizedUnexposedName(name: hiddenCommandId.rawValue, agentEligibility: .notYetAllowed)
        ])
        let catalog = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
            .decodeCommandCatalog(from: JSONEncoder().encode(fixture.commandComposition.catalogResult))
        let arguments = hiddenCase.arguments(workspaceWindowId: fixture.workspaceWindowId)
        let request = IPCCommandExecutionRequest(
            commandId: hiddenCommandId, correlationId: fixture.correlationId, arguments: arguments)
        let payload = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))

        // Gate 1: the CLI reads the payload with the catalog's envelope, not
        // with the advertised union, which has no such argument variant.
        let parsed = try IPCDescriptorInvocationParser.parse(
            ["command.execute", "--json", payload],
            descriptors: [catalog.requestEnvelopeDescriptor],
            correlationIDGenerator: { UUIDv7.generate() }
        )
        #expect(throws: (any Error).self) {
            _ = try catalog.executeDescriptor.normalizeParameters(Data(payload.utf8))
        }
        let parsedRequest = try JSONDecoder().decode(
            IPCCommandExecutionRequest.self,
            from: parsed.normalizedParameters.data
        )
        let invocation = try catalog.makeInvocation(
            commandId: parsedRequest.commandId,
            correlationId: parsedRequest.correlationId,
            arguments: parsedRequest.arguments
        )
        // Gate 2: framing accepts only the invocation's schema-bound
        // normalized value.
        let frame = try AgentStudioIPCClient(
            configuration: .init(socketPath: "/tmp/unused.sock"), descriptors: []
        ).requestFrame(invocation, requestID: 7)
        let framed = try JSONRPCCodec.decodeRequest(frame)
        let framedRequest = try JSONDecoder().decode(
            IPCCommandExecutionRequest.self, from: JSONEncoder().encode(try #require(framed.params)))

        #expect(framed.method == "command.execute")
        #expect(framedRequest == request)
    }

    @Test("advertised commands keep their own variants and unknown identifiers stay local")
    func advertisedCommandsKeepTypedValidation() throws {
        let fixture = try IPCCommandDiscoveryFixture.make(recognizedUnexposedCommands: [
            IPCRecognizedUnexposedName(name: "fixture.hidden", agentEligibility: .notYetAllowed)
        ])
        let catalog = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
            .decodeCommandCatalog(from: JSONEncoder().encode(fixture.commandComposition.catalogResult))

        let advertisedWithForeignVariant = try captureIPCCommandDiscoveryError {
            _ = try catalog.makeInvocation(
                commandId: fixture.noArgumentsCommandId,
                correlationId: fixture.correlationId,
                arguments: HiddenCommandCase.tab.arguments(workspaceWindowId: fixture.workspaceWindowId)
            )
        }
        let unknown = try captureIPCCommandDiscoveryError {
            _ = try catalog.makeInvocation(
                commandId: IPCCommandIdentifier(rawValue: "future.private.command"),
                correlationId: fixture.correlationId,
                arguments: .noArguments
            )
        }

        #expect(advertisedWithForeignVariant.reason == .argumentVariantNotAllowed)
        #expect(advertisedWithForeignVariant.fieldPath == "$.arguments.kind")
        #expect(unknown.reason == .unknownCommandIdentifier)
    }

    @Test("command result decoding preserves typed identity and correlation")
    func resultIdentityAndCorrelationRemainTyped() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let catalog = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
            .decodeCommandCatalog(from: JSONEncoder().encode(fixture.commandComposition.catalogResult))
        let invocation = try catalog.makeInvocation(
            commandId: fixture.noArgumentsCommandId,
            correlationId: fixture.correlationId,
            arguments: .noArguments
        )
        let expected = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(
                commandId: fixture.noArgumentsCommandId,
                correlationId: fixture.correlationId
            )
        )

        let result = try catalog.decodeResult(
            JSONEncoder().encode(expected),
            for: invocation
        )

        #expect(result == expected)
        #expect(result.commandId == fixture.noArgumentsCommandId)
        #expect(result.correlationId == fixture.correlationId)

        let wrongCorrelation = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(
                commandId: fixture.noArgumentsCommandId,
                correlationId: UUIDv7.generate()
            )
        )
        let error = try captureIPCCommandDiscoveryError {
            _ = try catalog.decodeResult(
                JSONEncoder().encode(wrongCorrelation),
                for: invocation
            )
        }
        #expect(error.reason == .resultCorrelationMismatch)
        #expect(error.fieldPath == "$.correlationId")
    }

    @Test("malformed live command payloads fail with controlled errors and do not echo private input")
    func malformedLivePayloadDoesNotEchoPrivateInput() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let discovery = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
        let privateValue = "PRIVATE-COMMAND-PAYLOAD-\u{1F512}"
        let malformed = Data(
            """
            {"compatibility":{"wireProtocolIdentifier":"agentstudio-ipc-jsonrpc-2","catalogIdentifier":"agentstudio-ipc-v2"},"commands":[{"private":"\(privateValue)"}]}
            """.utf8
        )

        let error = try captureIPCCommandDiscoveryError {
            _ = try discovery.decodeCommandCatalog(from: malformed)
        }

        #expect(error.reason == .invalidCommandCatalog)
        #expect(error.fieldPath == "$.commands")
        #expect(!String(describing: error).contains(privateValue))
        #expect(!String(describing: error).contains("private"))
    }

    @Test("raw command.list payloads reject unknown fields and wrong types")
    func rawCommandListPayloadsKeepFullSchemaValidation() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let discovery = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
        let validPayload = try JSONEncoder().encode(fixture.commandComposition.catalogResult)

        var unknownFieldObject = try #require(
            JSONSerialization.jsonObject(with: validPayload) as? [String: Any]
        )
        unknownFieldObject["privateExtension"] = true
        let unknownFieldPayload = try JSONSerialization.data(withJSONObject: unknownFieldObject)

        var wrongTypeObject = try #require(
            JSONSerialization.jsonObject(with: validPayload) as? [String: Any]
        )
        wrongTypeObject["commands"] = "not-an-array"
        let wrongTypePayload = try JSONSerialization.data(withJSONObject: wrongTypeObject)

        for malformedPayload in [unknownFieldPayload, wrongTypePayload] {
            let error = try captureIPCCommandDiscoveryError {
                _ = try discovery.decodeCommandCatalog(from: malformedPayload)
            }
            #expect(error.reason == .invalidCommandCatalog)
        }
    }

    @Test("raw command.list payloads reject an ambiguous oneOf")
    func rawCommandListRejectsAmbiguousOneOf() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let ambiguousListSchema = IPCJSONSchema.oneOf([
            fixture.commandComposition.list.contract.resultSchema,
            fixture.commandComposition.list.contract.resultSchema,
        ])
        var catalogObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.methodCatalog)) as? [String: Any]
        )
        var methods = try #require(catalogObject["methods"] as? [[String: Any]])
        let commandListIndex = try #require(methods.firstIndex { $0["name"] as? String == "command.list" })
        methods[commandListIndex]["resultSchema"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ambiguousListSchema)
        )
        methods[commandListIndex]["examples"] = []
        catalogObject["methods"] = methods

        let methodCatalog = try JSONDecoder().decode(
            IPCMethodCatalogResult.self,
            from: JSONSerialization.data(withJSONObject: catalogObject)
        )
        let discovery = try IPCCommandDiscovery(methodCatalog: methodCatalog)
        let payload = try JSONEncoder().encode(fixture.commandComposition.catalogResult)

        let error = try captureIPCCommandDiscoveryError {
            _ = try discovery.decodeCommandCatalog(from: payload)
        }

        #expect(error.reason == .invalidCommandCatalog)
    }

    @Test("command.list rejects a command body that violates its selected literal-id alternative")
    func commandListRejectsInvalidSelectedCommandBody() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let discovery = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
        var catalogObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(fixture.commandComposition.catalogResult)
            ) as? [String: Any]
        )
        var commands = try #require(catalogObject["commands"] as? [[String: Any]])
        commands[0]["title"] = 42
        catalogObject["commands"] = commands
        let malformedPayload = try JSONSerialization.data(withJSONObject: catalogObject, options: [.sortedKeys])

        let error = try captureIPCCommandDiscoveryError {
            _ = try discovery.decodeCommandCatalog(from: malformedPayload)
        }

        #expect(error.reason == .invalidCommandCatalog)
        #expect(error.fieldPath == "$.commands")
    }

    @Test("schema-normalized command.list data takes the typed skip path")
    func normalizedCommandListUsesTheTypedSkipPath() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let discovery = try IPCCommandDiscovery(methodCatalog: fixture.methodCatalog)
        let payload = try JSONEncoder().encode(fixture.commandComposition.catalogResult)
        let normalizedResult: IPCValidatedJSON = try discovery.commandListInvocation.descriptor.normalizeResult(payload)

        let discoveredCatalog = try discovery.decodeCommandCatalog(from: normalizedResult)
        let invocation = try discoveredCatalog.makeInvocation(
            commandId: fixture.noArgumentsCommandId,
            correlationId: fixture.correlationId,
            arguments: .noArguments
        )

        #expect(invocation.descriptor.metadata.name == "command.execute")
    }

    @Test("command.list and system.ping preserve typed normalized round trips")
    func typedCommandListAndPingRoundTrips() throws {
        let fixture = try IPCCommandDiscoveryFixture.make()
        let commandListResult = fixture.commandComposition.catalogResult
        let commandListContract = fixture.commandComposition.list.contract
        let validatedCommandList = try commandListContract.validatedResult(
            from: JSONEncoder().encode(commandListResult)
        )

        #expect(validatedCommandList.value == commandListResult)
        #expect(try commandListContract.decodeResult(from: validatedCommandList.json) == commandListResult)

        let pingResult = IPCSystemPingResult(runtimeId: UUIDv7.generate())
        let pingContract = try IPCMethodContract<IPCEmptyParams, IPCSystemPingResult>(
            parameterSchema: IPCEmptyParams.ipcSchema(),
            resultSchema: IPCSystemPingResult.ipcSchema()
        )
        let lowercasePingPayload = Data(
            "{\"ok\":true,\"runtimeId\":\"\(pingResult.runtimeId.uuidString.lowercased())\"}".utf8
        )
        let validatedPing = try pingContract.validatedResult(from: lowercasePingPayload)

        #expect(validatedPing.value == pingResult)
        #expect(try pingContract.decodeResult(from: validatedPing.json) == pingResult)
        #expect(validatedPing.json.data == (try pingContract.encodeResult(pingResult)))
    }
}

/// Argument variants no fixture command advertises, as `closeTab` and `newTab`
/// take on stable.
enum HiddenCommandCase: CaseIterable, Sendable {
    case tab
    case newTab

    func arguments(workspaceWindowId: UUID) -> IPCCommandArguments {
        switch self {
        case .tab:
            .tab(IPCTabCommandArguments(workspaceWindowId: workspaceWindowId, tabId: UUIDv7.generate()))
        case .newTab:
            .newTab(IPCNewTabCommandArguments(workspaceWindowId: workspaceWindowId, launchDirectory: nil))
        }
    }
}

private struct IPCCommandDiscoveryFixture {
    let noArgumentsCommandId: IPCCommandIdentifier
    let paneCommandId: IPCCommandIdentifier
    let correlationId: UUID
    let workspaceWindowId: UUID
    let commandComposition: IPCCommandMethodComposition
    let methodCatalog: IPCMethodCatalogResult

    static func make(recognizedUnexposedCommands: [IPCRecognizedUnexposedName] = []) throws -> Self {
        let noArgumentsCommandId = IPCCommandIdentifier(rawValue: "fixture.noArguments")
        let paneCommandId = IPCCommandIdentifier(rawValue: "fixture.pane")
        let correlationId = UUIDv7.generate()
        let workspaceWindowId = UUIDv7.generate()
        let paneArguments = IPCCommandArguments.pane(
            IPCPaneCommandArguments(
                workspaceWindowId: workspaceWindowId,
                paneSelector: try IPCPaneSelector(rawValue: "self")
            )
        )
        let noArgumentsRequest = IPCCommandExecutionRequest(
            commandId: noArgumentsCommandId,
            correlationId: correlationId,
            arguments: .noArguments
        )
        let paneRequest = IPCCommandExecutionRequest(
            commandId: paneCommandId,
            correlationId: correlationId,
            arguments: paneArguments
        )
        let commands = try [
            IPCCommandDescriptorFactory.make(
                IPCCommandDescriptorInput(
                    id: noArgumentsCommandId,
                    title: "Fixture No Arguments",
                    description: "Apply a fixture command with no command-specific arguments.",
                    exposure: .allChannels,
                    executionMode: .headless,
                    argumentVariants: [.noArguments],
                    requiredPrivileges: [.appCommandExecute],
                    dataScope: .uiSurface,
                    allowedTargetKinds: [],
                    resultVariants: [.applied],
                    examples: [
                        IPCCommandExample(
                            description: "Apply the no-arguments fixture command.",
                            request: noArgumentsRequest,
                            result: .applied(
                                IPCCommandAppliedResult(
                                    commandId: noArgumentsCommandId,
                                    correlationId: correlationId
                                )
                            )
                        )
                    ],
                    agentEligibility: .notYetAllowed
                )
            ),
            IPCCommandDescriptorFactory.make(
                IPCCommandDescriptorInput(
                    id: paneCommandId,
                    title: "Fixture Pane",
                    description: "Accept a fixture command for one pane.",
                    exposure: .debugTesting,
                    executionMode: .headless,
                    argumentVariants: [.pane],
                    requiredPrivileges: [.appCommandExecute],
                    dataScope: .terminalInput,
                    allowedTargetKinds: [.pane],
                    resultVariants: [.accepted],
                    examples: [
                        IPCCommandExample(
                            description: "Accept the pane fixture command.",
                            request: paneRequest,
                            result: .accepted(
                                IPCCommandAcceptedResult(
                                    commandId: paneCommandId,
                                    correlationId: correlationId,
                                    operationId: UUIDv7.generate()
                                )
                            )
                        )
                    ],
                    agentEligibility: .notYetAllowed
                )
            ),
        ]
        let commandComposition = try IPCCommandMethodComposition(
            compatibility: .current,
            commands: commands,
            recognizedUnexposedCommands: recognizedUnexposedCommands
        )
        return Self(
            noArgumentsCommandId: noArgumentsCommandId,
            paneCommandId: paneCommandId,
            correlationId: correlationId,
            workspaceWindowId: workspaceWindowId,
            commandComposition: commandComposition,
            methodCatalog: try methodCatalog(advertising: commandComposition)
        )
    }

    private static func methodCatalog(
        advertising commandComposition: IPCCommandMethodComposition
    ) throws -> IPCMethodCatalogResult {
        let examples = IPCBuiltInMethodExampleContext(illustrativeIdentifier: UUIDv7.generate())
        let bootstrap = try IPCBuiltInMethodCatalog.bootstrapDescriptors(examples: examples)
        let ping = try #require(bootstrap.first { $0.metadata.name == "system.ping" })
        let advertised =
            bootstrap + [
                try IPCAnyMethodDescriptor(erasing: commandComposition.list),
                try IPCAnyMethodDescriptor(erasing: commandComposition.execute),
            ]
        return try IPCSystemCapabilitiesDescriptorFactory.compose(
            compatibility: .current,
            availableDescriptors: advertised,
            illustrativeDescriptor: ping
        ).result
    }

    func paneArguments() throws -> IPCCommandArguments {
        .pane(
            IPCPaneCommandArguments(
                workspaceWindowId: workspaceWindowId,
                paneSelector: try IPCPaneSelector(rawValue: "self")
            )
        )
    }
}

private func captureIPCCommandDiscoveryError(
    _ operation: () throws -> Void
) throws -> IPCCommandDiscoveryError {
    do {
        try operation()
    } catch let error as IPCCommandDiscoveryError {
        return error
    } catch {
        Issue.record("Expected IPCCommandDiscoveryError, received \(type(of: error))")
        throw error
    }
    Issue.record("Expected live command discovery to fail")
    throw IPCCommandDiscoveryTestError.expectedFailure
}

private enum IPCCommandDiscoveryTestError: Error {
    case expectedFailure
}
