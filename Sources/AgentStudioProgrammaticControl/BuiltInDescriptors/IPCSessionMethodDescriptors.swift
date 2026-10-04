import Foundation

/// Provider lifecycle events and the retained session read. Pane messages
/// and asks have their own typed descriptors and service.
package struct IPCSessionMethodDescriptors: Sendable {
    package let sessionEvent: IPCMethodDescriptor<IPCSessionEventParams, IPCSessionEventResult>
    package let sessionQuery: IPCMethodDescriptor<IPCSessionQueryParams, IPCSessionQueryResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        sessionEvent = try Self.sessionEventEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        sessionQuery = try Self.sessionQueryEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        sessionEvent = try Self.sessionEventEntry.typedDescriptor(in: representations)
        sessionQuery = try Self.sessionQueryEntry.typedDescriptor(in: representations)
    }

    static let sessionEventEntry = IPCBuiltInMethodEntry<IPCSessionEventParams, IPCSessionEventResult>(
        name: "session.event",
        summary:
            "Project one provider lifecycle event into Sessions for the target pane. Permission events may set permissionHandling to blockingAsk when an ask supplies attention; absent or reportOnly opens a provider prompt.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Project a qualified provider session start",
                        parameters: IPCSessionEventParams(
                            handle: "self",
                            provider: IPCSessionProviderIdentity(
                                identifier: "example-agent",
                                version: "1.0.0",
                                mode: "interactive"
                            ),
                            event: IPCSessionEventIdentity(
                                name: .sessionStart,
                                conversationId: "conversation-1",
                                turnId: nil,
                                requestId: nil,
                                toolId: nil,
                                subagentId: nil,
                                occurrenceId: examples.subscriptionId
                            ),
                            correlationId: examples.correlationId
                        ),
                        result: IPCSessionEventResult(
                            paneId: examples.paneId,
                            disposition: .admitted,
                            correlationId: examples.correlationId
                        )
                    )
                ],
                exposure: .allChannels,
                requiredPrivileges: [.sessionReportWrite],
                dataScope: .sessionReport,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .sessionsIngest,
                principalAvailability: .authenticated,
                resultSemantics: .accepted,
                documentedErrors: Self.sessionErrors,
                isMutating: true,
                correlationPolicy: .required,
                offlineEligibility: .never,
                agentEligibility: entryEligibility
            )
        })

    static let sessionQueryEntry = IPCBuiltInMethodEntry<IPCSessionQueryParams, IPCSessionQueryResult>(
        name: "session.query", summary: "Read the target pane's current status-engine session summary.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Read one pane's current session state",
                        parameters: IPCSessionQueryParams(handle: "self"),
                        result: IPCSessionQueryResult(
                            paneId: examples.paneId, sourceHealth: .live,
                            session: IPCPaneSessionSummary(
                                id: examples.commandId, provider: "claude-code", conversationId: "example-session",
                                bindingGeneration: examples.correlationId, status: .needsYou(reason: .approval),
                                providerPrompts: [], omittedPromptCount: 0))
                    )
                ],
                exposure: .allChannels,
                requiredPrivileges: [.sessionStateRead],
                dataScope: .sessionState,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .sessionsIngest,
                principalAvailability: .authenticated,
                resultSemantics: .applied,
                documentedErrors: Self.sessionErrors,
                isMutating: false,
                correlationPolicy: .notAccepted,
                agentEligibility: entryEligibility
            )
        })

    private static var sessionErrors: [IPCMethodErrorCase] {
        [
            IPCBuiltInDescriptorSupport.invalidParams,
            IPCBuiltInDescriptorSupport.targetNotFound,
            IPCBuiltInDescriptorSupport.unavailable,
            .init(
                reason: IPCSessionFailureReason.bindingRequired,
                description: "The pane has no active conversation binding for a deliberate report."
            ),
            .init(
                reason: IPCSessionFailureReason.correlationConflict,
                description: "The correlation identifier was reused for a different request."
            ),
        ]
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: sessionEvent),
                IPCMethodDescriptorRepresentations(typedDescriptor: sessionQuery),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
