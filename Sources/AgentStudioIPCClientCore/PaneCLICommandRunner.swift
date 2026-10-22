import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation
import Synchronization

/// Parses at the CLI boundary, then calls only the selected compiled recipes.
/// Persistence stays in CLIStore; parameter/result admission stays in descriptors.
struct PaneCLICommandRunner: Sendable {
    let props: AgentStudioIPCClientCommandLineRunner.Props
    let global: IPCClientGlobalArguments
    let deadline: CallDeadline
    let totalDeadline: CallDeadline

    func run(_ intent: PaneCLIIntent) throws {
        do {
            try runCommand(intent)
        } catch {
            switch intent {
            case .title, .line: break
            case .notify, .ask, .withdraw, .answers, .pane:
                if let failure = error as? IPCDescriptorClientFailure,
                    failure.disposition == .authenticationRejected
                {
                    reportCredentialRefusal(tokenOutcome: .rejected)
                } else if global.configuration.authToken == nil,
                    let failure = error as? IPCDescriptorRemoteFailure, failure.code == -32_001
                {
                    reportCredentialRefusal(tokenOutcome: .absent)
                }
            }
            throw error
        }
    }

    private func reportCredentialRefusal(tokenOutcome: IPCSessionTokenOutcome) {
        guard !PaneSessionReportingPolicy.isBackgroundSession(environment: props.environment),
            deadline.remainingBudget > .zero,
            let claim = ProviderHookStatusReporting.paneClaim(environment: props.environment)
        else { return }
        // Report only the refusal through the existing status client. The
        // protected verb retains its original failure and never receives a claim.
        try? ProviderHookDelivery.liveIPC(exampleIdentifierProvider: props.identifierGenerator).reportStatus(
            .init(
                paneClaim: claim, tokenOutcome: tokenOutcome, report: .refusal(reason: .credentialNotRecognized),
                correlationId: props.identifierGenerator()),
            global.configuration.withAuthToken(nil), deadline)
    }

