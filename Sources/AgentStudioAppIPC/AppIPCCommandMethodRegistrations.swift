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
                    try JSONDecoder().decode(
                        JSONValue.self,
                        from: try composition.list.encodeResult(composition.catalogResult))
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: composition.executeRepresentations,
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, context, tools in
                    guard let principal = context.principal else {
                        throw AppIPCTypedMethodRegistrationError.authenticationRequired
                    }
                    let prepared = try await port.prepareCommand(parameters, principal: principal, tools: tools)
                    return AppIPCTargetResolution(
                        parameters: prepared.request, canonicalHandle: prepared.canonicalHandle,
                        target: prepared.target, requiredScopes: prepared.requiredScopes,
                        resolvedPaneIds: prepared.resolvedPaneIds,
                        commandId: prepared.request.commandId.rawValue,
                        agentArgumentRule: prepared.agentArgumentRule
                    )
                },
                connectionHandler: { parameters, context, _ in
                    let result = try await port.executeCommand(
                        parameters, ownPaneAssertion: AppIPCOwnPaneAssertion(principal: context.principal))
                    guard result.commandId == parameters.commandId, result.correlationId == parameters.correlationId
                    else {
                        throw AppIPCTypedMethodRegistrationError.correlationMismatch
                    }
                    return result
                }
            ).erase(),
        ]
    }
}
