import Foundation

package struct IPCTerminalMethodDescriptors: Sendable {
    package let terminalStatus: IPCMethodDescriptor<IPCPaneSelectorParams, IPCTerminalStatusResult>
    package let terminalSend: IPCMethodDescriptor<IPCTerminalSendParams, IPCTerminalSendInputResult>
    package let terminalSnapshot: IPCMethodDescriptor<IPCPaneSelectorParams, IPCTerminalSnapshotResult>
    package let terminalWait: IPCMethodDescriptor<IPCTerminalWaitParams, IPCTerminalWaitResponse>

    init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        terminalStatus = try Self.terminalStatusEntry.makeDescriptor(inputs: inputs)
        terminalSend = try Self.terminalSendEntry.makeDescriptor(inputs: inputs)
        terminalSnapshot = try Self.terminalSnapshotEntry.makeDescriptor(inputs: inputs)
        terminalWait = try Self.terminalWaitEntry.makeDescriptor(inputs: inputs)
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        terminalStatus = try Self.terminalStatusEntry.typedDescriptor(in: representations)
        terminalSend = try Self.terminalSendEntry.typedDescriptor(in: representations)
        terminalSnapshot = try Self.terminalSnapshotEntry.typedDescriptor(in: representations)
        terminalWait = try Self.terminalWaitEntry.typedDescriptor(in: representations)
    }

    static let terminalStatusEntry = IPCBuiltInMethodEntry<IPCPaneSelectorParams, IPCTerminalStatusResult>(
        name: "terminal.status", summary: "Read lifecycle and capability status for one terminal pane.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
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
                agentEligibility: entryEligibility
            )
        })

    static let terminalSendEntry = IPCBuiltInMethodEntry<IPCTerminalSendParams, IPCTerminalSendInputResult>(
        name: "terminal.send", summary: "Send exact input to one terminal pane.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
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
                    agentEligibility: entryEligibility)
            )
        })

    static let terminalSnapshotEntry = IPCBuiltInMethodEntry<IPCPaneSelectorParams, IPCTerminalSnapshotResult>(
        name: "terminal.snapshot", summary: "Read one terminal runtime snapshot without terminal output.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
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
                agentEligibility: entryEligibility
            )
        })

    static let terminalWaitEntry = IPCBuiltInMethodEntry<IPCTerminalWaitParams, IPCTerminalWaitResponse>(
        name: "terminal.wait", summary: "Wait for one bounded terminal condition.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .ownPane,
        parameterSchema: { try Self.waitParameterSchema() },
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let waitParameters = IPCTerminalWaitParams(
                handle: "self",
                condition: .titleChanged,
                timeoutSeconds: 1,
                afterSequence: nil
            )
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                parameterSchema: try Self.waitParameterSchema(),
                resultSchema: try IPCTerminalWaitResponse.ipcSchema(),
                examples: [
                    .init(
                        description: "Wait for the title to change",
                        parameters: waitParameters,
                        result: IPCTerminalWaitResponse(
                            observation: IPCTerminalWaitResult(
                                paneId: inputs.examples.paneId,
                                condition: .titleChanged,
                                eventName: .terminalTitleChanged,
                                commandId: nil,
                                correlationId: nil,
                                exitCode: nil,
                                duration: nil,
                                healthy: nil
                            ), timeoutSeconds: 1, wasClamped: false)
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
                    Self.terminalWaitErrors, agentEligibility: entryEligibility),
                isMutating: false,
                correlationPolicy: .notAccepted,
                agentEligibility: entryEligibility
            )
        })

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

    private static func waitParameterSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCRequestSchemaFields.pane(),
            .init(
                name: "condition", description: "Terminal condition to observe",
                schema: try IPCTerminalWaitCondition.ipcSchema()),
            .init(
                name: "timeoutSeconds",
                description:
                    "Finite nonnegative wait duration in seconds; the server clamps to its policy maximum and reports the effective timeout",
                schema: .number(minimum: 0)),
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
