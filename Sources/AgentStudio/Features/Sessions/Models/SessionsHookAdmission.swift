import AgentStudioCore
import Foundation

package enum SessionsEvidenceStatusEffect: String, Codable, Sendable, Equatable {
    case applied, recordedOnly
}

/// Pane authentication is admitted by AppIPC; Sessions owns the binding table.
package struct SessionsHookAdmission: Sendable {
    package let paneId: UUID
    package let providerIdentifier: String
    package let providerVersion: String
    package let sessionId: String
    package let eventName: SessionProviderSignalName
    package let turnId: String?
    package let subject: SessionsEvidenceSubject
    package let kind: SessionsEvidenceKind
    package let signal: SessionProviderSignal?
    package let recordId: UUID
    package let admissionInstant: ContinuousClock.Instant
    package let admittedAt: Date
    package let ownerPaneId: UUID?
    package let resumeHint: String?
    /// Invoked by the FIFO consumer only after its current state predicts an election.
    package let observeProcessChain: @Sendable () -> ProcessChainObservation

    package init(
        paneId: UUID, providerIdentifier: String, providerVersion: String, sessionId: String,
        eventName: SessionProviderSignalName, turnId: String?, subject: SessionsEvidenceSubject = .root,
        kind: SessionsEvidenceKind = .activityStarted, signal: SessionProviderSignal? = nil,
        recordId: UUID, admissionInstant: ContinuousClock.Instant = ContinuousClock.now,
        admittedAt: Date, ownerPaneId: UUID? = nil, resumeHint: String? = nil, chain: ProcessChainObservation
    ) {
        self.init(
            paneId: paneId, providerIdentifier: providerIdentifier, providerVersion: providerVersion,
            sessionId: sessionId,
            eventName: eventName, turnId: turnId, subject: subject, kind: kind, signal: signal, recordId: recordId,
            admissionInstant: admissionInstant, admittedAt: admittedAt, ownerPaneId: ownerPaneId,
            resumeHint: resumeHint,
            observeProcessChain: { chain })
    }

    package init(
        paneId: UUID, providerIdentifier: String, providerVersion: String, sessionId: String,
        eventName: SessionProviderSignalName, turnId: String?, subject: SessionsEvidenceSubject = .root,
        kind: SessionsEvidenceKind = .activityStarted, signal: SessionProviderSignal? = nil,
        recordId: UUID, admissionInstant: ContinuousClock.Instant = ContinuousClock.now,
        admittedAt: Date, ownerPaneId: UUID? = nil, resumeHint: String? = nil,
        observeProcessChain: @escaping @Sendable () -> ProcessChainObservation
    ) {
        self.paneId = paneId
        self.providerIdentifier = providerIdentifier
        self.providerVersion = providerVersion
        self.sessionId = sessionId
        self.eventName = eventName
        self.turnId = turnId
        self.subject = subject
        self.kind = kind
        self.signal = signal
        self.recordId = recordId
        self.admissionInstant = admissionInstant
        self.admittedAt = admittedAt
        self.ownerPaneId = ownerPaneId
        self.resumeHint = resumeHint
        self.observeProcessChain = observeProcessChain
    }
}

package enum SessionsHookDisposition: String, Sendable, Equatable {
    case bound, applied, recordedOnly
}

package enum SessionsHookOutcome: Sendable, Equatable {
    case ignored
    case committed(SessionsHookCommit)
}

package struct SessionsHookCommit: Sendable, Equatable {
    package let disposition: SessionsHookDisposition
    package let binding: SessionsBindingRecord
    package let supersededBinding: SessionsBindingRecord?
    package let evidence: SessionsEvidenceRecord
    package let revision: Int64
}
