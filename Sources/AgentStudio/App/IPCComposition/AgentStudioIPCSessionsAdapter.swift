import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation

/// Wire mapping only. Sessions owns the serialized binding and status decisions.
struct AgentStudioIPCSessionsAdapter: AppIPCSessionsPort {
    let ingestion: SessionsIngestion
    let now: @Sendable () -> Date
    let continuousNow: @Sendable () -> ContinuousClock.Instant
    let activityClock: PaneActivityClock?
    let processChainReader: any ProcessChainReading
    private let ownerPaneLookup: @Sendable (PaneId) -> PaneId?
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    init(
        ingestion: SessionsIngestion, now: @escaping @Sendable () -> Date = { Date() },
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        activityClock: PaneActivityClock? = nil,
        ownerPaneLookup: @escaping @Sendable (PaneId) -> PaneId? = { _ in nil },
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        processChainReader: any ProcessChainReading
    ) {
        self.ingestion = ingestion
        self.now = now
        self.continuousNow = continuousNow
        self.activityClock = activityClock
        self.ownerPaneLookup = ownerPaneLookup
        self.performanceTraceRecorder = performanceTraceRecorder
        self.processChainReader = processChainReader
    }

    func recordProviderEvent(
        paneId: UUID, params: IPCSessionEventParams,
        provenance: IPCSessionEventProvenance, peerProcess: AppIPCPeerProcess? = nil
    ) async throws -> IPCSessionEventResult {
        let chain = observeProcessChain(peerProcess: peerProcess, providerIdentifier: params.provider.identifier)
        guard provenance == .matchingPane else { throw AppIPCSessionsError(reason: .validationRejected) }
        guard !params.event.conversationId.isEmpty else { throw AppIPCSessionsError(reason: .validationRejected) }
        let began = performanceTraceRecorder?.isEnabled == true ? ContinuousClock.now : nil
        defer {
            if let began {
                performanceTraceRecorder?.recordDuration(
                    .ipcSessionEvent,
                    duration: began.duration(to: ContinuousClock.now))
            }
        }
        let signal = try Self.providerSignal(for: params.event)
        let recordId = UUIDv7.generate()
        let admissionInstant = continuousNow()
        let hook = SessionsHookAdmission(
            paneId: paneId, providerIdentifier: params.provider.identifier,
            providerVersion: params.provider.version, sessionId: params.event.conversationId,
            eventName: signal.name, turnId: params.event.turnId,
            subject: params.event.toolId.map { .tool($0) } ?? params.event.subagentId.map { .subagent($0) } ?? .root,
            signal: signal, recordId: recordId, admissionInstant: admissionInstant,
            admittedAt: Date(timeIntervalSince1970: now().timeIntervalSince1970),
            ownerPaneId: ownerPaneLookup(.init(existingUUID: paneId))?.uuid,
            resumeHint: params.event.providerFields.resumeHint
                ?? Self.resumeHint(provider: params.provider.identifier, conversationId: params.event.conversationId),
            chain: chain)
        do {
            let outcome = try await ingestion.submitHook(hook)
            if case .committed(let committed) = outcome,
                committed.disposition == .bound || committed.disposition == .applied
            {
                activityClock?.submit(
                    .init(
                        paneId: paneId, source: .hook,
                        orderingInstant: admissionInstant, wallTime: now()))
            }
        } catch {
            if let capacityError = error as? SessionsRepositoryError {
                switch capacityError {
                case .paneQueueFull, .globalQueueFull:
                    await ingestion.recordRefusal(
                        paneId: paneId,
                        refusal: .init(reason: .queueFull, event: params.event.name.rawValue, at: now()))
                default: break
                }
            }
            throw Self.portError(from: error)
        }
        return .init(paneId: paneId, disposition: .admitted, correlationId: params.correlationId)
    }

    func observeProcessChain(peerProcess: AppIPCPeerProcess?, providerIdentifier: String) -> ProcessChainObservation {
        let peer = peerProcess.map { ProcessChainPeer(pid: $0.pid, pidVersion: $0.pidVersion) }
        return processChainReader.observe(peer: peer, provider: providerIdentifier)
    }

    func recordRefusal(
        paneId: UUID, params: IPCSessionRefusalParams,
        provenance: IPCSessionEventProvenance
    ) async throws -> IPCSessionRefusalResult {
        guard provenance == .matchingPane else { throw AppIPCSessionsError(reason: .validationRejected) }
        let reason: AgentConnectionRefusalReason
        switch params.reason {
        case .noSessionId: reason = .noSessionId
        case .undecodablePayload: reason = .undecodablePayload
        }
        await ingestion.recordRefusal(
            paneId: paneId, refusal: .init(reason: reason, event: params.event, at: now()))
        return .init(paneId: paneId)
    }

    func readSessionState(
        paneId: UUID,
        params: IPCSessionQueryParams
    ) async throws -> IPCSessionQueryResult {
        let read: SessionsStatusReadResult
        do { read = try await ingestion.readSessionStatus(paneId: paneId) } catch { throw Self.portError(from: error) }
        let refusal = await ingestion.lastRefusal(paneId: paneId).map { value in
            let reason = Self.wireRefusal(value.reason)
            let intent = Self.wireIntent(value.intent)
            return IPCSessionLastRefusal(
                reason: reason, event: value.event, at: value.at, intent: intent, count: value.count)
        }
        switch read {
        case .unbound:
            return IPCSessionQueryResult(paneId: paneId, sourceHealth: .unbound, session: nil, lastRefusal: refusal)
        case .live(let summary):
            return IPCSessionQueryResult(
                paneId: paneId, sourceHealth: .live, session: PaneContextIPCMapping.session(summary),
                lastRefusal: refusal)
        case .ended(let summary):
            return IPCSessionQueryResult(
                paneId: paneId, sourceHealth: .ended, session: PaneContextIPCMapping.session(summary),
                lastRefusal: refusal)
        }
    }
    static func portError(from error: any Error) -> any Error {
        guard let repositoryError = error as? SessionsRepositoryError else { return error }
        switch repositoryError {
        case .paneQueueFull, .globalQueueFull:
            return AppIPCSessionsError(reason: .queueFull)
        case .ingestionFinished:
            return AppIPCSessionsError(reason: .ingestionUnavailable)
        default: return AppIPCSessionsError(reason: .validationRejected)
        }
    }
}
