import AgentStudioProgrammaticControl
import Foundation

package struct AppIPCPanePullRequestCaller: Sendable {
    package let principal: IPCPrincipal
    package let credentialIdentity: AgentStudioIPCAuthenticatedCredentialIdentity?

    package init(principal: IPCPrincipal, credentialIdentity: AgentStudioIPCAuthenticatedCredentialIdentity?) {
        self.principal = principal
        self.credentialIdentity = credentialIdentity
    }
}

package protocol AppIPCPanePullRequestPort: Sendable {
    func addPullRequest(_ params: IPCPanePullRequestMutationParams, caller: AppIPCPanePullRequestCaller) async throws
        -> IPCPanePullRequestAddResult
    func removePullRequest(_ params: IPCPanePullRequestMutationParams, caller: AppIPCPanePullRequestCaller) async throws
        -> IPCPanePullRequestRemoveResult
    func listPullRequests(_ params: IPCPanePullRequestListParams) async throws -> IPCPanePullRequestListResult
}

package struct UnavailableAppIPCPanePullRequestPort: AppIPCPanePullRequestPort {
    package init() {}
    package func addPullRequest(_ params: IPCPanePullRequestMutationParams, caller: AppIPCPanePullRequestCaller)
        async throws -> IPCPanePullRequestAddResult
    {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func removePullRequest(_ params: IPCPanePullRequestMutationParams, caller: AppIPCPanePullRequestCaller)
        async throws -> IPCPanePullRequestRemoveResult
    {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
    package func listPullRequests(_ params: IPCPanePullRequestListParams) async throws -> IPCPanePullRequestListResult {
        throw AppIPCPaneContextError(reason: .unavailable)
    }
}

extension AppIPCBuiltInMethodRegistrations {
    static func panePullRequestRegistrations(inputs: AppIPCBuiltInRegistrationInputs) throws
        -> [AnyAppIPCMethodRegistration]
    {
        let descriptors = inputs.catalog.panePullRequests
        let port = inputs.ports.panePullRequestPort
        return try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: inputs.descriptorRepresentations(for: descriptors.add),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters, rawHandle: parameters.targetPaneHandle, tools: tools,
                        replacingHandle: { original, target in
                            .init(
                                targetPaneHandle: target, pullRequest: original.pullRequest, writer: original.writer,
                                correlationId: original.correlationId)
                        })
                },
                connectionHandler: { parameters, context, _ in
                    try await port.addPullRequest(parameters, caller: pullRequestCaller(context))
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: inputs.descriptorRepresentations(for: descriptors.remove),
                correlation: .required(\.correlationId),
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters, rawHandle: parameters.targetPaneHandle, tools: tools,
                        replacingHandle: { original, target in
                            .init(
                                targetPaneHandle: target, pullRequest: original.pullRequest, writer: original.writer,
                                correlationId: original.correlationId)
                        })
                },
                connectionHandler: { parameters, context, _ in
                    try await port.removePullRequest(parameters, caller: pullRequestCaller(context))
                }
            ).erase(),
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: inputs.descriptorRepresentations(for: descriptors.list),
                correlation: .notRequired,
                resolveTarget: { parameters, _, tools in
                    try await AppIPCBuiltInRegistrationSupport.canonicalPaneTarget(
                        parameters, rawHandle: parameters.targetPaneHandle, tools: tools,
                        replacingHandle: { _, target in .init(targetPaneHandle: target) })
                },
                connectionHandler: { parameters, _, _ in try await port.listPullRequests(parameters) }
            ).erase(),
        ]
    }

    private static func pullRequestCaller(_ context: AppIPCConnectionContext) throws -> AppIPCPanePullRequestCaller {
        guard let principal = context.principal else { throw AppIPCTypedMethodRegistrationError.authenticationRequired }
        try context.revalidatePaneClaim()
        return .init(principal: principal, credentialIdentity: context.authenticatedContext?.credentialIdentity)
    }
}
