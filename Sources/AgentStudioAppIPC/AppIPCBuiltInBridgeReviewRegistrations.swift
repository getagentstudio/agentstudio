import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

struct AppIPCBridgePaneBinding<Parameters, Result>: Sendable
where Parameters: Codable & Sendable, Result: Codable & Sendable {
    let descriptor: IPCMethodDescriptor<Parameters, Result>
    let correlation: (@Sendable (Parameters) throws -> UUID)?
    let rawHandle: @Sendable (Parameters) -> String
    let rebuild: @Sendable (Parameters, String) -> Parameters
    let handler: @Sendable (Parameters) async throws -> Result
}

extension AppIPCBuiltInMethodRegistrations {
    static func bridgeRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        try bridgeReviewRegistrations(inputs: inputs)
            + bridgeControlAndTelemetryRegistrations(inputs: inputs)
    }

    private static func bridgeReviewRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        try bridgeCreationRegistrations(inputs: inputs)
            + bridgeReviewPaneRegistrations(inputs: inputs)
    }

    private static func bridgeCreationRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog.bridge.review
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.bridgeDiffLoad),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, _ in
                    AppIPCBuiltInRegistrationSupport.appTarget(parameters)
                },
                connectionHandler: { parameters, _, _ in
                    let result = try await inputs.ports.bridgePort.openReview(parameters)
                    await publishBridgeReviewUpdated(
                        paneId: result.paneId,
                        correlationId: result.correlationId,
                        inputs: inputs
                    )
                    return result
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.bridgeFileViewOpen),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, _ in
                    AppIPCBuiltInRegistrationSupport.appTarget(parameters)
                },
                connectionHandler: { parameters, _, _ in
                    let result = try await inputs.ports.bridgePort.openFileView(parameters)
                    await publishBridgeReviewUpdated(
                        paneId: result.paneId,
                        correlationId: result.correlationId,
                        inputs: inputs
                    )
                    return result
                }
            ).erase(),
        ]
    }

    private static func bridgeReviewPaneRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog.bridge.review
        return try [
            bridgePaneRegistration(
                binding: AppIPCBridgePaneBinding(
                    descriptor: descriptors.bridgeDiffRefresh,
                    correlation: {
                        try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                    },
                    rawHandle: { $0.handle },
                    rebuild: { original, canonicalHandle in
                        IPCBridgeReviewRefreshParams(
                            handle: canonicalHandle,
                            correlationId: original.correlationId
                        )
                    },
                    handler: { parameters in
                        let result = try await inputs.ports.bridgePort.refreshReview(parameters)
                        await publishBridgeReviewUpdated(
                            paneId: result.paneId,
                            packageId: result.packageId,
                            correlationId: result.correlationId,
                            inputs: inputs
                        )
                        return result
                    }
                ),
                inputs: inputs,
            ),
            bridgePaneRegistration(
                binding: AppIPCBridgePaneBinding(
                    descriptor: descriptors.bridgeDiffGetPackage,
                    correlation: nil,
                    rawHandle: { $0.handle },
                    rebuild: { _, canonicalHandle in IPCBridgePaneParams(handle: canonicalHandle) },
                    handler: { parameters in
                        try await inputs.ports.bridgePort.getPackage(IPCHandle.parse(parameters.handle))
                    }
                ),
                inputs: inputs,
            ),
            bridgePaneRegistration(
                binding: AppIPCBridgePaneBinding(
                    descriptor: descriptors.bridgeDiffRenderState,
                    correlation: nil,
                    rawHandle: { $0.handle },
                    rebuild: { _, canonicalHandle in IPCBridgePaneParams(handle: canonicalHandle) },
                    handler: { parameters in
                        try await inputs.ports.bridgePort.renderState(IPCHandle.parse(parameters.handle))
                    }
                ),
                inputs: inputs,
            ),
            bridgePaneRegistration(
                binding: AppIPCBridgePaneBinding(
                    descriptor: descriptors.bridgeDiffSelectFile,
                    correlation: {
                        try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                    },
                    rawHandle: { $0.handle },
                    rebuild: { original, canonicalHandle in
                        IPCBridgeReviewSelectFileParams(
                            handle: canonicalHandle,
                            itemId: original.itemId,
                            correlationId: original.correlationId
                        )
                    },
                    handler: { parameters in
                        let result = try await inputs.ports.bridgePort.selectFile(parameters)
                        if result.selected {
                            await publishBridgeFileSelected(
                                paneId: result.paneId,
                                itemId: result.itemId,
                                correlationId: result.correlationId,
                                inputs: inputs
                            )
                        }
                        return result
                    }
                ),
                inputs: inputs,
            ),
        ]
    }

    static func bridgePaneRegistration<Parameters, Result>(
        binding: AppIPCBridgePaneBinding<Parameters, Result>,
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> AnyAppIPCMethodRegistration
    where Parameters: Codable & Sendable, Result: Codable & Sendable {
        let correlationPolicy: AppIPCCorrelation<Parameters>
        if let correlation = binding.correlation {
            correlationPolicy = .required(correlation)
        } else {
            correlationPolicy = .notRequired
        }
        return try AppIPCTypedMethodRegistration(
            descriptorRepresentations: try inputs.descriptorRepresentations(for: binding.descriptor),
            correlation: correlationPolicy,
            resolveTarget: { parameters, _, tools in
                try await AppIPCBuiltInRegistrationSupport.validatedBridgePaneTarget(
                    parameters,
                    rawHandle: binding.rawHandle(parameters),
                    tools: tools,
                    queryPort: inputs.ports.queryPort,
                    replacingHandle: binding.rebuild
                )
            },
            connectionHandler: { parameters, _, _ in try await binding.handler(parameters) }
        ).erase()
    }

    static func publishBridgeReviewUpdated(
        paneId: UUID,
        packageId: String? = nil,
        correlationId: UUID?,
        inputs: AppIPCBuiltInRegistrationInputs
    ) async {
        await publishBridgeEvent(
            name: .bridgeReviewUpdated,
            payload: IPCBridgeEventPayload(
                paneId: paneId,
                packageId: packageId,
                correlationId: correlationId
            ),
            inputs: inputs
        )
    }

    static func publishBridgeFileSelected(
        paneId: UUID,
        itemId: String,
        correlationId: UUID?,
        inputs: AppIPCBuiltInRegistrationInputs
    ) async {
        await publishBridgeEvent(
            name: .bridgeFileSelected,
            payload: IPCBridgeEventPayload(
                paneId: paneId,
                itemId: itemId,
                correlationId: correlationId
            ),
            inputs: inputs
        )
    }

    static func publishBridgeEvent(
        name: IPCEventName,
        payload: IPCBridgeEventPayload,
        inputs: AppIPCBuiltInRegistrationInputs
    ) async {
        let notification = IPCEventNotification(
            eventId: UUIDv7.generate(),
            name: name,
            occurredAt: Date(),
            payload: .bridge(payload)
        )
        _ = await inputs.eventBroker.publish(notification) { notification, principal in
            bridgeEventIsVisible(notification, to: principal)
        }
    }

    private static func bridgeEventIsVisible(
        _ notification: IPCEventNotification,
        to principal: IPCPrincipal
    ) -> Bool {
        guard case .bridge(let payload) = notification.payload else {
            return false
        }
        switch principal.kind {
        case .spawnedPaneAgent(let boundPaneId, _):
            return boundPaneId == payload.paneId.uuidString
        case .automationClient, .unsafeDebugClient:
            return true
        case .futureMCPClient:
            return false
        }
    }
}
