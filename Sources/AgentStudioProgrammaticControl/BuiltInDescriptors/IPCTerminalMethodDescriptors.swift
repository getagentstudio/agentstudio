import Foundation

package struct IPCTerminalMethodDescriptors: Sendable {
    package let terminalStatus: IPCMethodDescriptor<IPCPaneSelectorParams, IPCTerminalStatusResult>
    package let terminalSend: IPCMethodDescriptor<IPCTerminalSendParams, IPCTerminalSendInputResult>
    package let terminalSnapshot: IPCMethodDescriptor<IPCPaneSelectorParams, IPCTerminalSnapshotResult>
    package let terminalWait: IPCMethodDescriptor<IPCTerminalWaitParams, IPCTerminalWaitResult>

    init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        let example = inputs.examples
        terminalStatus = try IPCBuiltInDescriptorSupport.read(
            name: "terminal.status",
            description: "Read lifecycle and capability status for one terminal pane.",
            parameters: IPCPaneSelectorParams(handle: "self"),
            result: IPCTerminalStatusResult(
                paneId: example.paneId,
                lifecycle: .ready,
                isReady: true,
                backend: .local,
                capabilities: ["input"]
            ),
            privilege: .terminalStatusRead,
            dataScope: .terminalStatus,
            targetKinds: [.pane],
            exposure: .allChannels,
            owner: .runtimeCommand,
            errors: Self.terminalErrors,
            agentEligibility: .ownPane
        )
        terminalSend = try IPCBuiltInDescriptorSupport.mutation(
            name: "terminal.send",
            description: "Send exact input to one terminal pane.",
            parameters: IPCTerminalSendParams(
                handle: "self",
                input: "printf 'hello'\n",
                correlationId: example.correlationId
            ),
            result: IPCTerminalSendInputResult(
                paneId: example.paneId,
                commandId: example.commandId,
                correlationId: example.correlationId,
                disposition: .accepted,
                queuePosition: nil
            ),
            metadata: .init(
                privilege: .terminalInputWrite,
                dataScope: .terminalInput,
                targetKinds: [.pane],
                owner: .runtimeCommand,
                semantics: .accepted,
                errors: Self.terminalErrors,
                exposure: .allChannels,
                agentEligibility: .ownPane)
        )
        terminalSnapshot = try IPCBuiltInDescriptorSupport.read(
            name: "terminal.snapshot",
            description: "Read one terminal runtime snapshot without terminal output.",
            parameters: IPCPaneSelectorParams(handle: "self"),
            result: IPCTerminalSnapshotResult(
                paneId: example.paneId,
                lifecycle: .ready,
                backend: .local,
                capabilities: ["input"],
                lastSequence: 1,
                timestamp: Date(timeIntervalSinceReferenceDate: 0),
                rendererHealthy: true,
                readOnly: false,
                secureInput: false
            ),
            privilege: .terminalSnapshotRead,
            dataScope: .terminalSnapshot,
            targetKinds: [.pane],
            exposure: .allChannels,
            owner: .runtimeCommand,
            errors: Self.terminalErrors,
            agentEligibility: .ownPane
        )
        terminalWait = try Self.makeWaitDescriptor(inputs: inputs)
    }

    private static func makeWaitDescriptor(
        inputs: IPCBuiltInMethodCatalogInputs
    ) throws -> IPCMethodDescriptor<IPCTerminalWaitParams, IPCTerminalWaitResult> {
        let waitParameters = IPCTerminalWaitParams(
            handle: "self",
            condition: .titleChanged,
            timeoutSeconds: min(1, inputs.terminalWaitMaximumSeconds),
            afterSequence: nil
        )
        return try IPCMethodDescriptor(
            name: "terminal.wait",
            description: "Wait for one bounded terminal condition.",
            parameterSchema: try Self.waitParameterSchema(maximumSeconds: inputs.terminalWaitMaximumSeconds),
            resultSchema: try IPCTerminalWaitResult.ipcSchema(),
            examples: [
                .init(
                    description: "Wait for the title to change",
                    parameters: waitParameters,
                    result: IPCTerminalWaitResult(
                        paneId: inputs.examples.paneId,
                        condition: .titleChanged,
                        eventName: .terminalTitleChanged,
                        commandId: nil,
                        correlationId: nil,
                        exitCode: nil,
                        duration: nil,
                        healthy: nil
                    )
                )
            ],
            exposure: .allChannels,
            requiredPrivileges: [.terminalWait],
            dataScope: .terminalWait,
            allowedTargetKinds: [.pane],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .runtimeCommand,
            principalAvailability: .authenticated,
            resultSemantics: .accepted,
            documentedErrors: IPCBuiltInDescriptorSupport.documentedErrors(
                Self.terminalWaitErrors, agentEligibility: .ownPane),
            isMutating: false,
            correlationPolicy: .notAccepted,
            agentEligibility: .ownPane
        )
    }

    private static var terminalErrors: [IPCMethodErrorCase] {
        [
            IPCBuiltInDescriptorSupport.invalidParams,
            IPCBuiltInDescriptorSupport.targetNotFound,
            .init(reason: "runtimeNotReady", description: "The terminal runtime cannot accept the request."),
        ]
    }

    private static var terminalWaitErrors: [IPCMethodErrorCase] {
        Self.terminalErrors + [
            .init(
                reason: "timeout",
                description: "The condition was not observed before the bounded timeout"
            ),
            .init(
                reason: "replayGap",
                description: "Events after `afterSequence` are no longer retained"
            ),
        ]
    }

    private static func waitParameterSchema(maximumSeconds: Double) throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "condition", description: "Terminal condition to observe",
                schema: try IPCTerminalWaitCondition.ipcSchema()),
            .init(
                name: "timeoutSeconds", description: "Finite bounded wait duration in seconds",
                schema: .number(minimum: 0, maximum: maximumSeconds)),
            .optional(
                "afterSequence", description: "Observe only events after this terminal sequence",
                schema: IPCSchemaScalars.unsignedInteger),
        ])
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: terminalStatus),
                IPCMethodDescriptorRepresentations(typedDescriptor: terminalSend),
                IPCMethodDescriptorRepresentations(typedDescriptor: terminalSnapshot),
                IPCMethodDescriptorRepresentations(typedDescriptor: terminalWait),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
