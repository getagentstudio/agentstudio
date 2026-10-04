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
            try orderedWrite(
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

    private func orderedWrite(
        _ intent: PaneCLIIntent, writer: IPCPaneWriterClaim?, descriptors: [IPCAnyMethodDescriptor],
        client: AgentStudioIPCClient, correlationID: UUID
    ) throws {
        guard let store = openStore() else { throw PaneCLICommandFailure.orderingStoreUnavailable }
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
        let key = try stateKey(kind, writer: writer)
        let reservation: CLIWriteReservation
        do { reservation = try store.reserveWrite(key) } catch { throw PaneCLICommandFailure.orderingStoreUnavailable }
        let first: IPCDescriptorInvocation
        switch reservation {
        case .claim(let claimID):
            first = try invocation(
                "pane.writer.claimEpoch",
                parameters: IPCPaneWriterClaimEpochParams(
                    handle: "self", writer: writer, stream: stream, claimId: claimID,
                    correlationId: props.identifierGenerator()),
                descriptors: descriptors)
        case .allocated(let number):
            first = try orderedInvocation(
                intent, writer: writer, number: number, descriptors: descriptors, correlationID: correlationID)
        }
        try client.withAuthenticatedExchange(first: first) { exchange in
            let number: CLIAllocatedWriteNumber
            let response: Data
            switch reservation {
            case .claim(let claimID):
                let claimed = try JSONDecoder().decode(IPCPaneEpochClaimResult.self, from: result(exchange.call(first)))
                let epoch: UInt64
                switch claimed {
                case .claimed(let value): epoch = value
                }
                guard let storedEpoch = Int64(exactly: epoch) else {
                    throw PaneCLICommandFailure.orderingStoreUnavailable
                }
                do { number = try store.acceptClaim(key, claimID: claimID, epoch: storedEpoch) } catch {
                    throw PaneCLICommandFailure.orderingStoreUnavailable
                }
                let write = try orderedInvocation(
                    intent, writer: writer, number: number, descriptors: descriptors, correlationID: correlationID)
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
        _ intent: PaneCLIIntent, writer: IPCPaneWriterClaim?, number: CLIAllocatedWriteNumber,
        descriptors: [IPCAnyMethodDescriptor], correlationID: UUID
    ) throws -> IPCDescriptorInvocation {
        let wireNumber = IPCPaneWriteNumber(epoch: UInt64(number.epoch), counter: UInt64(number.counter))
        switch intent {
        case .title(let text):
            return try invocation(
                "pane.title.set",
                parameters: IPCPaneTitleSetParams(
                    handle: "self", writer: writer, text: text, writeNumber: wireNumber, correlationId: correlationID),
                descriptors: descriptors)
        case .line(let line):
            return try invocation(
                "pane.line.set",
                parameters: IPCPaneLineSetParams(
                    handle: "self", writer: writer, line: line, writeNumber: wireNumber, correlationId: correlationID),
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

    private func openStore() -> CLIStore? {
        guard let path = props.environment["AGENTSTUDIO_CLI_STORE"], !path.isEmpty,
            let channel = props.environment["AGENTSTUDIO_CLI_STORE_CHANNEL"].flatMap(CLIStoreChannel.init(rawValue:))
        else { return nil }
        switch CLIStore.openWriter(
            url: URL(fileURLWithPath: path), channel: channel, migrationLockWaitBudget: { deadline.remainingBudget })
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
    case orderingStoreUnavailable
    case stale(IPCPaneWriteStaleness)

    var description: String {
        switch self {
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
