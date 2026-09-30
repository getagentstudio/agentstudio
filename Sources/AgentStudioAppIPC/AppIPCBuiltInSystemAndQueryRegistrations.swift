import AgentStudioProgrammaticControl
import Foundation

extension AppIPCBuiltInMethodRegistrations {
    static func systemAndQueryRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        try systemAndAuthRegistrations(inputs: inputs)
            + workspaceQueryRegistrations(inputs: inputs)
    }

    private static func systemAndAuthRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.systemAndAuth.systemPing),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in
                    AppIPCBuiltInRegistrationSupport.appTarget(parameters)
                },
                connectionHandler: { _, _, _ in
                    IPCSystemPingResult(runtimeId: inputs.runtimeId)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.systemAndAuth.systemIdentify),
                correlation: .notRequired,
                resolveTarget: { parameters, context, _ in
                    try AppIPCBuiltInRegistrationSupport.principalTarget(parameters, context: context)
                },
                connectionHandler: { _, _, _ in
                    try await inputs.ports.queryPort.systemIdentify()
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.systemAndAuth.systemVersion),
                correlation: .notRequired,
                resolveTarget: { parameters, context, _ in
                    try AppIPCBuiltInRegistrationSupport.principalTarget(parameters, context: context)
                },
                connectionHandler: { _, _, _ in
                    try await inputs.ports.queryPort.systemVersion()
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.systemAndAuth.authLogin),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in
                    AppIPCBuiltInRegistrationSupport.appTarget(parameters)
                },
                connectionHandler: { parameters, context, _ in
                    try await context.authenticate(parameters)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.systemAndAuth.authStatus),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in
                    AppIPCBuiltInRegistrationSupport.appTarget(parameters)
                },
                connectionHandler: { _, context, _ in
                    context.authenticationStatus()
                }
            ).erase(),
        ]
    }

    private static func workspaceQueryRegistrations(
        inputs: AppIPCBuiltInRegistrationInputs
    ) throws -> [AnyAppIPCMethodRegistration] {
        let descriptors = inputs.catalog
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.workspaceQueries.windowList),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { _, _, _ in try await inputs.ports.queryPort.listWindows() }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.workspaceQueries.windowCurrent),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { _, _, _ in try await inputs.ports.queryPort.currentWindow() }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.workspaceQueries.workspaceList),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { _, _, _ in try await inputs.ports.queryPort.listWorkspaces() }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.workspaceQueries.workspaceCurrent),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { _, _, _ in try await inputs.ports.queryPort.currentWorkspace() }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.workspaceQueries.paneList),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { _, _, _ in try await inputs.ports.queryPort.listPanes() }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.workspaceQueries.paneCurrent),
                correlation: .notRequired,
                resolveTarget: { parameters, _, _ in AppIPCBuiltInRegistrationSupport.appTarget(parameters) },
                connectionHandler: { _, _, _ in try await inputs.ports.queryPort.currentPane() }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: try inputs.descriptorRepresentations(
                    for: descriptors.workspaceQueries.paneSnapshot),
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
                    let handle = try IPCHandle.parse(parameters.handle)
                    guard case (.pane, .canonicalUUID(let paneId)) = (handle.kind, handle.reference) else {
                        throw AppIPCTypedMethodRegistrationError.targetKindNotAllowed
                    }
                    return try await inputs.ports.queryPort.snapshotPane(
                        paneId, ownPaneAssertion: AppIPCOwnPaneAssertion(principal: context.principal))
                }
            ).erase(),
        ]
    }
}
