import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package enum AppIPCCommandMethodRegistrations {
    package static func make(
        composition: IPCCommandMethodComposition,
        port: any AppIPCCommandPort
    ) throws -> [AnyAppIPCMethodRegistration] {
        try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: composition.listRepresentations,
                correlation: .notRequired,
                resolveTarget: { parameters, context, _ in
                    try AppIPCBuiltInRegistrationSupport.principalTarget(parameters, context: context)
                },
                connectionHandler: { _, _, _ in composition.catalogResult },
                cachedTransportResult: AppIPCCachedTransportResult {
                    try composition.list.encodeResult(composition.catalogResult)
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: composition.executeRepresentations,
                correlation: .required(\.correlationId),
                preparedCorrelation: .required { (prepared: AppIPCPreparedCommand) in prepared.request.correlationId },
                prepare: commandPreparation(port: port),
                resolveTarget: { prepared, _, _ in
                    AppIPCTargetResolution(
                        parameters: prepared, canonicalHandle: prepared.canonicalHandle,
                        target: prepared.target, requiredScopes: prepared.requiredScopes,
                        resolvedPaneIds: prepared.resolvedPaneIds,
                        commandId: prepared.request.commandId.rawValue, agentArgumentRule: prepared.agentArgumentRule)
                },
                connectionHandler: { parameters, context, _ in
                    let result = try await port.executeCommand(
                        parameters.request, ownPaneAssertion: AppIPCOwnPaneAssertion(principal: context.principal))
                    guard result.commandId == parameters.request.commandId,
                        result.correlationId == parameters.request.correlationId
                    else {
                        throw AppIPCTypedMethodRegistrationError.correlationMismatch
                    }
                    return result
                }
            ).erase(),
        ]
    }
    private static func commandPreparation(port: any AppIPCCommandPort)
        -> @Sendable (IPCRawCommandExecutionRequest, AppIPCConnectionContext, AppIPCTargetResolutionTools)
        async throws(AgentStudioAppIPCRequestError) -> AppIPCPreparedCommand
    {
        { parameters, context, tools async throws(AgentStudioAppIPCRequestError) -> AppIPCPreparedCommand in
            guard let principal = context.principal else {
                throw AgentStudioAppIPCRequestError(AppIPCTypedMethodRegistrationError.authenticationRequired)
            }
            return try await port.prepareCommand(parameters, principal: principal, tools: tools)
        }
    }

}
