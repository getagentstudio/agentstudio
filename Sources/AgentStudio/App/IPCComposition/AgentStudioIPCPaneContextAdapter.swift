import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation

/// App owns wire-to-domain composition. Credential target admission belongs to
/// AppIPC; binding resolution and all service work stay off MainActor.
struct AgentStudioIPCPaneContextAdapter: AppIPCPaneContextPort {
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let service: PaneContextService
    private let ingestion: SessionsIngestion
    private let maximumEncodedReplyBytes: Int

    /// Test seam; lowers only. Production composition passes no cap.
    init(
        service: PaneContextService, ingestion: SessionsIngestion,
        maximumEncodedReplyBytes: Int = min(
            IPCFramePolicy.maximumResponseFrameBytes, AppPolicies.IPC.maximumQueuedOutputBytes - 1),
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        self.performanceTraceRecorder = performanceTraceRecorder
        self.service = service
        self.ingestion = ingestion
        self.maximumEncodedReplyBytes = min(
            maximumEncodedReplyBytes,
            min(IPCFramePolicy.maximumResponseFrameBytes, AppPolicies.IPC.maximumQueuedOutputBytes - 1))
    }

    func sendMessage(paneId: UUID, params: IPCPaneMessageSendParams) async throws -> IPCPaneMessageSendResult {
        try await sendMessage(paneId: paneId, params: params, commitParticipant: nil)
    }

    @concurrent
    func sendMessage(
        paneId: UUID, params: IPCPaneMessageSendParams, commitParticipant: (any PaneContextCommitParticipant)?
    ) async throws -> IPCPaneMessageSendResult {
        let writer = try await resolveWriter(params.writer, paneId: paneId)
        let shape: PaneMessageSendShape
        switch params.shape {
        case .notice: shape = .notice
        case .ask(let reason, let form, _):
            shape = .ask(
                reason: PaneContextIPCMapping.reason(reason), form: try PaneContextIPCMapping.form(form),
                waiting: .nonBlocking)
        }
        try PaneContextIPCMapping.validateActions(params.actions)
        let result = await service.send(
            PaneMessageSendRequest(
                paneId: PaneId(existingUUID: paneId), messageId: AgentMessageId(existingUUID: params.messageId),
                sender: try writer.sender, sourceOccurredAt: params.sourceOccurredAt,
                importance: PaneContextIPCMapping.importance(params.importance), body: params.body, why: params.why,
                actions: try params.actions.map(PaneContextIPCMapping.action), shape: shape),
            commitParticipant: commitParticipant)
        return try sendResult(result)
    }

    @concurrent
    func askMessage(
        paneId: UUID, params: IPCPaneMessageAskParams,
        connectionEndCause: @escaping @Sendable () -> AppIPCConnectionEndCause
    ) async throws -> IPCPaneAskOutcome {
        let writer = try await resolveWriter(params.writer, paneId: paneId)
        let shape: PaneMessageSendShape
        switch params.shape {
        case .ask(let reason, let form, let waiting):
            switch waiting {
            case .blocking(let deadline):
                shape = .ask(
                    reason: PaneContextIPCMapping.reason(reason), form: try PaneContextIPCMapping.form(form),
                    waiting: .blocking(deadline: deadline))
            }
        }
        try PaneContextIPCMapping.validateActions(params.actions)
        let pane = PaneId(existingUUID: paneId)
        let message = AgentMessageId(existingUUID: params.messageId)
        _ = try sendResult(
            await service.send(
                PaneMessageSendRequest(
                    paneId: pane, messageId: message, sender: try writer.sender,
                    sourceOccurredAt: params.sourceOccurredAt,
                    importance: PaneContextIPCMapping.importance(params.importance), body: params.body, why: params.why,
                    actions: try params.actions.map(PaneContextIPCMapping.action), shape: shape)))
        return try await waitForPaneContextAsk(
            service: service, paneId: pane, messageId: message, connectionEndCause: connectionEndCause)
    }

    @concurrent
    func withdrawMessage(paneId: UUID, params: IPCPaneMessageWithdrawParams) async throws
        -> IPCPaneMessageWithdrawResult
    {
        let writer = try await resolveWriter(params.writer, paneId: paneId)
        switch await service.withdraw(
            messageId: AgentMessageId(existingUUID: params.messageId), paneId: PaneId(existingUUID: paneId),
            writer: try writer.sender)
        {
        case .withdrawn: return .withdrawn
        case .alreadySettled(let state): return .alreadySettled(state: PaneContextIPCMapping.terminal(state))
        case .notFound: return .notFound
        case .refused(let reason): throw PaneContextIPCMapping.refusal(reason)
        case .unavailable: throw AppIPCPaneContextError(reason: .unavailable)
        }
    }

