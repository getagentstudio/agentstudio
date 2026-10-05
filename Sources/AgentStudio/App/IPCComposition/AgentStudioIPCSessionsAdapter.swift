import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation

/// Whether one projected provider event earned a Sessions mutation, and the
/// reported reason when it did not.
private enum SessionsProviderEventAdmissionOutcome: Sendable {
    case admitted(SessionsMutation)
    case rejected(IPCSessionEventDisposition)
}

/// Which of the pane's source generations one provider event names.
///
/// A provider that has not noticed it was replaced keeps reporting, and what it
/// reports is about its own conversation. Resolving the generation from the
/// event's conversation rather than from the pane's current binding is what
/// keeps a delayed event off whatever replaced it.
private enum SessionsProviderEventGeneration: Sendable {
    /// The pane's live binding, which this event's conversation still owns.
    case live(SessionsBindingRecord)
    /// A generation of this pane that has already been retired. Evidence
    /// against it is history and an end for it is a duplicate.
    case retired(SessionsBindingRecord)
    /// The pane has bindings, but never one for this conversation.
    case foreignConversation
    /// The pane has never bound at all.
    case unbound
}

/// Bridges the IPC session methods to Sessions ingestion. It owns only the
/// wire-to-domain mapping: ordering, replay and reduction stay in Sessions, and
/// nothing here touches MainActor.
struct AgentStudioIPCSessionsAdapter: AppIPCSessionsPort {
    private let ingestion: SessionsIngestion
    private let providerRegistry: SessionsProviderAdapterRegistry
    private let admissionFreshness: SessionsEvidenceFreshness
    private let now: @Sendable () -> Date
    private let continuousNow: @Sendable () -> ContinuousClock.Instant
    private let activityClock: PaneActivityClock?

    /// The live IPC server admits messages as `.live`. The offline spool drainer
    /// composes a second adapter over the same ingestion with `.late`, so one
    /// mapping serves both routes and freshness stays a composition input.
    init(
        ingestion: SessionsIngestion,
        providerRegistry: SessionsProviderAdapterRegistry,
        admissionFreshness: SessionsEvidenceFreshness = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        activityClock: PaneActivityClock? = nil
    ) {
        self.ingestion = ingestion
        self.providerRegistry = providerRegistry
        self.admissionFreshness = admissionFreshness
        self.now = now
        self.continuousNow = continuousNow
        self.activityClock = activityClock
    }

    func recordDeliberateReport(
        paneId: UUID,
        params: IPCSessionReportParams
    ) async throws -> IPCSessionReportResult {
        try await recordDeliberateReport(paneId: paneId, params: params, commitParticipant: nil)
    }

    func recordDeliberateReport(
        paneId: UUID,
        params: IPCSessionReportParams,
        commitParticipant: (any SessionsCommitParticipant)?
    ) async throws -> IPCSessionReportResult {
        let reportedAt = now()
        let mutation: SessionsMutation =
            switch params.kind {
            case .needsYou:
                .deliberateNeedsYou(
                    SessionsDeliberateNeedsYouMutation(
                        paneId: paneId,
                        explanation: params.explanation ?? "",
                        freshness: admissionFreshness,
                        reportedAt: reportedAt
                    )
                )
            case .clearNeedsYou:
                .clearDeliberateNeedsYou(
                    SessionsClearDeliberateNeedsYouMutation(
                        paneId: paneId,
                        freshness: admissionFreshness,
                        clearedAt: reportedAt
                    )
                )
            case .done:
                .deliberateDone(
                    SessionsDeliberateDoneMutation(
                        paneId: paneId,
                        freshness: admissionFreshness,
                        reportedAt: reportedAt
                    )
                )
            }
        do {
            _ = try await ingestion.submit(
                correlationId: params.correlationId, mutation: mutation,
                commitParticipant: commitParticipant)
        } catch {
            throw Self.portError(from: error)
        }
        let snapshot = try await paneSnapshot(paneId: paneId)
        return IPCSessionReportResult(
            paneId: paneId,
            state: Self.agentState(snapshot.state),
            origin: Self.evidenceOrigin(snapshot.stateOrigin),
            requestId: snapshot.currentAttention.first?.requestId,
            correlationId: params.correlationId
        )
    }

