import Foundation

package enum IPCCommandMethodCompositionError: Error, Equatable, Sendable {
    case incompatibleIdentity
    case emptyCommandCatalog
    case duplicateCommandIdentifier(String)
}

/// One immutable command value supplies discovery, server registration, and
/// its compiled raw CLI envelope and help projection.
package struct IPCCommandMethodComposition: Sendable {
    package static var listHelp: IPCMethodHelpProjection {
        IPCMethodHelpProjection(
            name: "command.list", summary: "Return the complete available typed App command catalog.",
            agentAccess: .readOnly, argumentSyntax: .schemaOptions,
            parameterSchema: { try IPCEmptyParams.ipcSchema() },
            exampleArguments: { _ in ["--json", "'{}'"] })
    }

    package static var executeHelp: IPCMethodHelpProjection {
        IPCMethodHelpProjection(
            name: "command.execute",
            summary: "Execute one available App command with raw strings parsed against its owning spec.",
            agentAccess: .selectedCommand, argumentSyntax: .rawCommandStrings,
            parameterSchema: { try IPCRawCommandExecutionRequest.ipcSchema() },
            exampleArguments: { inputs in
                // The existing scroll-to-bottom command example needs only its window and pane target.
                [
                    "--command-id", "scrollToBottom", "--arg", "workspaceWindowId=\(inputs.examples.windowId)",
                    "--arg", "paneSelector=self",
                ]
            })
    }

    package static let executionErrors = [
        IPCMethodErrorCase(
            reason: "invalidParams",
            description: "The command envelope or selected typed arguments are invalid."
        ),
        IPCMethodErrorCase(
            reason: "invalidArguments", description: "Raw argument strings do not match the selected command spec."),
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
    package let execute: IPCMethodDescriptor<IPCRawCommandExecutionRequest, IPCCommandExecutionResult>
    package let listRepresentations: IPCMethodDescriptorRepresentations<IPCEmptyParams, IPCCommandCatalogResult>
    package let executeRepresentations:
        IPCMethodDescriptorRepresentations<
            IPCRawCommandExecutionRequest,
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
        let resultVariants = Self.uniqueResultVariants(in: commands)
        let commandExamples: [IPCCommandExample] = commands.flatMap(\.examples)
        let methodExamples: [IPCMethodExample<IPCRawCommandExecutionRequest, IPCCommandExecutionResult>] =
            try commandExamples.map {
                IPCMethodExample(
                    description: $0.description,
                    parameters: try IPCRawCommandExecutionRequest(typedRequest: $0.request),
                    result: $0.result
                )
            }

        let list = try IPCMethodDescriptor(
            name: Self.listHelp.name,
            description: Self.listHelp.summary,
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
            description: Self.executeHelp.summary,
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

    /// The compiled raw command envelope accepts any command name; only App
    /// knows its spec, channel visibility and argument validation.
    package static func compiledExecute() throws
        -> IPCMethodDescriptor<IPCRawCommandExecutionRequest, IPCCommandExecutionResult>
    {
        try makeExecute(
            description: "Execute one App command with raw strings parsed against its owning spec.",
            resultVariants: IPCCommandResultVariant.allCases, examples: [],
            allowedTargetKinds: Set(IPCHandleKind.allCases))
    }

    // Each command's own `agentEligibility` decides admission; the method
    // itself only carries the pane-scoped class.
    private static func makeExecute(
        description: String,
        resultVariants: [IPCCommandResultVariant],
        examples: [IPCMethodExample<IPCRawCommandExecutionRequest, IPCCommandExecutionResult>],
        allowedTargetKinds: Set<IPCHandleKind>
    ) throws -> IPCMethodDescriptor<IPCRawCommandExecutionRequest, IPCCommandExecutionResult> {
        try IPCMethodDescriptor(
            name: Self.executeHelp.name,
            description: description,
            parameterSchema: try IPCRawCommandExecutionRequest.ipcSchema(),
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

    private static func uniqueResultVariants(
        in commands: [IPCCommandDescriptor]
    ) -> [IPCCommandResultVariant] {
        Array(Set(commands.flatMap(\.resultVariants))).sorted { $0.rawValue < $1.rawValue }
    }
}
