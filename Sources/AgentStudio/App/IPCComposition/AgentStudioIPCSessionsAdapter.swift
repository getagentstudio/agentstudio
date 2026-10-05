import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation

/// Bridges the IPC session methods to Sessions ingestion. It owns only the
/// wire-to-domain mapping: ordering, replay and reduction stay in Sessions, and
/// nothing here touches MainActor.
struct AgentStudioIPCSessionsAdapter: AppIPCSessionsPort {
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let ingestion: SessionsIngestion
    private let providerRegistry: SessionsProviderAdapterRegistry
    private let admissionFreshness: SessionsEvidenceFreshness
    private let now: @Sendable () -> Date
    private let continuousNow: @Sendable () -> ContinuousClock.Instant
    private let activityClock: PaneActivityClock?
    private let ownerPaneLookup: @Sendable (PaneId) -> PaneId?

    /// The live IPC server admits messages as `.live`. The offline spool drainer
    /// composes a second adapter over the same ingestion with `.late`, so one
    /// mapping serves both routes and freshness stays a composition input.
    init(
        ingestion: SessionsIngestion,
        providerRegistry: SessionsProviderAdapterRegistry,
        admissionFreshness: SessionsEvidenceFreshness = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        activityClock: PaneActivityClock? = nil,
        ownerPaneLookup: @escaping @Sendable (PaneId) -> PaneId? = { _ in nil },
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        self.performanceTraceRecorder = performanceTraceRecorder
        self.ingestion = ingestion
        self.providerRegistry = providerRegistry
        self.admissionFreshness = admissionFreshness
        self.now = now
        self.continuousNow = continuousNow
        self.activityClock = activityClock
        self.ownerPaneLookup = ownerPaneLookup
    }

    func recordProviderEvent(
        paneId: UUID,
        params: IPCSessionEventParams,
        provenance: IPCSessionEventProvenance
    ) async throws -> IPCSessionEventResult {
        guard params.permissionHandling == nil || params.event.name == .permission else {
            throw AgentStudioAppIPCRequestError(
                code: -32_602, message: "invalid params",
                data: .object([
                    "reason": .string("invalidParams"), "fieldPath": .string("$.permissionHandling"),
                ]))
        }
        let spanBegan: ContinuousClock.Instant? =
            performanceTraceRecorder?.isEnabled == true ? ContinuousClock.now : nil
        defer {
            if let spanBegan {
                performanceTraceRecorder?.recordDuration(
                    .ipcSessionEvent, duration: spanBegan.duration(to: ContinuousClock.now))
            }
        }
        let provider = SessionsProviderIdentity(
            providerIdentifier: params.provider.identifier, exactVersion: params.provider.version,
            operatingMode: params.provider.mode)
        let capability = Self.capability(for: params.event.name)
        let qualification = providerRegistry.qualification(
            providerIdentifier: provider.providerIdentifier, exactVersion: provider.exactVersion,
            operatingMode: provider.operatingMode, capability: capability)
        guard case .qualified = qualification else {
            return IPCSessionEventResult(
                paneId: paneId, disposition: Self.rejectedDisposition(qualification),
                correlationId: params.correlationId)
        }
        let submission = try qualifiedHookSubmission(paneId: paneId, params: params, provider: provider)
        let activityOccurrence: PaneActivityOccurrence? =
            if provenance == .matchingPane, submission.evidenceKind != nil {
                PaneActivityOccurrence(
                    paneId: paneId, source: .hook, orderingInstant: continuousNow(), wallTime: now())
            } else { nil }
        do {
            let result = try await ingestion.submitQualifiedHook(
                correlationId: params.correlationId, submission: submission)
            if result.disposition == .inserted, let activityOccurrence {
                activityClock?.submit(activityOccurrence)
            }
        } catch {
            throw Self.portError(from: error)
        }
        return IPCSessionEventResult(
            paneId: paneId,
            disposition: .admitted,
            correlationId: params.correlationId
        )
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
}

private typealias QualifiedSessionBindBuilder =
    @Sendable (UUID, SessionsEvidenceFreshness) throws -> SessionsBindMutation

extension AgentStudioIPCSessionsAdapter {
    private func qualifiedHookSubmission(
        paneId: UUID, params: IPCSessionEventParams, provider: SessionsProviderIdentity
    ) throws -> SessionsQualifiedHookSubmission {
        // Live prompt times must have the same epoch precision as SQLite restore.
        let admittedAt = Date(timeIntervalSince1970: now().timeIntervalSince1970)
        let fingerprint = try Self.providerIntentFingerprint(params)
        let capability = Self.capability(for: params.event.name)
        let kind: SessionsEvidenceKind?
        let signal: SessionProviderSignal?
        let occurrenceKind: SessionsProviderOccurrenceKind
        switch params.event.name {
        case .sessionStart:
            kind = nil
            signal = nil
            occurrenceKind = .bind
        case .sessionEnd:
            kind = nil
            signal = nil
            occurrenceKind = .sourceEnded
        default:
            kind = try Self.evidenceKind(for: params.event)
            signal = try Self.providerSignal(for: params.event, permissionHandling: params.permissionHandling)
            occurrenceKind = .evidence
        }
        let registry = providerRegistry
        let ownerPaneId = ownerPaneLookup(.init(existingUUID: paneId))?.uuid
        let makeBind: QualifiedSessionBindBuilder = { generation, freshness in
            let admission = SessionsQualifiedSessionStartAdmission(
                provider: provider,
                source: .init(
                    paneId: paneId, providerConversationId: params.event.conversationId,
                    sourceId: params.event.conversationId, sourceGenerationId: generation,
                    occurrenceId: params.event.occurrenceId),
                freshness: freshness, reportedAt: admittedAt)
            guard var bind = registry.qualifiedSessionStartBind(admission, qualifyingCapability: capability) else {
                throw AppIPCSessionsError(reason: .validationRejected)
            }
            bind.resumeHint =
                (params.event.name == .sessionStart ? params.event.providerFields.resumeHint : nil)
                ?? Self.resumeHint(provider: params.provider.identifier, conversationId: params.event.conversationId)
            bind.ownerPaneId = ownerPaneId
            bind.providerIntentFingerprint = fingerprint
            bind.sourceOccurredAt = params.event.sourceOccurredAt
            return bind
        }
        return SessionsQualifiedHookSubmission(
            paneId: paneId, providerIdentifier: provider.providerIdentifier,
            providerConversationId: params.event.conversationId,
            occurrence: .init(kind: occurrenceKind, occurrenceId: params.event.occurrenceId),
            providerIntentFingerprint: fingerprint, occurredAt: admittedAt,
            sourceOccurredAt: params.event.sourceOccurredAt, evidenceKind: kind,
            makeBind: makeBind,
            makeMutation: { generation, freshness in
                if params.event.name == .sessionStart { return .bind(try makeBind(generation, freshness)) }
                if params.event.name == .sessionEnd {
                    return .sourceEnded(
                        Self.sourceEndMutation(
                            paneId: paneId, sourceGenerationId: generation, params: params,
                            admittedAt: admittedAt, fingerprint: fingerprint))
                }
                guard let kind,
                    let context = registry.admitProviderEvidence(
                        .init(
                            provider: provider, capability: capability, paneId: paneId,
                            sourceGenerationId: generation, freshness: freshness))
                else { throw AppIPCSessionsError(reason: .validationRejected) }
                var evidence = SessionsEvidenceMutation(
                    admittedContext: context, occurrenceId: params.event.occurrenceId, turnId: params.event.turnId,
                    subject: Self.subject(for: params.event), kind: kind, occurredAt: admittedAt, sourceCursor: nil)
                evidence.sourceOccurredAt = params.event.sourceOccurredAt
                evidence.providerSignal = signal
                evidence.providerIntentFingerprint = fingerprint
                return .recordEvidence(evidence)
            })
    }