    private func runCommand(_ intent: PaneCLIIntent) throws {
        let writer = writerClaim
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: props.identifierGenerator()))
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: global.methodArguments, authenticated: global.configuration.authToken != nil, inputs: inputs)
        let cleanup = CLIStoreCleanupHandler(
            environment: props.environment, now: props.now, migrationLockWaitBudget: { totalDeadline.remainingBudget })
        let completionMark = Mutex<IPCCLIStoreReadThrough?>(nil)
        defer { cleanup.handle(readThrough: completionMark.withLock { $0 }) }
        let client = AgentStudioIPCClient(
            configuration: global.configuration, descriptors: descriptors, deadline: deadline,
            onCallCompletion: { mark in completionMark.withLock { $0 = mark } })
        let correlationID = props.identifierGenerator()
        switch intent {
        case .title, .line:
            try orderedWriteWithFallback(
                intent, writer: writer, descriptors: descriptors, client: client, correlationID: correlationID)
        case .notify(let draft):
            let parameters = IPCPaneMessageSendParams(
                handle: "self", messageId: props.identifierGenerator(), writer: writer,
                sourceOccurredAt: draft.createdAt, importance: draft.importance,
                body: draft.body, actions: draft.actions, shape: .notice, correlationId: correlationID)
            let request = try invocation("pane.message.send", parameters: parameters, descriptors: descriptors)
            do { try write(try result(client.call(request))) } catch let failure as IPCDescriptorClientFailure
                where failure.permitsOfflineQueue
            {
                let handler = PaneNotificationOfflineHandler(
                    environment: props.environment, now: { draft.createdAt },
                    migrationLockWaitBudget: { totalDeadline.remainingBudget })
                switch try handler.handleUnreachableApp(
                    invocation: request, requestLine: { try client.requestFrame(request) })
                {
                case .queued(let reply):
                    props.standardOutputSink("\(reply) (notSent(\(String(describing: failure.reason))))")
                case .notQueued: throw failure
                }
            }
        case .ask(let draft):
            if let timeout = draft.timeout {
                let parameters = IPCPaneMessageAskParams(
                    handle: "self", messageId: props.identifierGenerator(), writer: writer,
                    sourceOccurredAt: draft.message.createdAt,
                    importance: draft.message.importance,
                    body: draft.message.body, actions: draft.message.actions,
                    shape: .ask(
                        reason: draft.reason, form: draft.form,
                        waiting: .blocking(deadline: draft.message.createdAt.addingTimeInterval(timeout))),
                    correlationId: correlationID)
                try write(
                    try result(
                        client.call(invocation("pane.message.ask", parameters: parameters, descriptors: descriptors))))
            } else {
                let parameters = IPCPaneMessageSendParams(
                    handle: "self", messageId: props.identifierGenerator(), writer: writer,
                    sourceOccurredAt: draft.message.createdAt,
                    importance: draft.message.importance,
                    body: draft.message.body, actions: draft.message.actions,
                    shape: .ask(reason: draft.reason, form: draft.form, waiting: .nonBlocking),
                    correlationId: correlationID)
                try write(
                    try result(
                        client.call(invocation("pane.message.send", parameters: parameters, descriptors: descriptors))))
            }
        case .withdraw(let id):
            let parameters = IPCPaneMessageWithdrawParams(
                handle: "self", messageId: id, writer: writer, correlationId: correlationID)
            try write(
                try result(
                    client.call(invocation("pane.message.withdraw", parameters: parameters, descriptors: descriptors))))
        case .answers:
            try printAnswers(writer: writer, descriptors: descriptors, client: client, correlationID: correlationID)
        case .pane:
            try write(
                try result(
                    client.call(
                        invocation(
                            "pane.context.get", parameters: IPCPaneContextGetParams(handle: "self", page: .first),
                            descriptors: descriptors))))
        }
    }

    private func printAnswers(
        writer: IPCPaneWriterClaim?, descriptors: [IPCAnyMethodDescriptor],
        client: AgentStudioIPCClient, correlationID: UUID
    ) throws {
        let store = openStore()
        defer { try? store?.close() }
        let key = try? stateKey(.answerPosition, writer: writer)
        var position = UInt64(key.flatMap { try? store?.answerPosition($0) } ?? 0)
        let first = try invocation(
            "pane.message.changes",
            parameters: IPCPaneMessageChangesParams(
                handle: "self", writer: writer, after: position, correlationId: correlationID),
            descriptors: descriptors)
        var entries: [IPCPaneMessageChangeEntry] = []
        var didReceivePage = false
        var interruptedBy: (any Error)?
        let complete: IPCPaneMessageChangesResult
        do {
            complete = try client.withAuthenticatedExchange(first: first) { exchange in
                var request = first
                while true {
                    let response = try result(exchange.call(request))
                    let page = try JSONDecoder().decode(IPCPaneMessageChangesResult.self, from: response)
                    entries.append(contentsOf: page.entries)
                    position = page.nextPosition
                    didReceivePage = true
                    guard page.more else {
                        return IPCPaneMessageChangesResult(entries: entries, nextPosition: position, more: false)
                    }
                    request = try invocation(
                        "pane.message.changes",
                        parameters: IPCPaneMessageChangesParams(
                            handle: "self", writer: writer, after: position,
                            correlationId: props.identifierGenerator()),
                        descriptors: descriptors)
                }
            }
        } catch {
            guard didReceivePage else { throw error }
            interruptedBy = error
            complete = IPCPaneMessageChangesResult(entries: entries, nextPosition: position, more: true)
        }
        try write(JSONEncoder().encode(complete))
        if let key, let store, let next = Int64(exactly: complete.nextPosition) {
            do { try store.advanceAnswerPosition(key, to: next) } catch {
                CLIDiagnostics.record(.storeUnavailable)
            }
        }
        if let interruptedBy { throw interruptedBy }
    }

    private func orderedWriteWithFallback(
        _ intent: PaneCLIIntent, writer: IPCPaneWriterClaim?, descriptors: [IPCAnyMethodDescriptor],
        client: AgentStudioIPCClient, correlationID: UUID
    ) throws {
        guard let store = openStore(allowOrderingDiscovery: true) else {
            CLIDiagnostics.recordHook(
                IPCAgentConnectionRefusalReason.orderingStoreUnavailable.rawValue, environment: props.environment)
            throw PaneCLICommandFailure.orderingStoreUnavailable
        }
        defer { try? store.close() }
        let stream: IPCPaneWriteStream
        let kind: CLIStateKind
        switch intent {
        case .title:
            stream = .title
            kind = .titleWriteNumber
        case .line:
            stream = .line
            kind = .lineWriteNumber
        default: throw PaneCLIIntent.invalid()
        }
        let paneKey = try stateKey(kind, writer: nil)
        let primaryKey = try stateKey(kind, writer: writer)
        let hasPrimary = global.configuration.authToken != nil
        let keys = hasPrimary && writer != nil ? [primaryKey, paneKey] : [paneKey]
        let reservations: [CLIWriteReservation]
        do { reservations = try store.reserveWrites(keys) } catch {
            throw PaneCLICommandFailure.orderingStoreUnavailable
        }
        if hasPrimary {
            do {
                try orderedWrite(
                    PaneOrderedWriteRequest(
                        intent: intent,
                        attribution: PaneWriteAttribution(writer: writer, paneClaim: nil, tokenOutcome: nil),
                        stream: stream, key: primaryKey, reservation: reservations[0], correlationID: correlationID),
                    store: store, descriptors: descriptors, client: client)
                return
            } catch let failure as IPCDescriptorRemoteFailure
                where writer != nil && failure.documentedReason == IPCSessionFailureReason.bindingRequired
            {
                guard let reservation = reservations.last else {
                    throw PaneCLICommandFailure.orderingStoreUnavailable
                }
                try orderedWrite(
                    PaneOrderedWriteRequest(
                        intent: intent,
                        attribution: PaneWriteAttribution(writer: nil, paneClaim: nil, tokenOutcome: nil),
                        stream: stream, key: paneKey, reservation: reservation, correlationID: correlationID),
                    store: store, descriptors: descriptors, client: client)
                return
            } catch let failure as IPCDescriptorClientFailure where failure.disposition == .authenticationRejected {
                // Login rejection permits the unauthenticated fallback. Both writer slots were
                // reserved before login, so this older intent cannot be renumbered.
            }
        }
        guard let claim = ProviderHookStatusReporting.paneClaim(environment: props.environment),
            let reservation = reservations.last
        else { throw PaneCLICommandFailure.orderingStoreUnavailable }
        let paneClient = AgentStudioIPCClient(
            configuration: global.configuration.withAuthToken(nil), descriptors: descriptors, deadline: deadline)
        try orderedWrite(
            PaneOrderedWriteRequest(
                intent: intent,
                attribution: PaneWriteAttribution(
                    writer: nil, paneClaim: claim, tokenOutcome: hasPrimary ? .rejected : .absent),
                stream: stream, key: paneKey, reservation: reservation, correlationID: correlationID),
            store: store, descriptors: descriptors, client: paneClient)
    }

    private func orderedWrite(
        _ request: PaneOrderedWriteRequest, store: CLIStore,
        descriptors: [IPCAnyMethodDescriptor], client: AgentStudioIPCClient
    ) throws {
        let intent = request.intent
        let attribution = request.attribution
        let key = request.key
        let reservation = request.reservation
        let correlationID = request.correlationID
        let first: IPCDescriptorInvocation
        switch reservation {
        case .claim(let claimID, _):
            first = try invocation(
                "pane.writer.claimEpoch",
                parameters: IPCPaneWriterClaimEpochParams(
                    handle: "self", writer: attribution.writer, paneClaim: attribution.paneClaim,
                    stream: request.stream, claimId: claimID,
                    correlationId: props.identifierGenerator()),
                descriptors: descriptors)
        case .allocated(let number):
            first = try orderedInvocation(
                intent, attribution: attribution, number: number,
                descriptors: descriptors, correlationID: correlationID)
        }
        try client.withAuthenticatedExchange(first: first) { exchange in
            let number: CLIAllocatedWriteNumber
            let response: Data
            switch reservation {
            case .claim(let claimID, let counter):
                let claimed = try JSONDecoder().decode(IPCPaneEpochClaimResult.self, from: result(exchange.call(first)))
                let epoch: UInt64
                switch claimed {
                case .claimed(let value): epoch = value
                }
                guard let storedEpoch = Int64(exactly: epoch) else {
                    throw PaneCLICommandFailure.orderingStoreUnavailable
                }
                do { number = try store.acceptClaim(key, claimID: claimID, epoch: storedEpoch, counter: counter) } catch
                {
                    throw PaneCLICommandFailure.orderingStoreUnavailable
                }
                let write = try orderedInvocation(
                    intent, attribution: attribution, number: number,
                    descriptors: descriptors, correlationID: correlationID)
                response = try result(exchange.call(write))
            case .allocated(let allocated):
                number = allocated
                response = try result(exchange.call(first))
            }
            let outcome = try JSONDecoder().decode(IPCPaneOrderedWriteResult.self, from: response)
            if case .stale(let reason) = outcome {
                do {
                    switch reason {
                    case .epochSuperseded: try store.clearSupersededEpoch(key, epoch: number.epoch)
                    case .lastAccepted(let accepted):
                        guard let epoch = Int64(exactly: accepted.epoch), let counter = Int64(exactly: accepted.counter)
                        else {
                            throw PaneCLICommandFailure.orderingStoreUnavailable
                        }
                        try store.retainLastAccepted(key, epoch: epoch, counter: counter)
                    case .writerReplaced: break
                    }
                } catch { CLIDiagnostics.record(.storeUnavailable) }
                throw PaneCLICommandFailure.stale(reason)
            }
            try write(response)
        }
    }

    private func orderedInvocation(
        _ intent: PaneCLIIntent, attribution: PaneWriteAttribution, number: CLIAllocatedWriteNumber,
        descriptors: [IPCAnyMethodDescriptor], correlationID: UUID
    ) throws -> IPCDescriptorInvocation {
        let writer = attribution.writer
        let paneClaim = attribution.paneClaim
        let tokenOutcome = attribution.tokenOutcome
        let wireNumber = IPCPaneWriteNumber(epoch: UInt64(number.epoch), counter: UInt64(number.counter))
        switch intent {
        case .title(let text):
            return try invocation(
                "pane.title.set",
                parameters: IPCPaneTitleSetParams(
                    handle: "self", writer: writer, paneClaim: paneClaim, tokenOutcome: tokenOutcome, text: text,
                    writeNumber: wireNumber, correlationId: correlationID),
                descriptors: descriptors)
        case .line(let line):
            return try invocation(
                "pane.line.set",
                parameters: IPCPaneLineSetParams(
                    handle: "self", writer: writer, paneClaim: paneClaim, tokenOutcome: tokenOutcome, line: line,
                    writeNumber: wireNumber, correlationId: correlationID),
                descriptors: descriptors)
        default: throw PaneCLIIntent.invalid()
        }
    }

    private var writerClaim: IPCPaneWriterClaim? {
        if let id = props.environment["CLAUDE_CODE_SESSION_ID"], !id.isEmpty {
            return .init(provider: "claude-code", conversationId: id)
        }
        if let id = props.environment["CODEX_THREAD_ID"], !id.isEmpty {
            return .init(provider: "codex", conversationId: id)
        }
        if let id = props.environment["CURSOR_CONVERSATION_ID"], !id.isEmpty {
            return .init(provider: "cursor", conversationId: id)
        }
        return nil
    }

    private func stateKey(_ kind: CLIStateKind, writer: IPCPaneWriterClaim?) throws -> CLIStateKey {
        CLIStateKey(
            kind: kind, paneID: try paneID(), sessionRef: writer.map { "\($0.provider):\($0.conversationId)" } ?? "pane"
        )
    }

    private func paneID() throws -> UUID {
        guard let text = props.environment["AGENTSTUDIO_PANE_ID"], let id = UUID(uuidString: text) else {
            throw PaneCLICommandFailure.orderingStoreUnavailable
        }
        return id
    }

    private func openStore(allowOrderingDiscovery: Bool = false) -> CLIStore? {
        let hasExplicitStore = props.environment["AGENTSTUDIO_CLI_STORE"].map { !$0.isEmpty } ?? false
        guard allowOrderingDiscovery || hasExplicitStore,
            let location = CLIOrderingStoreLocation.resolve(
                environment: props.environment, socketPath: global.configuration.socketPath)
        else { return nil }
        switch CLIStore.openWriter(
            url: location.url, channel: location.channel, migrationLockWaitBudget: { deadline.remainingBudget })
        {
        case .success(let writer): return writer
        case .failure(let failure):
            CLIDiagnostics.record(.init(cleanupFailure: failure))
            return nil
        }
    }

    private func invocation(_ name: String, parameters: some Encodable, descriptors: [IPCAnyMethodDescriptor]) throws
        -> IPCDescriptorInvocation
    {
        guard let descriptor = descriptors.first(where: { $0.metadata.name == name }) else {
            throw PaneCLIIntent.invalid()
        }
        return try IPCDescriptorInvocation(
            descriptor: descriptor,
            normalizedParameters: descriptor.normalizeParameters(JSONEncoder().encode(parameters)),
            presentation: .tooling)
    }

    private func result(_ result: IPCDescriptorClientCallResult) throws -> Data {
        switch result {
        case .success(let response): return response.normalizedResult.data
        case .remoteFailure(let failure): throw failure
        }
    }

    private func write(_ bytes: Data) throws {
        guard let text = String(data: bytes, encoding: .utf8) else { throw PaneCLIIntent.invalid() }
        props.standardOutputSink(text)
    }
}