    func recordAgentMessage(
        paneId: UUID,
        params: IPCSessionMessageParams
    ) async throws -> IPCSessionMessageResult {
        try await recordAgentMessage(paneId: paneId, params: params, commitParticipant: nil)
    }

    func recordAgentMessage(
        paneId: UUID,
        params: IPCSessionMessageParams,
        commitParticipant: (any SessionsCommitParticipant)?
    ) async throws -> IPCSessionMessageResult {
        // Attribution is decided before submission so one correlation always
        // carries one semantic fingerprint. A binding that changes between
        // retries surfaces as a correlation conflict, which R-09 requires,
        // rather than quietly rewriting the retained outcome.
        let snapshot = try await paneSnapshot(paneId: paneId)
        let hasLiveBinding = snapshot.currentBinding?.status == .active
        let context: SessionsReportContext =
            hasLiveBinding ? .currentPaneBinding(paneId: paneId) : .unattributed(paneId: paneId)
        let outcome: SessionsMutationOutcome
        do {
            outcome = try await ingestion.submit(
                correlationId: params.correlationId,
                mutation: .message(
                    SessionsMessageMutation(
                        context: context,
                        text: params.text,
                        freshness: admissionFreshness,
                        receivedAt: now()
                    )
                ),
                commitParticipant: commitParticipant
            )
        } catch {
            throw Self.portError(from: error)
        }
        guard case .messageSaved(let occurrenceId, let attribution) = outcome else {
            throw AppIPCSessionsError(reason: .validationRejected)
        }
        return IPCSessionMessageResult(
            paneId: paneId,
            occurrenceId: occurrenceId,
            attributed: attribution == .attributed,
            correlationId: params.correlationId
        )
    }

