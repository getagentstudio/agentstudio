import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation

/// Wire mapping only. Sessions owns the serialized binding and status decisions.
struct AgentStudioIPCSessionsAdapter: AppIPCSessionsPort {
    private let ingestion: SessionsIngestion
    private let now: @Sendable () -> Date
    private let continuousNow: @Sendable () -> ContinuousClock.Instant
    private let activityClock: PaneActivityClock?
    private let ownerPaneLookup: @Sendable (PaneId) -> PaneId?
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    init(
        ingestion: SessionsIngestion, now: @escaping @Sendable () -> Date = { Date() },
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        activityClock: PaneActivityClock? = nil,
        ownerPaneLookup: @escaping @Sendable (PaneId) -> PaneId? = { _ in nil },
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        self.ingestion = ingestion
        self.now = now
        self.continuousNow = continuousNow
        self.activityClock = activityClock
        self.ownerPaneLookup = ownerPaneLookup
        self.performanceTraceRecorder = performanceTraceRecorder
    }

    func recordProviderEvent(
        paneId: UUID, params: IPCSessionEventParams,
        provenance: IPCSessionEventProvenance
    ) async throws -> IPCSessionEventResult {
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
        let hook = SessionsHookAdmission(
            paneId: paneId, providerIdentifier: params.provider.identifier,
            providerVersion: params.provider.version, sessionId: params.event.conversationId,
            eventName: signal.name, turnId: params.event.turnId,
            subject: params.event.toolId.map { .tool($0) } ?? params.event.subagentId.map { .subagent($0) } ?? .root,
            signal: signal, recordId: recordId, admittedAt: Date(timeIntervalSince1970: now().timeIntervalSince1970),
            ownerPaneId: ownerPaneLookup(.init(existingUUID: paneId))?.uuid,
            resumeHint: params.event.providerFields.resumeHint
                ?? Self.resumeHint(provider: params.provider.identifier, conversationId: params.event.conversationId))
        do {
            let committed = try await ingestion.submitHook(hook)
            if committed.disposition == .bound || committed.disposition == .applied {
                activityClock?.submit(
                    .init(
                        paneId: paneId, source: .hook,
                        orderingInstant: continuousNow(), wallTime: now()))
            }
        } catch { throw Self.portError(from: error) }
        return .init(paneId: paneId, disposition: .admitted, correlationId: params.correlationId)
    }

    // Unit 3 fills the explicitly commissioned refusal slot.
    func recordRefusal(
        paneId: UUID, params _: IPCSessionRefusalParams,
        provenance: IPCSessionEventProvenance
    ) async throws -> IPCSessionRefusalResult {
        guard provenance == .matchingPane else { throw AppIPCSessionsError(reason: .validationRejected) }
        return .init(paneId: paneId)
    }

    func readSessionState(
        paneId: UUID,
        params: IPCSessionQueryParams
    ) async throws -> IPCSessionQueryResult {
        let read: SessionsStatusReadResult
        do { read = try await ingestion.readSessionStatus(paneId: paneId) } catch { throw Self.portError(from: error) }
        switch read {
        case .unbound:
            return IPCSessionQueryResult(paneId: paneId, sourceHealth: .unbound, session: nil)
        case .live(let summary):
            return IPCSessionQueryResult(
                paneId: paneId, sourceHealth: .live, session: PaneContextIPCMapping.session(summary))
        case .ended(let summary):
            return IPCSessionQueryResult(
                paneId: paneId, sourceHealth: .ended, session: PaneContextIPCMapping.session(summary))
        }
    }
    private static func portError(from error: any Error) -> any Error {
        guard let repositoryError = error as? SessionsRepositoryError else { return error }
        switch repositoryError {
        case .ingestionFinished, .paneQueueFull, .globalQueueFull:
            return AppIPCSessionsError(reason: .ingestionUnavailable)
        default: return AppIPCSessionsError(reason: .validationRejected)
        }
    }
}
