import AgentStudioProgrammaticControl
import Foundation

extension AppIPCBuiltInMethodRegistrations {
    static func layoutAndTerminalRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let layout = try layoutRegistrations(inputs: inputs)
        let terminal = try terminalRegistrations(inputs: inputs)
        return layout + terminal
    }

    private static func layoutRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        try paneLayoutRegistrations(inputs: inputs)
            + drawerLayoutRegistrations(inputs: inputs)
    }

    private static func paneLayoutRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog.layout
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.paneFocus),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCPaneControlParams(
                                handle: canonicalHandle,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, _, _ in
                    try await inputs.ports.layoutPort.focusPane(IPCHandle.parse(parameters.handle))
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.paneSplit),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCPaneSplitParams(
                                handle: canonicalHandle,
                                direction: original.direction,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, _, _ in
                    try await inputs.ports.layoutPort.splitPane(parameters)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.paneClose),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        agentArgumentRule: { .closesPane($0) },
                        replacingHandle: { original, canonicalHandle in
                            IPCPaneCloseParams(
                                handle: canonicalHandle,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, context, _ in
                    try await inputs.ports.layoutPort.closePane(
                        parameters, ownPaneAssertion: AppIPCOwnPaneAssertion(principal: context.principal))
                }
            ).erase(),
        ]
    }

    private static func drawerLayoutRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog.layout
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.drawerToggle),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.parentPaneHandle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCDrawerToggleParams(
                                parentPaneHandle: canonicalHandle,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, _, _ in
                    try await inputs.ports.layoutPort.toggleDrawer(parameters)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.drawerAddPane),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.parentPaneHandle,
                        tools: tools,
                        agentArgumentRule: {
                            .addsDrawerChild(parentPaneId: $0, content: parameters.content ?? .terminal)
                        },
                        replacingHandle: { original, canonicalHandle in
                            IPCDrawerAddPaneParams(
                                parentPaneHandle: canonicalHandle,
                                content: original.content,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, context, _ in
                    try await inputs.ports.layoutPort.addDrawerPane(
                        parameters, ownPaneAssertion: AppIPCOwnPaneAssertion(principal: context.principal))
                }
            ).erase(),
        ]
    }

    private static func terminalRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog.terminal
        return try [
            terminalPaneReadRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.terminalStatus),
                handler: { handle, assertion in
                    try await inputs.ports.runtimePort.terminalStatus(handle, ownPaneAssertion: assertion)
                }
            ),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.terminalSend),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCTerminalSendParams(
                                handle: canonicalHandle,
                                input: original.input,
                                correlationId: original.correlationId
                            )
                        }
                    )
                },
                connectionHandler: { parameters, context, _ in
                    try await inputs.ports.runtimePort.sendTerminalInput(
                        to: IPCHandle.parse(parameters.handle),
                        input: parameters.input,
                        correlationId: parameters.correlationId,
                        ownPaneAssertion: AppIPCOwnPaneAssertion(principal: context.principal)
                    )
                }
            ).erase(),
            terminalPaneReadRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.terminalSnapshot),
                handler: { handle, assertion in
                    try await inputs.ports.runtimePort.terminalSnapshot(handle, ownPaneAssertion: assertion)
                }
            ),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.terminalWait),
                correlation: .notRequired,
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters,
                        rawHandle: parameters.handle,
                        tools: tools,
                        replacingHandle: { original, canonicalHandle in
                            IPCTerminalWaitParams(
                                handle: canonicalHandle,
                                condition: original.condition,
                                timeoutSeconds: original.timeoutSeconds,
                                afterSequence: original.afterSequence
                            )
                        }
                    )
                },
                connectionHandler: { parameters, context, _ in
                    try await inputs.ports.runtimePort.waitForTerminal(
                        IPCHandle.parse(parameters.handle),
                        condition: parameters.condition,
                        timeout: AppIPCBuiltInRegistrationSupport.duration(seconds: parameters.timeoutSeconds),
                        afterSequence: parameters.afterSequence,
                        ownPaneAssertion: AppIPCOwnPaneAssertion(principal: context.principal)
                    )
                }
            ).erase(),
        ]
    }

    private static func terminalPaneReadRegistration<Result>(
        descriptorRepresentations: IPCMethodDescriptorRepresentations<IPCPaneSelectorParams, Result>,
        handler: @escaping @Sendable (IPCHandle, AppIPCOwnPaneAssertion?) async throws -> Result
    ) throws -> AnyAppIPCMethodRegistration
    where Result: Codable & Sendable {
        try AppIPCTypedMethodRegistration(
            descriptorRepresentations: descriptorRepresentations,
            correlation: .notRequired,
            resolveTarget: { parameters, _, tools in
                try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                    parameters,
                    rawHandle: parameters.handle,
                    tools: tools,
                    replacingHandle: { _, canonicalHandle in
                        IPCPaneSelectorParams(handle: canonicalHandle)
                    }
                )
            },
            connectionHandler: { parameters, context, _ in
                try await handler(
                    IPCHandle.parse(parameters.handle), AppIPCOwnPaneAssertion(principal: context.principal))
            }
        ).erase()
    }
}
