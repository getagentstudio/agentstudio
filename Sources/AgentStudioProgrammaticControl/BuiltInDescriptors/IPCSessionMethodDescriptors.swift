import Foundation

/// Live agent reports, messages, provider lifecycle events and one session
/// read. The deliberate verbs project to scalar model calls; the hook-facing
/// event method stays tooling-only because no model types provider identity.
package struct IPCSessionMethodDescriptors: Sendable {
    package let sessionReport: IPCMethodDescriptor<IPCSessionReportParams, IPCSessionReportResult>
    package let sessionMessage: IPCMethodDescriptor<IPCSessionMessageParams, IPCSessionMessageResult>
    package let sessionEvent: IPCMethodDescriptor<IPCSessionEventParams, IPCSessionEventResult>
    package let sessionQuery: IPCMethodDescriptor<IPCSessionQueryParams, IPCSessionQueryResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        sessionReport = try Self.sessionReportEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        sessionMessage = try Self.sessionMessageEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        sessionEvent = try Self.sessionEventEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        sessionQuery = try Self.sessionQueryEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        sessionReport = try Self.sessionReportEntry.typedDescriptor(in: representations)
        sessionMessage = try Self.sessionMessageEntry.typedDescriptor(in: representations)
        sessionEvent = try Self.sessionEventEntry.typedDescriptor(in: representations)
        sessionQuery = try Self.sessionQueryEntry.typedDescriptor(in: representations)
    }

    static let sessionReportEntry = IPCBuiltInMethodEntry<IPCSessionReportParams, IPCSessionReportResult>(
        name: "session.report", summary: "Record one deliberate agent report for the target pane.",
        modelCalls: [
            .init(
                variant: .needsYou,
                selectors: [.init(parameterField: "kind", equals: IPCSessionReportKind.needsYou.rawValue)],
                scalarArguments: [
                    .init(
                        name: "explanation",
                        parameterField: "explanation",
                        description: "Short reason the user is needed",
                        isRequired: false
                    )
                ],
                successReply: "needs-you recorded",
                queuedReply: "needs-you queued"
            ),
            .init(
                variant: .needsYouClear,
                selectors: [.init(parameterField: "kind", equals: IPCSessionReportKind.clearNeedsYou.rawValue)],
                scalarArguments: [],
                successReply: "needs-you cleared",
                queuedReply: nil
            ),
            .init(
                variant: .done,
                selectors: [.init(parameterField: "kind", equals: IPCSessionReportKind.done.rawValue)],
                scalarArguments: [],
                successReply: "done recorded",
                queuedReply: "done queued"
            ),
        ],
        correlationPolicy: .required,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, entryModelCalls, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Report that the agent needs the user",
                        parameters: IPCSessionReportParams(
                            handle: "self",
                            kind: .needsYou,
                            explanation: "waiting on approval",
                            correlationId: examples.correlationId
                        ),
                        result: IPCSessionReportResult(
                            paneId: examples.paneId,
                            state: .needsYou,
                            origin: .agentReported,
                            requestId: "attention-1",
                            correlationId: examples.correlationId
                        )
                    ),
                    .init(
                        description: "Report that the agent finished its work",
                        parameters: IPCSessionReportParams(
                            handle: "self",
                            kind: .done,
                            explanation: nil,
                            correlationId: examples.correlationId
                        ),
                        result: IPCSessionReportResult(
                            paneId: examples.paneId,
                            state: .done,
                            origin: .agentReported,
                            requestId: nil,
                            correlationId: examples.correlationId
                        )
                    ),
                ],
                exposure: .allChannels,
                requiredPrivileges: [.sessionReportWrite],
                dataScope: .sessionReport,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .sessionsIngest,
                principalAvailability: .authenticated,
                resultSemantics: .applied,
                documentedErrors: Self.sessionErrors,
                isMutating: true,
                correlationPolicy: .required,
                offlineEligibility: .modelCallVariants([.needsYou, .done]),
                modelCalls: entryModelCalls,
                agentEligibility: entryEligibility
            )
        })

    static let sessionMessageEntry = IPCBuiltInMethodEntry<IPCSessionMessageParams, IPCSessionMessageResult>(
        name: "session.message", summary: "Record one exact agent message for the target pane.",
        modelCalls: [
            .init(
                variant: .message,
                selectors: [],
                scalarArguments: [
                    .init(
                        name: "text",
                        parameterField: "text",
                        description: "Exact message text",
                        isRequired: true
                    )
                ],
                successReply: "message sent",
                queuedReply: "message queued"
            )
        ],
        correlationPolicy: .required,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, entryModelCalls, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Send one message from a bound agent",
                        parameters: IPCSessionMessageParams(
                            handle: "self",
                            text: "the migration finished",
                            correlationId: examples.correlationId
                        ),
                        result: IPCSessionMessageResult(
                            paneId: examples.paneId,
                            occurrenceId: examples.commandId,
                            attributed: true,
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
                resultSemantics: .applied,
                documentedErrors: Self.sessionErrors,
                isMutating: true,
                correlationPolicy: .required,
                offlineEligibility: .modelCallVariants([.message]),
                modelCalls: entryModelCalls,
                agentEligibility: entryEligibility
            )
        })

    static let sessionEventEntry = IPCBuiltInMethodEntry<IPCSessionEventParams, IPCSessionEventResult>(
        name: "session.event", summary: "Project one provider lifecycle event into Sessions for the target pane.",
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
        name: "session.query", summary: "Read the target pane's session state and newest retained messages.",
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
                            paneId: examples.paneId,
                            state: .needsYou,
                            origin: .agentReported,
                            needsYou: IPCSessionAttentionProjection(
                                requestId: "attention-1",
                                explanation: "waiting on approval"
                            ),
                            messages: [
                                IPCSessionMessageProjection(
                                    occurrenceId: examples.commandId,
                                    text: "the migration finished",
                                    seen: false,
                                    receivedAt: Date(timeIntervalSinceReferenceDate: 0)
                                )
                            ],
                            sourceHealth: .live
                        )
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
                IPCMethodDescriptorRepresentations(typedDescriptor: sessionMessage),
                IPCMethodDescriptorRepresentations(typedDescriptor: sessionQuery),
                IPCMethodDescriptorRepresentations(typedDescriptor: sessionReport),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