    func recordProviderEvent(
        paneId: UUID,
        params: IPCSessionEventParams,
        provenance: IPCSessionEventProvenance
    ) async throws -> IPCSessionEventResult {
        let admission = try await providerAdmission(
            paneId: paneId,
            params: params,
            snapshot: try await paneSnapshot(paneId: paneId)
        )
        guard case .admitted(let mutation) = admission else {
            guard case .rejected(let disposition) = admission else {
                throw AppIPCSessionsError(reason: .validationRejected)
            }
            return IPCSessionEventResult(
                paneId: paneId,
                disposition: disposition,
                correlationId: params.correlationId
            )
        }
        let activityOccurrence: PaneActivityOccurrence? =
            if provenance == .matchingPane, case .recordEvidence = mutation {
                PaneActivityOccurrence(
                    paneId: paneId,
                    source: .hook,
                    orderingInstant: continuousNow(),
                    wallTime: now()
                )
            } else {
                nil
            }
        do {
            let submission = try await ingestion.submitWithCommitDisposition(
                correlationId: params.correlationId,
                mutation: mutation
            )
            if submission.disposition == .inserted, let activityOccurrence {
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
        let snapshot = try await paneSnapshot(paneId: paneId)
        return IPCSessionQueryResult(
            paneId: paneId,
            state: Self.agentState(snapshot.state),
            origin: Self.evidenceOrigin(snapshot.stateOrigin),
            needsYou: snapshot.currentAttention.first.map {
                IPCSessionAttentionProjection(requestId: $0.requestId, explanation: $0.explanation)
            },
            messages: snapshot.messages.map {
                IPCSessionMessageProjection(
                    occurrenceId: $0.occurrenceId,
                    text: $0.text,
                    seen: $0.disposition == .seen,
                    receivedAt: $0.reportedAt
                )
            },
            sourceHealth: Self.sourceHealth(snapshot.currentBinding)
        )
    }
}

extension AgentStudioIPCSessionsAdapter {
    fileprivate func paneSnapshot(paneId: UUID) async throws -> SessionsSnapshot {
        do {
            return try await ingestion.snapshot(
                .pane(
                    paneId,
                    page: SessionsSnapshotPage(
                        limit: IPCSessionSchemaLimits.maximumQueryMessageCount,
                        after: nil
                    )
                )
            )
        } catch {
            throw Self.portError(from: error)
        }
    }

    /// A session start binds the pane; every other name records evidence
    /// against the source generation its own conversation opened. Both routes
    /// admit only an exactly qualified provider identity.
    fileprivate func providerAdmission(
        paneId: UUID,
        params: IPCSessionEventParams,
        snapshot: SessionsSnapshot
    ) async throws -> SessionsProviderEventAdmissionOutcome {
        let provider = SessionsProviderIdentity(
            providerIdentifier: params.provider.identifier,
            exactVersion: params.provider.version,
            operatingMode: params.provider.mode
        )
        let capability = Self.capability(for: params.event.name)
        let qualification = providerRegistry.qualification(
            providerIdentifier: provider.providerIdentifier,
            exactVersion: provider.exactVersion,
            operatingMode: provider.operatingMode,
            capability: capability
        )
        guard case .qualified = qualification else {
            return .rejected(Self.rejectedDisposition(qualification))
        }
        let occurredAt = now()
        guard params.event.name != .sessionStart else {
            let admission = SessionsQualifiedSessionStartAdmission(
                provider: provider,
                source: SessionsBindingSourceIdentity(
                    paneId: paneId,
                    providerConversationId: params.event.conversationId,
                    sourceId: params.event.conversationId,
                    sourceGenerationId: UUIDv7.generate(),
                    occurrenceId: params.event.occurrenceId
                ),
                freshness: .live,
                reportedAt: occurredAt
            )
            guard let bind = providerRegistry.qualifiedSessionStartBind(admission) else {
                return .rejected(.unqualified)
            }
            return .admitted(.bind(bind))
        }
        let generation = try await eventGeneration(
            paneId: paneId,
            provider: provider,
            conversationId: params.event.conversationId,
            snapshot: snapshot
        )
        // A session end retires the generation it names rather than recording
        // evidence against it. It is decided before the binding requirement
        // below because ending a pane that is already unbound is not a caller
        // error — there is simply nothing left to retire. An end for a
        // generation that is already retired is a duplicate: the reduction
        // recognizes the ended source and changes nothing.
        guard params.event.name != .sessionEnd else {
            switch generation {
            case .unbound, .foreignConversation:
                return .rejected(.unqualified)
            case .live(let binding), .retired(let binding):
                return .admitted(
                    .sourceEnded(
                        SessionsSourceEndMutation(
                            paneId: paneId,
                            sourceGenerationId: binding.sourceGenerationId,
                            endedAt: occurredAt
                        )
                    )
                )
            }
        }
        let binding: SessionsBindingRecord
        let freshness: SessionsEvidenceFreshness
        switch generation {
        case .unbound:
            throw AppIPCSessionsError(reason: .bindingRequired)
        case .foreignConversation:
            // Not late evidence about anything this pane ran. Recording it
            // against the live generation would make one pane's state answer
            // for a session that was never on it.
            return .rejected(.unqualified)
        case .live(let liveBinding):
            binding = liveBinding
            freshness = .live
        case .retired(let retiredBinding):
            // The reduction stores this against its own generation as history
            // and projects nothing onto whatever replaced it.
            binding = retiredBinding
            freshness = .historical
        }
        guard
            let admitted = providerRegistry.admitProviderEvidence(
                SessionsProviderEvidenceAdmission(
                    provider: provider,
                    capability: capability,
                    paneId: paneId,
                    sourceGenerationId: binding.sourceGenerationId,
                    freshness: freshness
                )
            )
        else {
            return .rejected(.unqualified)
        }
        return .admitted(
            .recordEvidence(
                SessionsEvidenceMutation(
                    admittedContext: admitted,
                    occurrenceId: params.event.occurrenceId,
                    turnId: params.event.turnId,
                    subject: Self.subject(for: params.event),
                    kind: try Self.evidenceKind(for: params.event),
                    occurredAt: occurredAt,
                    sourceCursor: nil
                )
            )
        )
    }

    /// Resolves the generation an event belongs to from the conversation it
    /// names.
    ///
    /// The current binding answers the common case for free, so only a
    /// conversation the pane is not bound to right now costs a read. A pane has
    /// at most one active binding and the snapshot already names it, so any
    /// binding this read finds belongs to a generation that has been retired.
    fileprivate func eventGeneration(
        paneId: UUID,
        provider: SessionsProviderIdentity,
        conversationId: String,
        snapshot: SessionsSnapshot
    ) async throws -> SessionsProviderEventGeneration {
        guard let currentBinding = snapshot.currentBinding else { return .unbound }
        if currentBinding.providerIdentifier == provider.providerIdentifier,
            currentBinding.providerConversationId == conversationId
        {
            return currentBinding.status == .active ? .live(currentBinding) : .retired(currentBinding)
        }
        let earlierBinding: SessionsBindingRecord?
        do {
            earlierBinding = try await ingestion.bindingForProviderConversation(
                paneId: paneId,
                providerIdentifier: provider.providerIdentifier,
                providerConversationId: conversationId
            )
        } catch {
            throw Self.portError(from: error)
        }
        guard let earlierBinding else { return .foreignConversation }
        return .retired(earlierBinding)
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
        case .permission: .permission
        case .question: .question
        case .elicitation: .elicitation
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
        case .turnStart, .toolActivity, .subagentActivity:
            return .activityStarted
        case .turnDone:
            return .completed
        case .turnAbort:
            return .aborted
        case .permission, .question, .elicitation:
            guard let requestId = event.requestId else {
                throw AppIPCSessionsError(reason: .validationRejected)
            }
            return .needsYouOpened(requestId: requestId, explanation: nil)
        case .sessionStart, .sessionEnd:
            // Neither is evidence: one opens a source generation and the other
            // retires it. `providerAdmission` routes both before reaching here.
            throw AppIPCSessionsError(reason: .validationRejected)
        }
    }

    fileprivate static func agentState(_ state: SessionsAgentState) -> IPCSessionAgentState {
        switch state {
        case .unknown: .unknown
        case .running: .running
        case .needsYou: .needsYou
        case .done: .done
        }
    }

    fileprivate static func evidenceOrigin(
        _ origin: SessionsEvidenceOrigin?
    ) -> IPCSessionEvidenceOrigin {
        switch origin {
        case .none: .unknown
        case .estimated: .estimated
        case .agentReported: .agentReported
        case .reported: .reported
        }
    }

    fileprivate static func sourceHealth(
        _ binding: SessionsBindingRecord?
    ) -> IPCSessionSourceHealth {
        guard let binding else { return .unbound }
        return binding.status == .active ? .live : .ended
    }

    fileprivate static func portError(from error: any Error) -> any Error {
        guard let repositoryError = error as? SessionsRepositoryError else { return error }
        switch repositoryError {
        case .bindingRequired, .sourceNotFound, .attentionNotFound:
            return AppIPCSessionsError(reason: .bindingRequired)
        case .correlationConflict, .occurrenceConflict:
            return AppIPCSessionsError(reason: .correlationConflict)
        case .ingestionFinished, .paneQueueFull, .globalQueueFull:
            return AppIPCSessionsError(reason: .ingestionUnavailable)
        case .bindingConflict, .messageNotFound, .invalidStoredValue, .invalidPageLimit,
            .staleSnapshotCursor:
            return AppIPCSessionsError(reason: .validationRejected)
        }
    }
}
