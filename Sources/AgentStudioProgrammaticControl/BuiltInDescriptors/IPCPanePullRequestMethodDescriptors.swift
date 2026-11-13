import Foundation

package struct IPCPanePullRequestMethodDescriptors: Sendable {
    package let add: IPCMethodDescriptor<IPCPanePullRequestMutationParams, IPCPanePullRequestAddResult>
    package let remove: IPCMethodDescriptor<IPCPanePullRequestMutationParams, IPCPanePullRequestRemoveResult>
    package let list: IPCMethodDescriptor<IPCPanePullRequestListParams, IPCPanePullRequestListResult>

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        add = try Self.addEntry.typedDescriptor(in: representations)
        remove = try Self.removeEntry.typedDescriptor(in: representations)
        list = try Self.listEntry.typedDescriptor(in: representations)
    }

    static let addEntry = IPCBuiltInMethodEntry<IPCPanePullRequestMutationParams, IPCPanePullRequestAddResult>(
        name: "pane.pullRequest.add",
        summary: "Add a GitHub PR to any main pane, idempotently per authenticated author; at most 20 PRs.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .anyTarget,
        makeDescriptor: { name, summary, _, eligibility, inputs in
            try IPCMethodDescriptor(
                name: name, description: summary, callIntent: .control,
                examples: [.init(description: "Add a PR", parameters: mutationExample(inputs), result: .added)],
                exposure: .allChannels, requiredPrivileges: [.paneContextWrite], dataScope: .paneContext,
                allowedTargetKinds: [.pane], commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService, principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: errors, isMutating: true, correlationPolicy: .required, agentEligibility: eligibility)
        })

    static let removeEntry = IPCBuiltInMethodEntry<IPCPanePullRequestMutationParams, IPCPanePullRequestRemoveResult>(
        name: "pane.pullRequest.remove",
        summary: "Withdraw the authenticated author's contribution to a GitHub PR on a main pane.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .anyTarget,
        makeDescriptor: { name, summary, _, eligibility, inputs in
            try IPCMethodDescriptor(
                name: name, description: summary, callIntent: .control,
                examples: [
                    .init(
                        description: "Remove an author's PR contribution", parameters: mutationExample(inputs),
                        result: .removed)
                ],
                exposure: .allChannels, requiredPrivileges: [.paneContextWrite], dataScope: .paneContext,
                allowedTargetKinds: [.pane], commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService, principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: errors, isMutating: true, correlationPolicy: .required, agentEligibility: eligibility)
        })

    static let listEntry = IPCBuiltInMethodEntry<IPCPanePullRequestListParams, IPCPanePullRequestListResult>(
        name: "pane.pullRequest.list",
        summary: "Read a main pane's PR list in popover order, including known state and sources.",
        modelCalls: [], correlationPolicy: .notAccepted, agentEligibility: .anyTarget,
        makeDescriptor: { name, summary, _, eligibility, inputs in
            try IPCMethodDescriptor(
                name: name, description: summary, callIntent: .read,
                examples: [
                    .init(
                        description: "Read the PR list",
                        parameters: .init(targetPaneHandle: inputs.examples.paneId.uuidString), result: .init(rows: []))
                ],
                exposure: .allChannels, requiredPrivileges: [.paneContextRead], dataScope: .paneContext,
                allowedTargetKinds: [.pane], commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService, principalAvailability: .authenticated, resultSemantics: .applied,
                documentedErrors: errors, isMutating: false, correlationPolicy: .notAccepted,
                agentEligibility: eligibility)
        })

    private static func mutationExample(_ inputs: IPCBuiltInMethodCatalogInputs) -> IPCPanePullRequestMutationParams {
        .init(
            targetPaneHandle: inputs.examples.paneId.uuidString,
            pullRequest: .init(host: "github.com", owner: "owner", repository: "repo", number: 7),
            correlationId: inputs.examples.correlationId)
    }

    private static var errors: [IPCMethodErrorCase] {
        [
            IPCBuiltInDescriptorSupport.invalidParams, IPCBuiltInDescriptorSupport.targetNotFound,
            IPCLayoutMethodDescriptors.drawerBrowseNotMainPane, IPCLayoutMethodDescriptors.drawerBrowseNoActiveWindow,
            .init(reason: "notGitHub", description: "Only GitHub pull request identities are admitted."),
            .init(reason: "invalidField", description: "A PR parameter is malformed or contains an unknown field."),
            .init(reason: "unavailable", description: "Pane-context storage is unavailable."),
        ]
    }
}
