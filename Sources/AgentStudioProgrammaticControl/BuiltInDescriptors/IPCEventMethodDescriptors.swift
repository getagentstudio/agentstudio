import Foundation

package struct IPCEventMethodDescriptors: Sendable {
    package let eventsSubscribe: IPCMethodDescriptor<IPCEventsSubscribeParams, IPCEventSubscriptionResult>
    package let eventsUnsubscribe: IPCMethodDescriptor<IPCEventsUnsubscribeParams, IPCEventsUnsubscribeResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        eventsSubscribe = try Self.eventsSubscribeEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        eventsUnsubscribe = try Self.eventsUnsubscribeEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        eventsSubscribe = try Self.eventsSubscribeEntry.typedDescriptor(in: representations)
        eventsUnsubscribe = try Self.eventsUnsubscribeEntry.typedDescriptor(in: representations)
    }

    static let eventsSubscribeEntry = IPCBuiltInMethodEntry<IPCEventsSubscribeParams, IPCEventSubscriptionResult>(
        name: "events.subscribe", summary: "Subscribe this connection to a non-empty set of event names.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try Self.eventMutation(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
                parameters: IPCEventsSubscribeParams(
                    eventNames: [.terminalCommandFinished],
                    correlationId: examples.correlationId
                ),
                result: IPCEventSubscriptionResult(
                    subscriptionId: examples.subscriptionId,
                    eventNames: [.terminalCommandFinished]
                ),
                semantics: .accepted,
                responseDelivery: .subscription
            )
        })

    static let eventsUnsubscribeEntry = IPCBuiltInMethodEntry<IPCEventsUnsubscribeParams, IPCEventsUnsubscribeResult>(
        name: "events.unsubscribe", summary: "Remove one event subscription owned by this connection.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try Self.eventMutation(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
                parameters: IPCEventsUnsubscribeParams(
                    subscriptionId: examples.subscriptionId,
                    correlationId: examples.correlationId
                ),
                result: IPCEventsUnsubscribeResult(subscriptionId: examples.subscriptionId),
                semantics: .applied
            )
        })

    private static func eventMutation<Parameters, Result>(
        name: String,
        description: String,
        agentEligibility: IPCAgentEligibility?,
        parameters: Parameters,
        result: Result,
        semantics: IPCResultSemantics,
        responseDelivery: IPCMethodResponseDelivery = .single
    ) throws -> IPCMethodDescriptor<Parameters, Result>
    where Parameters: IPCSchemaProviding, Result: IPCSchemaProviding {
        try IPCMethodDescriptor(
            name: name,
            description: description,
            examples: [
                .init(description: "Representative \(name) result", parameters: parameters, result: result)
            ],
            exposure: .allChannels,
            requiredPrivileges: [.eventsRead],
            dataScope: .permissionState,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .eventReader,
            principalAvailability: .authenticated,
            resultSemantics: semantics,
            documentedErrors: [
                IPCBuiltInDescriptorSupport.invalidParams,
                .init(
                    reason: "subscriptionNotFound", description: "The subscription does not belong to this connection."),
            ],
            isMutating: true,
            correlationPolicy: .required,
            responseDelivery: responseDelivery,
            agentEligibility: agentEligibility
        )
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: eventsSubscribe),
                IPCMethodDescriptorRepresentations(typedDescriptor: eventsUnsubscribe),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
