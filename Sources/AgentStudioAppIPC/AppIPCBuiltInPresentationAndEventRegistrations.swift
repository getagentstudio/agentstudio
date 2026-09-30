import AgentStudioProgrammaticControl
import Foundation

extension AppIPCBuiltInMethodRegistrations {
    static func presentationAndEventRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        try presentationAndSidebarRegistrations(inputs: inputs)
            + eventRegistrations(inputs: inputs)
    }

    private static func presentationAndSidebarRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog.presentationAndSidebar
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.uiCommandBarOpen),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, _ in
                    AppIPCBuiltInRegistrationSupport.canonicalWindowTarget(
                        parameters,
                        windowId: parameters.workspaceWindowId
                    )
                },
                connectionHandler: { parameters, _, _ in
                    try await inputs.ports.uiPresentationPort.openCommandBar(parameters)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.uiArrangementsOpen),
                correlation: .required {
                    try AppIPCBuiltInRegistrationSupport.requiredCorrelation($0.correlationId)
                },
                resolveTarget: { parameters, _, tools in
                    let canonicalParameters: IPCArrangementsOpenParams
                    if let targetPaneHandle = parameters.targetPaneHandle {
                        let paneResolution = try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                            parameters,
                            rawHandle: targetPaneHandle,
                            tools: tools,
                            replacingHandle: { original, canonicalHandle in
                                IPCArrangementsOpenParams(
                                    workspaceWindowId: original.workspaceWindowId,
                                    targetPaneHandle: canonicalHandle,
                                    correlationId: original.correlationId
                                )
                            }
                        )
                        canonicalParameters = paneResolution.parameters
                    } else {
                        canonicalParameters = parameters
                    }
                    return AppIPCBuiltInRegistrationSupport.canonicalWindowTarget(
                        canonicalParameters,
                        windowId: canonicalParameters.workspaceWindowId
                    )
                },
                connectionHandler: { parameters, _, _ in
                    try await inputs.ports.uiPresentationPort.openArrangements(parameters)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.sidebarGroupingGet),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { parameters, _, _ in
                    try await inputs.ports.sidebarPort.getGrouping(parameters)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: descriptors.sidebarSurfaceGet),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { parameters, _, _ in
                    try await inputs.ports.sidebarPort.getSurface(parameters)
                }
            ).erase(),
        ]
    }

    private static func eventRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let events = inputs.catalog.events
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: events.eventsSubscribe),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCBuiltInRegistrationSupport.principalTarget(parameters, context: context)
                },
                connectionHandler: { parameters, context, _ in
                    guard let principal = context.principal else {
                        throw AppIPCTypedMethodRegistrationError.authenticationRequired
                    }
                    return try await inputs.eventBroker.subscribe(
                        eventNames: Set(parameters.eventNames),
                        principal: principal,
                        connectionId: context.contextId,
                        subscriber: context.eventSubscriber
                    )
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(for: events.eventsUnsubscribe),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, _ in
                    try AppIPCBuiltInRegistrationSupport.principalTarget(parameters, context: context)
                },
                connectionHandler: { parameters, context, _ in
                    guard let principal = context.principal else {
                        throw AppIPCTypedMethodRegistrationError.authenticationRequired
                    }
                    try await inputs.eventBroker.unsubscribe(
                        parameters.subscriptionId,
                        principal: principal,
                        connectionId: context.contextId
                    )
                    return IPCEventsUnsubscribeResult(subscriptionId: parameters.subscriptionId)
                }
            ).erase(),
        ]
    }
}
