import Foundation

package struct IPCEventMethodDescriptors: Sendable {
    package let eventsSubscribe: IPCMethodDescriptor<IPCEventsSubscribeParams, IPCEventSubscriptionResult>
    package let eventsUnsubscribe: IPCMethodDescriptor<IPCEventsUnsubscribeParams, IPCEventsUnsubscribeResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        eventsSubscribe = try Self.eventMutation(
            name: "events.subscribe",
            description: "Subscribe this connection to a non-empty set of event names.",
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
        eventsUnsubscribe = try Self.eventMutation(
            name: "events.unsubscribe",
            description: "Remove one event subscription owned by this connection.",
            parameters: IPCEventsUnsubscribeParams(
                subscriptionId: examples.subscriptionId,
                correlationId: examples.correlationId
            ),
            result: IPCEventsUnsubscribeResult(subscriptionId: examples.subscriptionId),
            semantics: .applied,
            responseDelivery: .single
        )
    }

    private static func eventMutation<Parameters, Result>(
        name: String,
        description: String,
        parameters: Parameters,
        result: Result,
        semantics: IPCResultSemantics,
        responseDelivery: IPCMethodResponseDelivery
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
            responseDelivery: responseDelivery
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
