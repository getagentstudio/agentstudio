import Foundation

package struct IPCPaneContextMethodDescriptors: Sendable {
    package let messageSend: IPCMethodDescriptor<IPCPaneMessageSendParams, IPCPaneMessageSendResult>
    package let messageAsk: IPCMethodDescriptor<IPCPaneMessageAskParams, IPCPaneAskOutcome>
    package let messageWithdraw: IPCMethodDescriptor<IPCPaneMessageWithdrawParams, IPCPaneMessageWithdrawResult>
    package let messageChanges: IPCMethodDescriptor<IPCPaneMessageChangesParams, IPCPaneMessageChangesResult>
    package let lineSet: IPCMethodDescriptor<IPCPaneLineSetParams, IPCPaneOrderedWriteResult>
    package let titleSet: IPCMethodDescriptor<IPCPaneTitleSetParams, IPCPaneOrderedWriteResult>
    package let writerClaimEpoch: IPCMethodDescriptor<IPCPaneWriterClaimEpochParams, IPCPaneEpochClaimResult>
    package let contextGet: IPCMethodDescriptor<IPCPaneContextGetParams, IPCPaneContextGetResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        messageSend = try Self.messageSendEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        messageAsk = try Self.messageAskEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        messageWithdraw = try Self.messageWithdrawEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        messageChanges = try Self.messageChangesEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        lineSet = try Self.lineSetEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        titleSet = try Self.titleSetEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        writerClaimEpoch = try Self.writerClaimEpochEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        contextGet = try Self.contextGetEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        messageSend = try Self.messageSendEntry.typedDescriptor(in: representations)
        messageAsk = try Self.messageAskEntry.typedDescriptor(in: representations)
        messageWithdraw = try Self.messageWithdrawEntry.typedDescriptor(in: representations)
        messageChanges = try Self.messageChangesEntry.typedDescriptor(in: representations)
        lineSet = try Self.lineSetEntry.typedDescriptor(in: representations)
        titleSet = try Self.titleSetEntry.typedDescriptor(in: representations)
        writerClaimEpoch = try Self.writerClaimEpochEntry.typedDescriptor(in: representations)
        contextGet = try Self.contextGetEntry.typedDescriptor(in: representations)
    }

    static let messageSendEntry = IPCBuiltInMethodEntry<IPCPaneMessageSendParams, IPCPaneMessageSendResult>(
        name: "pane.message.send",
        summary:
            "Post a notice or non-blocking ask. Body <= 4 KiB UTF-8, why <= 1 KiB, choices <= 12 with labels <= 200 bytes, form <= 16 properties and 8 KiB encoded, actions <= 4 with each <= 1 KiB encoded. At most 32 open asks and 200 unread notices per pane.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.message.send call",
                        parameters: IPCPaneMessageSendParams(
                            handle: "self", messageId: examples.commandId, importance: .info,
                            body: "The migration finished", actions: [], shape: .notice,
                            correlationId: examples.correlationId), result: .created(id: examples.commandId))
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextWrite],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: Self.errors,
                isMutating: true,
                correlationPolicy: .required,
                offlineEligibility: .noticeOnly,
                agentEligibility: entryEligibility
            )
        })

    static let messageAskEntry = IPCBuiltInMethodEntry<IPCPaneMessageAskParams, IPCPaneAskOutcome>(
        name: "pane.message.ask",
        summary:
            "Wait beside the connection reader for one blocking ask. The send limits apply; EOF withdraws, stopping makes stale, and the first committed settlement wins.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.message.ask call",
                        parameters: IPCPaneMessageAskParams(
                            handle: "self", messageId: examples.commandId,
                            writer: IPCPaneWriterClaim(provider: "claude-code", conversationId: "conversation-1"),
                            importance: .attention, body: "Continue?", actions: [],
                            shape: .ask(
                                reason: .approval, form: .freeText(placeholder: nil),
                                waiting: .blocking(deadline: Date(timeIntervalSinceReferenceDate: 60))),
                            correlationId: examples.correlationId), result: .expired)
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextWrite],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: Self.errors,
                isMutating: true,
                correlationPolicy: .required,
                agentEligibility: entryEligibility
            )
        })

    static let messageWithdrawEntry = IPCBuiltInMethodEntry<IPCPaneMessageWithdrawParams, IPCPaneMessageWithdrawResult>(
        name: "pane.message.withdraw",
        summary:
            "Withdraw one message owned by this pane writer. A settled ask returns its committed terminal state; a read notice cannot be withdrawn.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.message.withdraw call",
                        parameters: IPCPaneMessageWithdrawParams(
                            handle: "self", messageId: examples.commandId, correlationId: examples.correlationId),
                        result: .withdrawn)
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextWrite],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: Self.errors,
                isMutating: true,
                correlationPolicy: .required,
                agentEligibility: entryEligibility
            )
        })

    static let messageChangesEntry = IPCBuiltInMethodEntry<IPCPaneMessageChangesParams, IPCPaneMessageChangesResult>(
        name: "pane.message.changes",
        summary:
            "Read up to 200 changes or 256 KiB and confirm receipt through after. Positions are exact non-negative JSON safe integers.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.message.changes call",
                        parameters: IPCPaneMessageChangesParams(
                            handle: "self", after: 0, correlationId: examples.correlationId),
                        result: IPCPaneMessageChangesResult(entries: [], nextPosition: 0, more: false))
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextWrite],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: Self.errors,
                isMutating: true,
                correlationPolicy: .required,
                agentEligibility: entryEligibility
            )
        })

    static let lineSetEntry = IPCBuiltInMethodEntry<IPCPaneLineSetParams, IPCPaneOrderedWriteResult>(
        name: "pane.line.set",
        summary:
            "Set or clear the ordered Agent Line. Summary/work <= 200 UTF-8 bytes, detail <= 2 KiB, steps <= 10000, refs <= 8 with each <= 512 encoded bytes.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.line.set call",
                        parameters: IPCPaneLineSetParams(
                            handle: "self", line: nil, writeNumber: IPCPaneWriteNumber(epoch: 1, counter: 1),
                            correlationId: examples.correlationId), result: .applied)
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextWrite],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: Self.errors,
                isMutating: true,
                correlationPolicy: .required,
                agentEligibility: entryEligibility
            )
        })

    static let titleSetEntry = IPCBuiltInMethodEntry<IPCPaneTitleSetParams, IPCPaneOrderedWriteResult>(
        name: "pane.title.set",
        summary:
            "Set or clear the ordered Agent Title, at most 256 UTF-8 bytes. Stale payloads are final and must never be retried under a new number.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.title.set call",
                        parameters: IPCPaneTitleSetParams(
                            handle: "self", text: "Migration complete",
                            writeNumber: IPCPaneWriteNumber(epoch: 1, counter: 1), correlationId: examples.correlationId
                        ),
                        result: .applied)
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextWrite],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: Self.errors,
                isMutating: true,
                correlationPolicy: .required,
                agentEligibility: entryEligibility
            )
        })

    static let writerClaimEpochEntry = IPCBuiltInMethodEntry<IPCPaneWriterClaimEpochParams, IPCPaneEpochClaimResult>(
        name: "pane.writer.claimEpoch",
        summary:
            "Idempotently claim the current writer stream epoch by claimId. A claim changes no displayed value.",
        modelCalls: [], correlationPolicy: .required, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.writer.claimEpoch call",
                        parameters: IPCPaneWriterClaimEpochParams(
                            handle: "self", stream: .title, claimId: examples.commandId,
                            correlationId: examples.correlationId), result: .claimed(epoch: 1))
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextWrite],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .discriminated,
                documentedErrors: Self.errors,
                isMutating: true,
                correlationPolicy: .required,
                agentEligibility: entryEligibility
            )
        })

    static let contextGetEntry = IPCBuiltInMethodEntry<IPCPaneContextGetParams, IPCPaneContextGetResult>(
        name: "pane.context.get",
        summary:
            "Read the credential pane and its current drawers. One composed 1 MiB logical budget; truncation and more pages reach every live message. Encoded replies also fit the transport and output-queue bounds.",
        modelCalls: [], correlationPolicy: .notAccepted, agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Representative pane.context.get call",
                        parameters: IPCPaneContextGetParams(handle: "self", page: .first),
                        result: IPCPaneContextGetResult(
                            paneId: examples.paneId, revision: 0, messages: [], drawerMessages: [], links: .unknown,
                            pullRequests: .notApplicable))
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextRead],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .paneContextService,
                principalAvailability: .authenticated,
                resultSemantics: .applied,
                documentedErrors: Self.errors,
                isMutating: false,
                correlationPolicy: .notAccepted,
                agentEligibility: entryEligibility
            )
        })

    private static var errors: [IPCMethodErrorCase] {
        [
            "unauthorized", "notOwnPane", "bindingRequired", "conflict", "paneGone", "notSender", "noticeAlreadyRead",
            "tooLarge",
            "invalidField", "stale", "sourceNotInView", "unavailable", "internalError", "connectionBusy",
        ].map {
            IPCMethodErrorCase(
                reason: $0,
                description: $0 == "notOwnPane"
                    ? "Pane agents must use handle: self; another handle is refused without effects."
                    : "Typed pane context refusal: \($0).")
        }
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            try [
                IPCMethodDescriptorRepresentations(typedDescriptor: messageSend),
                IPCMethodDescriptorRepresentations(typedDescriptor: messageAsk),
                IPCMethodDescriptorRepresentations(typedDescriptor: messageWithdraw),
                IPCMethodDescriptorRepresentations(typedDescriptor: messageChanges),
                IPCMethodDescriptorRepresentations(typedDescriptor: lineSet),
                IPCMethodDescriptorRepresentations(typedDescriptor: titleSet),
                IPCMethodDescriptorRepresentations(typedDescriptor: writerClaimEpoch),
                IPCMethodDescriptorRepresentations(typedDescriptor: contextGet),
            ]
        }
    }
}