    @concurrent
    func readChanges(paneId: UUID, params: IPCPaneMessageChangesParams) async throws -> IPCPaneMessageChangesResult {
        let writer = try await resolveWriter(params.writer, paneId: paneId)
        switch await service.changes(
            PaneMessageChangesRequest(
                paneId: PaneId(existingUUID: paneId), writer: try writer.sender, after: AnswerPosition(params.after)))
        {
        case .page(let page):
            try IPCPaneNumericCoding.requireSafe(page.nextPosition.value)
            let entries = try page.entries.map { entry in
                try IPCPaneNumericCoding.requireSafe(entry.position.value)
                let kind: IPCPaneMessageChangeKind
                switch entry.kind {
                case .answer(let answer): kind = .answer(value: PaneContextIPCMapping.answer(answer))
                case .dismissal: kind = .dismissal
                case .withdrawal: kind = .withdrawal
                }
                return IPCPaneMessageChangeEntry(
                    id: entry.id, position: entry.position.value, messageId: entry.messageId.uuid, kind: kind)
            }
            return IPCPaneMessageChangesResult(entries: entries, nextPosition: page.nextPosition.value, more: page.more)
        case .refused(let reason): throw PaneContextIPCMapping.refusal(reason)
        case .unavailable: throw AppIPCPaneContextError(reason: .unavailable)
        }
    }

    @concurrent
    func setLine(paneId: UUID, params: IPCPaneLineSetParams) async throws -> IPCPaneOrderedWriteResult {
        let writer = try await resolveWriter(params.writer, paneId: paneId)
        if writer.isHistorical { return .stale(reason: .writerReplaced) }
        let line = try params.line.map(PaneContextIPCMapping.line)
        return try PaneContextIPCMapping.orderedResult(
            await service.setLine(
                PaneLineWriteRequest(
                    paneId: PaneId(existingUUID: paneId), writer: try writer.sender, line: line,
                    writeNumber: WriteNumber(epoch: params.writeNumber.epoch, counter: params.writeNumber.counter))))
    }

    @concurrent
    func setTitle(paneId: UUID, params: IPCPaneTitleSetParams) async throws -> IPCPaneOrderedWriteResult {
        let writer = try await resolveWriter(params.writer, paneId: paneId)
        if writer.isHistorical { return .stale(reason: .writerReplaced) }
        return try PaneContextIPCMapping.orderedResult(
            await service.setTitle(
                PaneTitleWriteRequest(
                    paneId: PaneId(existingUUID: paneId), writer: try writer.sender, text: params.text,
                    writeNumber: WriteNumber(epoch: params.writeNumber.epoch, counter: params.writeNumber.counter))))
    }

    @concurrent
    func claimEpoch(paneId: UUID, params: IPCPaneWriterClaimEpochParams) async throws -> IPCPaneEpochClaimResult {
        let writer = try await resolveWriter(params.writer, paneId: paneId)
        if writer.isHistorical { throw AppIPCPaneContextError(reason: .stale, staleness: .writerReplaced) }
        let stream: PaneWriteStream
        switch params.stream {
        case .line: stream = .line
        case .title: stream = .title
        }
        switch await service.claimEpoch(
            PaneEpochClaimRequest(
                paneId: PaneId(existingUUID: paneId), writer: try writer.sender, stream: stream, claimId: params.claimId
            ))
        {
        case .claimed(let epoch):
            try IPCPaneNumericCoding.requireSafe(epoch)
            return .claimed(epoch: epoch)
        case .refused(let reason): throw PaneContextIPCMapping.refusal(reason)
        case .unavailable: throw AppIPCPaneContextError(reason: .unavailable)
        }
    }

