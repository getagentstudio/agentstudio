import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC typed command descriptors")
struct IPCCommandDescriptorTests {
    @Test("two unrelated open identities retain explicit variants and derived schemas")
    func unrelatedOpenIdentitiesComposeWithoutSharedIdentityTable() throws {
        let first = try IPCCommandDescriptorTestFixtures.firstDescriptor()
        let second = try IPCCommandDescriptorTestFixtures.secondDescriptor()

        #expect(first.id == IPCCommandDescriptorTestFixtures.firstCommandId)
        #expect(first.argumentVariants == [.noArguments])
        #expect(first.resultVariants == [.applied])
        #expect(first.requiredPrivileges == [.appCommandExecute, .layoutMutate])
        #expect(first.exposure == .allChannels)
        #expect(second.id == IPCCommandDescriptorTestFixtures.secondCommandId)
        #expect(second.argumentVariants == [.pane])
        #expect(second.resultVariants == [.accepted])
        #expect(second.exposure == .debugTesting)

        guard case .object(let catalogFields) = try first.catalogEntrySchema else {
            Issue.record("Expected a finite command descriptor object schema")
            return
        }
        #expect(catalogFields.first { $0.name == "argumentSchema" }?.schema == .schemaDocument)
        #expect(catalogFields.first { $0.name == "resultSchema" }?.schema == .schemaDocument)
        guard
            case .array(let argumentVariantItems, let argumentMinimum, _) =
                catalogFields.first(where: { $0.name == "argumentVariants" })?.schema,
            case .array(let resultVariantItems, let resultMinimum, _) =
                catalogFields.first(where: { $0.name == "resultVariants" })?.schema
        else {
            Issue.record("Expected typed argument and result variant arrays")
            return
        }
        #expect(try argumentVariantItems == IPCCommandArgumentVariant.ipcSchema())
        #expect(argumentMinimum == 1)
        #expect(try resultVariantItems == IPCCommandResultVariant.ipcSchema())
        #expect(resultMinimum == 1)

        let firstExample = try #require(first.examples.first)
        #expect(
            try first.argumentSchema.decode(
                IPCCommandArguments.self,
                from: JSONEncoder().encode(firstExample.request.arguments)
            ) == firstExample.request.arguments
        )
        #expect(
            try first.resultSchema.decode(
                IPCCommandExecutionResult.self,
                from: JSONEncoder().encode(firstExample.result)
            ) == firstExample.result
        )
        #expect(throws: IPCSchemaValidationError.self) {
            try first.argumentSchema.normalize(
                JSONEncoder().encode(try IPCCommandDescriptorTestFixtures.secondRequest().arguments)
            )
        }
    }

    @Test("an agent-eligible command must reach every channel and its eligibility is discovered")
    func agentEligibleCommandMustReachEveryChannel() throws {
        for eligibility in [IPCAgentEligibility.ownPane, .anyTarget] {
            #expect(throws: IPCCommandDescriptorError.agentEligibleCommandMustBeExposedOnAllChannels) {
                try IPCCommandDescriptorTestFixtures.secondDescriptor(agentEligibility: eligibility)
            }
        }
        let refused = try IPCCommandDescriptorTestFixtures.secondDescriptor()
        let decoded = try refused.catalogEntrySchema.decode(
            IPCCommandDescriptor.self, from: JSONEncoder().encode(refused))

        #expect(decoded.agentEligibility == .notYetAllowed)
    }

    @Test("factory rejects invalid identity, correlation, variants, and examples")
    func factoryRejectsInconsistentDescriptorMeaning() throws {
        let wrongCommandId = IPCCommandIdentifier(rawValue: "wrong.command")
        let wrongCorrelationId = UUID(uuidString: "01994abc-3000-7000-8000-000000000099")!

        #expect(throws: (any Error).self) {
            try IPCCommandDescriptorFactory.make(
                IPCCommandDescriptorInput(
                    id: IPCCommandIdentifier(rawValue: ""),
                    title: "Invalid",
                    description: "An empty open identifier is invalid.",
                    exposure: .allChannels,
                    executionMode: .headless,
                    argumentVariants: [.noArguments],
                    requiredPrivileges: [.appCommandExecute],
                    dataScope: .unspecified,
                    allowedTargetKinds: [],
                    resultVariants: [.applied],
                    examples: [],
                    agentEligibility: .notYetAllowed
                )
            )
        }
        #expect(throws: (any Error).self) {
            try IPCCommandDescriptorTestFixtures.firstDescriptor(
                request: IPCCommandDescriptorTestFixtures.firstRequest(commandId: wrongCommandId)
            )
        }
        #expect(throws: (any Error).self) {
            try IPCCommandDescriptorTestFixtures.firstDescriptor(
                result: IPCCommandDescriptorTestFixtures.firstResult(commandId: wrongCommandId)
            )
        }
        #expect(throws: (any Error).self) {
            try IPCCommandDescriptorTestFixtures.firstDescriptor(
                result: IPCCommandDescriptorTestFixtures.firstResult(correlationId: wrongCorrelationId)
            )
        }
        #expect(throws: (any Error).self) {
            try IPCCommandDescriptorTestFixtures.firstDescriptor(
                request: try IPCCommandDescriptorTestFixtures.secondRequest(
                    commandId: IPCCommandDescriptorTestFixtures.firstCommandId,
                    correlationId: IPCCommandDescriptorTestFixtures.firstCorrelationId
                )
            )
        }
        #expect(throws: (any Error).self) {
            try IPCCommandDescriptorTestFixtures.firstDescriptor(
                result: .accepted(
                    IPCCommandAcceptedResult(
                        commandId: IPCCommandDescriptorTestFixtures.firstCommandId,
                        correlationId: IPCCommandDescriptorTestFixtures.firstCorrelationId,
                        operationId: nil
                    )
                )
            )
        }
        #expect(throws: (any Error).self) {
            try IPCCommandDescriptorTestFixtures.firstDescriptor(
                requiredPrivileges: [.layoutMutate]
            )
        }
    }

    @Test("catalog result validates itself against a finite composed schema")
    func catalogResultHasFiniteSelfSchema() throws {
        let descriptors = try IPCCommandDescriptorTestFixtures.descriptors()
        let composition = try IPCCommandMethodComposition(
            compatibility: .current,
            commands: descriptors
        )
        let schema = try IPCCommandCatalogResult.schema(
            compatibility: .current,
            commands: composition.commands
        )
        let encoded = try JSONEncoder().encode(composition.catalogResult)

        #expect(composition.commands.map(\.id.rawValue) == ["alpha.futureCommand", "omega.futureCommand"])
        #expect(
            try schema.decode(IPCCommandCatalogResult.self, from: encoded)
                == composition.catalogResult
        )

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var commands = try #require(object["commands"] as? [[String: Any]])
        commands[0]["hiddenDefault"] = true
        object["commands"] = commands
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(
                JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }
    }

    @Test("composition builds typed list and execute descriptors from one command value")
    func compositionBuildsTypedMethodsFromOneCommandCatalog() throws {
        let composition = try IPCCommandMethodComposition(
            compatibility: .current,
            commands: IPCCommandDescriptorTestFixtures.descriptors()
        )

        #expect(composition.list.metadata.name == "command.list")
        #expect(composition.list.metadata.exposure == .allChannels)
        #expect(composition.list.metadata.requiredPrivileges == [.systemRead])
        #expect(composition.list.metadata.commandRelationship == .noInteractiveIdentity)
        #expect(composition.list.metadata.resultSemantics == .applied)
        #expect(composition.execute.metadata.name == "command.execute")
        #expect(composition.execute.metadata.exposure == .allChannels)
        #expect(composition.execute.metadata.requiredPrivileges == [.appCommandExecute])
        #expect(
            composition.execute.metadata.commandRelationship
                == .appCommandParameter(field: "commandId")
        )
        #expect(composition.execute.metadata.resultSemantics == .discriminated)
        #expect(composition.execute.metadata.correlationPolicy == .required)
        #expect(composition.execute.metadata.examples.count == 2)

        let erasedList = try IPCAnyMethodDescriptor(erasing: composition.list)
        let erasedExecute = try IPCAnyMethodDescriptor(erasing: composition.execute)
        _ = try erasedList.catalogEntrySchema.decode(
            IPCMethodCatalogEntry.self,
            from: JSONEncoder().encode(erasedList.metadata)
        )
        _ = try erasedExecute.catalogEntrySchema.decode(
            IPCMethodCatalogEntry.self,
            from: JSONEncoder().encode(erasedExecute.metadata)
        )
    }

    @Test("generic execute descriptor preserves unknown ids for App lookup")
    func genericExecuteDescriptorAllowsUnknownCommandIdentity() throws {
        let composition = try IPCCommandMethodComposition(
            compatibility: .current,
            commands: IPCCommandDescriptorTestFixtures.descriptors()
        )
        let unknownRequest = IPCCommandExecutionRequest(
            commandId: IPCCommandIdentifier(rawValue: "command.from.a.newer.app"),
            correlationId: IPCCommandDescriptorTestFixtures.firstCorrelationId,
            arguments: .noArguments
        )

        let decoded = try composition.execute.decodeParameters(
            from: JSONEncoder().encode(unknownRequest)
        )

        #expect(decoded == unknownRequest)
        #expect(decoded.commandId.rawValue == "command.from.a.newer.app")
    }

    @Test("composition rejects duplicate command ids")
    func compositionRejectsDuplicateCommandIdentity() throws {
        let descriptor = try IPCCommandDescriptorTestFixtures.firstDescriptor()

        #expect(throws: (any Error).self) {
            try IPCCommandMethodComposition(
                compatibility: .current,
                commands: [descriptor, descriptor]
            )
        }
    }

    @Test("composition rejects a foreign compatibility identity")
    func compositionRejectsForeignCompatibilityIdentity() throws {
        let foreignCompatibility = IPCProtocolCatalogCompatibility(
            wireProtocolIdentifier: "foreign-wire",
            catalogIdentifier: "foreign-catalog"
        )

        #expect(throws: IPCCommandMethodCompositionError.incompatibleIdentity) {
            try IPCCommandMethodComposition(
                compatibility: foreignCompatibility,
                commands: IPCCommandDescriptorTestFixtures.descriptors()
            )
        }
        #expect(throws: IPCSchemaValidationError.self) {
            try IPCCommandCatalogResult.schema(
                compatibility: foreignCompatibility,
                commands: IPCCommandDescriptorTestFixtures.descriptors()
            )
        }
    }
}