enum PaneCLICommandFailure: Error {
    case backgroundSession
    case orderingStoreUnavailable
    case stale(IPCPaneWriteStaleness)

    var description: String {
        switch self {
        case .backgroundSession: "background session: not attached to a pane"
        case .orderingStoreUnavailable: "unavailable(orderingStoreUnavailable)"
        case .stale(let reason):
            switch reason {
            case .lastAccepted: "stale(lastAccepted)"
            case .epochSuperseded: "stale(epochSuperseded)"
            case .writerReplaced: "stale(writerReplaced)"
            }
        }
    }
}

/// Who an ordered title or Agent Line write is attributed to: a session writer with a
/// recognized token, or the pane writer on a pane claim after a refused or absent token.
private struct PaneWriteAttribution {
    let writer: IPCPaneWriterClaim?
    let paneClaim: IPCPaneClaim?
    let tokenOutcome: IPCSessionTokenOutcome?
}

/// One ordered write: its intent, attribution, stream, store key, the ordering slot
/// reserved before any I/O, and its correlation id.
private struct PaneOrderedWriteRequest {
    let intent: PaneCLIIntent
    let attribution: PaneWriteAttribution
    let stream: IPCPaneWriteStream
    let key: CLIStateKey
    let reservation: CLIWriteReservation
    let correlationID: UUID
}