    @concurrent
    func readContext(paneId: UUID, params: IPCPaneContextGetParams, replyEnvelopeOverheadBytes: Int) async throws
        -> IPCPaneContextGetResult
    {
        let spanBegan: ContinuousClock.Instant? =
            performanceTraceRecorder?.isEnabled == true ? ContinuousClock.now : nil
        var detailDuration = Duration.zero
        var replyBytes = 0
        defer {
            if let spanBegan {
                performanceTraceRecorder?.recordDuration(
                    .ipcPaneContextRead, duration: spanBegan.duration(to: ContinuousClock.now),
                    attributes: [
                        "agentstudio.performance.ipc.pane_context_read.detail_elapsed_ms": .double(
                            AgentStudioPerformanceTraceRecorder.milliseconds(from: detailDuration)),
                        "agentstudio.performance.ipc.pane_context_read.reply_bytes": .int(replyBytes),
                    ])
            }
        }
        let productionCap = min(IPCFramePolicy.maximumResponseFrameBytes, AppPolicies.IPC.maximumQueuedOutputBytes - 1)
        guard replyEnvelopeOverheadBytes >= 0, replyEnvelopeOverheadBytes < productionCap else {
            throw AppIPCPaneContextError(reason: .tooLarge, field: "context")
        }
        let cap = min(maximumEncodedReplyBytes, productionCap - replyEnvelopeOverheadBytes)
        guard cap > 0 else { throw AppIPCPaneContextError(reason: .tooLarge, field: "context") }
        let request = PaneContextReadRequest(
            paneId: PaneId(existingUUID: paneId), page: PaneContextIPCMapping.page(params.page))
        var sizing = PaneContextIPCReplySizing()
        let fullReadBegan = spanBegan.map { _ in ContinuousClock.now }
        let fullRead = await service.readDetail(request, maximumDetailBytes: AppPolicies.PaneContext.maximumDetailBytes)
        if let fullReadBegan { detailDuration += fullReadBegan.duration(to: ContinuousClock.now) }
        let full = try PaneContextIPCMapping.detail(fullRead)
        let fullBytes = try sizing.encodedSize(full)
        if fullBytes <= cap {
            replyBytes = fullBytes
            return full
        }
        var fittingBudget = AppPolicies.PaneContext.minimumDetailBytes
        var oversizedBudget = AppPolicies.PaneContext.maximumDetailBytes
        let minimumReadBegan = spanBegan.map { _ in ContinuousClock.now }
        let minimumRead = await service.readDetail(request, maximumDetailBytes: fittingBudget)
        if let minimumReadBegan { detailDuration += minimumReadBegan.duration(to: ContinuousClock.now) }
        var best = try PaneContextIPCMapping.detail(minimumRead)
        var bestBytes = try sizing.encodedSize(best)
        guard bestBytes <= cap else {
            throw AppIPCPaneContextError(reason: .tooLarge, field: "context")
        }
        // Each read halves the interval: at most ceil(log2(full budget - floor)) search reads.
        while oversizedBudget - fittingBudget > 1 {
            let budget = fittingBudget + (oversizedBudget - fittingBudget) / 2
            let candidateReadBegan = spanBegan.map { _ in ContinuousClock.now }
            let candidateRead = await service.readDetail(request, maximumDetailBytes: budget)
            if let candidateReadBegan { detailDuration += candidateReadBegan.duration(to: ContinuousClock.now) }
            let result = try PaneContextIPCMapping.detail(candidateRead)
            let candidateBytes = try sizing.encodedSize(result)
            if candidateBytes <= cap {
                fittingBudget = budget
                best = result
                bestBytes = candidateBytes
            } else {
                oversizedBudget = budget
            }
        }
        replyBytes = bestBytes
        return best
    }

    private func sendResult(_ result: PaneMessageSendResult) throws -> IPCPaneMessageSendResult {
        switch result {
        case .created(let id): return .created(id: id.uuid)
        case .existing(let id): return .existing(id: id.uuid)
        case .refused(let reason): throw PaneContextIPCMapping.refusal(reason)
        case .unavailable: throw AppIPCPaneContextError(reason: .unavailable)
        }
    }

    private func resolveWriter(_ claim: IPCPaneWriterClaim?, paneId: UUID) async throws
        -> PaneContextIPCWriterResolution
    {
        guard let claim else { return .pane(PaneId(existingUUID: paneId)) }
        let binding: SessionsBindingRecord?
        do {
            binding = try await ingestion.bindingForProviderConversation(
                paneId: paneId, providerIdentifier: claim.provider, providerConversationId: claim.conversationId)
        } catch { throw AppIPCPaneContextError(reason: .unavailable) }
        guard let record = binding, record.paneId == paneId
        else { return .bindingRequired }
        let sender: AgentMessageSender
        do {
            sender = .session(
                provider: try BridgeAgentProviderName(record.providerIdentifier),
                sessionRef: try BridgeAgentSessionRef(record.providerConversationId),
                bindingGeneration: record.bindingGenerationId)
        } catch { throw AppIPCPaneContextError(reason: .invalidField, field: "writer") }
        switch record.status {
        case .active: return .active(sender)
        case .ended: return .historical(sender)
        }
    }
}

private enum PaneContextIPCWriterResolution {
    case pane(PaneId)
    case active(AgentMessageSender)
    case historical(AgentMessageSender)
    case bindingRequired

    var isHistorical: Bool {
        if case .historical = self { return true }
        return false
    }
    var sender: AgentMessageSender {
        get throws {
            switch self {
            case .pane(let paneId): return .pane(paneId)
            case .active(let sender), .historical(let sender): return sender
            case .bindingRequired: throw AppIPCPaneContextError(reason: .bindingRequired)
            }
        }
    }
}
