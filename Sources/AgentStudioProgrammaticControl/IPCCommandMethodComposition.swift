import Foundation

package enum IPCCommandMethodCompositionError: Error, Equatable, Sendable {
    case incompatibleIdentity
    case emptyCommandCatalog
    case duplicateCommandIdentifier(String)
}

/// One immutable command value supplies discovery, server registration, and
/// later descriptor-driven CLI construction.
package struct IPCCommandMethodComposition: Sendable {
    package static let executionErrors = [
        IPCMethodErrorCase(
            reason: "invalidParams",
            description: "The command envelope or selected typed arguments are invalid."
        ),
        IPCMethodErrorCase(
            reason: "missingGrant",
            description: "The principal lacks a required canonical command scope."
        ),
        IPCMethodErrorCase(
            reason: "targetNotFound",
            description: "The selected command target does not exist."
        ),
        IPCMethodErrorCase(
            reason: "unknownCommand",
            description: "The open command identifier is not known by this application."
        ),
        IPCMethodErrorCase(
            reason: "unsupportedCommand",
            description: "The known command is unavailable on this channel."
        ),
        IPCMethodErrorCase(
            reason: "stateUnavailable",
            description: "The selected command owner cannot currently apply the command."
        ),
        IPCMethodErrorCase(
            reason: "notYetAllowed",
            description: "A pane agent named a command or target outside its own pane."
        ),
        IPCMethodErrorCase(
            reason: "refusedForAgent",
            description: "A pane agent asked for an effect agents are never allowed."
        ),
    ]

    package let commands: [IPCCommandDescriptor]
    package let catalogResult: IPCCommandCatalogResult
    package let list: IPCMethodDescriptor<IPCEmptyParams, IPCCommandCatalogResult>
    package let execute: IPCMethodDescriptor<IPCCommandExecutionRequest, IPCCommandExecutionResult>
    package let listRepresentations: IPCMethodDescriptorRepresentations<IPCEmptyParams, IPCCommandCatalogResult>
    package let executeRepresentations:
        IPCMethodDescriptorRepresentations<
            IPCCommandExecutionRequest,
            IPCCommandExecutionResult
        >

    package init(
        compatibility: IPCProtocolCatalogCompatibility,
        commands: [IPCCommandDescriptor],
        recognizedUnexposedCommands: [IPCRecognizedUnexposedName] = []
    ) throws {
        guard compatibility == .current else {
            throw IPCCommandMethodCompositionError.incompatibleIdentity
        }
        guard !commands.isEmpty else { throw IPCCommandMethodCompositionError.emptyCommandCatalog }
        var observedIdentifiers: Set<String> = []
        for command in commands {
            guard observedIdentifiers.insert(command.id.rawValue).inserted else {
                throw IPCCommandMethodCompositionError.duplicateCommandIdentifier(command.id.rawValue)
            }
        }

        let commands = commands.sorted { $0.id.rawValue < $1.id.rawValue }
        let catalogResult = IPCCommandCatalogResult(
            compatibility: compatibility,
            commands: commands,
            recognizedUnexposedCommands: recognizedUnexposedCommands.sorted { $0.name < $1.name }
        )
        let catalogSchema = try IPCCommandCatalogResult.schema(
            compatibility: compatibility,
            commands: commands
        )
        let argumentVariants = Self.uniqueArgumentVariants(in: commands)
        let resultVariants = Self.uniqueResultVariants(in: commands)
        let methodExamples = commands.flatMap(\.examples).map {
            IPCMethodExample(
                description: $0.description,
                parameters: $0.request,
                result: $0.result
            )
        }

        let list = try IPCMethodDescriptor(
            name: "command.list",
            description: "Return the complete available typed App command catalog.",
            parameterSchema: try IPCEmptyParams.ipcSchema(),
            resultSchema: catalogSchema,
            examples: [
                IPCMethodExample(
                    description: "List the commands composed for this runtime and channel.",
                    parameters: IPCEmptyParams(),
                    result: catalogResult
                )
            ],
            exposure: .allChannels,
            requiredPrivileges: [.systemRead],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [],
            isMutating: false,
            correlationPolicy: .notAccepted,
            agentEligibility: .anyTarget
        )
        let execute = try Self.makeExecute(
            description: "Execute one available App command through its typed arguments.",
            argumentVariants: argumentVariants,
            resultVariants: resultVariants,
            examples: methodExamples,
            allowedTargetKinds: Set(commands.flatMap(\.allowedTargetKinds))
        )

        for example in methodExamples {
            _ = try execute.decodeParameters(from: JSONEncoder().encode(example.parameters))
            _ = try execute.encodeResult(example.result)
        }
        let listRepresentations = try IPCMethodDescriptorRepresentations(typedDescriptor: list)
        let executeRepresentations = try IPCMethodDescriptorRepresentations(typedDescriptor: execute)

        self.commands = commands
        self.catalogResult = catalogResult
        self.list = list
        self.execute = execute
        self.listRepresentations = listRepresentations
        self.executeRepresentations = executeRepresentations
    }

    /// The `command.execute` shape a client uses for a command the app
    /// recognizes but this channel hides. The channel's catalog carries no
    /// descriptor for such a command, so its request is typed against every
    /// argument variant this build compiles; the app refuses a hidden command
    /// by name before it validates arguments. A client uses it only for an
    /// identifier the app listed as recognized and hidden; it is never
    /// registered by the server.
    package static func recognizedHiddenExecute() throws
        -> IPCMethodDescriptor<IPCCommandExecutionRequest, IPCCommandExecutionResult>
    {
        try makeExecute(
            description: "Name one App command this channel hides so the app refuses it by name.",
            argumentVariants: IPCCommandArgumentVariant.allCases,
            resultVariants: IPCCommandResultVariant.allCases,
            examples: [],
            allowedTargetKinds: Set(IPCHandleKind.allCases)
        )
    }

    // Each command's own `agentEligibility` decides admission; the method
    // itself only carries the pane-scoped class.
    private static func makeExecute(
        description: String,
        argumentVariants: [IPCCommandArgumentVariant],
        resultVariants: [IPCCommandResultVariant],
        examples: [IPCMethodExample<IPCCommandExecutionRequest, IPCCommandExecutionResult>],
        allowedTargetKinds: Set<IPCHandleKind>
    ) throws -> IPCMethodDescriptor<IPCCommandExecutionRequest, IPCCommandExecutionResult> {
        try IPCMethodDescriptor(
            name: "command.execute",
            description: description,
            parameterSchema: try IPCCommandExecutionRequest.ipcSchema(allowing: argumentVariants),
            resultSchema: try IPCCommandExecutionResult.ipcSchema(allowing: resultVariants),
            examples: examples,
            exposure: .allChannels,
            requiredPrivileges: [.appCommandExecute],
            dataScope: .unspecified,
            allowedTargetKinds: allowedTargetKinds,
            commandRelationship: .appCommandParameter(field: "commandId"),
            executionOwner: .appCommand,
            principalAvailability: .authenticated,
            resultSemantics: .discriminated,
            documentedErrors: executionErrors,
            isMutating: true,
            correlationPolicy: .required,
            agentEligibility: .ownPane
        )
    }

    private static func uniqueArgumentVariants(
        in commands: [IPCCommandDescriptor]
    ) -> [IPCCommandArgumentVariant] {
        Array(Set(commands.flatMap(\.argumentVariants))).sorted { $0.rawValue < $1.rawValue }
    }

    private static func uniqueResultVariants(
        in commands: [IPCCommandDescriptor]
    ) -> [IPCCommandResultVariant] {
        Array(Set(commands.flatMap(\.resultVariants))).sorted { $0.rawValue < $1.rawValue }
    }
}