    /// An absent profile means no capability of this provider is known at all;
    /// a present profile that omits the capability is a known refusal.
    fileprivate static func rejectedDisposition(
        _ qualification: SessionsProviderQualification
    ) -> IPCSessionEventDisposition {
        switch qualification {
        case .qualified, .unavailable: .unqualified
        case .unverified: .unknownCapability
        }
    }

    fileprivate static func capability(
        for name: IPCSessionEventName
    ) -> SessionsProviderCapability {
        switch name {
        case .sessionStart: .sessionStart
        case .sessionEnd: .sessionEnd
        case .turnStart: .turnStart
        case .turnDone: .turnDone
        case .turnAbort: .turnAbort
        case .turnFailed: .turnFailed
        case .permission: .permission
        case .question: .question
        case .elicitation: .elicitation
        case .elicitationResult: .elicitationResult
        case .toolCompleted: .toolCompleted
        case .toolFailed: .toolFailed
        case .toolActivity: .toolActivity
        case .subagentActivity: .subagentActivity
        }
    }

    fileprivate static func subject(for event: IPCSessionEventIdentity) -> SessionsEvidenceSubject {
        if let toolId = event.toolId { return .tool(toolId) }
        if let subagentId = event.subagentId { return .subagent(subagentId) }
        return .root
    }

    fileprivate static func evidenceKind(
        for event: IPCSessionEventIdentity
    ) throws -> SessionsEvidenceKind {
        switch event.name {
        case .turnStart, .toolActivity, .subagentActivity, .toolCompleted, .toolFailed, .elicitationResult:
            return .activityStarted
        case .turnDone:
            return .completed
        case .turnAbort, .turnFailed:
            return .aborted
        case .permission, .question, .elicitation:
            let requestId = event.requestId ?? event.toolId ?? event.elicitationId ?? event.occurrenceId.uuidString
            return .needsYouOpened(requestId: requestId, explanation: nil)
        case .sessionStart, .sessionEnd:
            // Neither is evidence: one opens a source generation and the other
            // retires it. `qualifiedHookSubmission` routes both before reaching here.
            throw AppIPCSessionsError(reason: .validationRejected)
        }
    }

    fileprivate static func portError(from error: any Error) -> any Error {
        guard let repositoryError = error as? SessionsRepositoryError else { return error }
        switch repositoryError {
        case .bindingRequired, .sourceNotFound:
            return AppIPCSessionsError(reason: .bindingRequired)
        case .correlationConflict, .occurrenceConflict:
            return AppIPCSessionsError(reason: .correlationConflict)
        case .ingestionFinished, .paneQueueFull, .globalQueueFull:
            return AppIPCSessionsError(reason: .ingestionUnavailable)
        case .bindingConflict, .invalidStoredValue:
            return AppIPCSessionsError(reason: .validationRejected)
        }
    }
}
