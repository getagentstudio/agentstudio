import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation

extension AgentStudioIPCSessionsAdapter {
    func recordUnverifiedStatus(
        paneId: UUID, params: IPCSessionStatusParams, peerProcess: AppIPCPeerProcess? = nil,
        revalidateClaim: @escaping @Sendable () throws -> Void
    ) async throws -> IPCSessionEventResult {
        try revalidateClaim()
        let instant = continuousNow()
        let at = now()
        let hook: SessionsHookAdmission?
        let reason: AgentConnectionRefusalReason
        let eventName: String?
        switch params.report {
        case .refusal(let refusal):
            hook = nil
            reason = Self.domainRefusal(refusal)
            eventName = nil
        case .hook(let event, let provider, let providerSessionId):
            guard !providerSessionId.isEmpty, event.conversationId == providerSessionId else {
                throw AppIPCSessionsError(reason: .validationRejected)
            }
            let signal = try Self.providerSignal(for: event)
            hook = SessionsHookAdmission(
                paneId: paneId, providerIdentifier: provider.identifier, providerVersion: provider.version,
                sessionId: providerSessionId, eventName: signal.name, turnId: event.turnId,
                signal: signal, recordId: UUIDv7.generate(), admissionInstant: instant, admittedAt: at,
                chain: .unknown(.peerUnbound))
            reason = .credentialNotRecognized
            eventName = event.name.rawValue
        }
        do {
            let outcome = try await ingestion.recordUnverifiedStatus(
                paneId: paneId, hook: hook,
                refusal: .init(reason: reason, event: eventName, at: at, intent: .status),
                remainsPresent: { (try? revalidateClaim()) != nil })
            try revalidateClaim()
            // Like the verified path's bound/applied rule: only a hook that takes effect moves activity.
            switch outcome {
            case .hookApplied:
                activityClock?.submit(.init(paneId: paneId, source: .hook, orderingInstant: instant, wallTime: at))
            case .hookAcceptedWithoutStatus, .notAccepted, .refusalRecorded: break
            }
        } catch { throw Self.portError(from: error) }
        return .init(paneId: paneId, disposition: .admitted, correlationId: params.correlationId)
    }

    static func domainRefusal(_ reason: IPCAgentConnectionRefusalReason) -> AgentConnectionRefusalReason {
        switch reason {
        case .credentialNotRecognized: .credentialNotRecognized
        case .paneNotFound: .paneNotFound
        case .paneRetired: .paneRetired
        case .otherWorkspace: .otherWorkspace
        case .intentRequiresToken: .intentRequiresToken
        case .noSessionId: .noSessionId
        case .undecodablePayload: .undecodablePayload
        case .queueFull: .queueFull
        case .appUnavailable: .appUnavailable
        case .deadlineExceeded: .deadlineExceeded
        case .orderingStoreUnavailable: .orderingStoreUnavailable
        }
    }

    static func wireRefusal(_ reason: AgentConnectionRefusalReason) -> IPCAgentConnectionRefusalReason {
        switch reason {
        case .credentialNotRecognized: .credentialNotRecognized
        case .paneNotFound: .paneNotFound
        case .paneRetired: .paneRetired
        case .otherWorkspace: .otherWorkspace
        case .intentRequiresToken: .intentRequiresToken
        case .noSessionId: .noSessionId
        case .undecodablePayload: .undecodablePayload
        case .queueFull: .queueFull
        case .appUnavailable: .appUnavailable
        case .deadlineExceeded: .deadlineExceeded
        case .orderingStoreUnavailable: .orderingStoreUnavailable
        }
    }

    static func wireIntent(_ intent: AgentCallIntent) -> IPCCallIntent {
        switch intent {
        case .status: .status
        case .identity: .identity
        case .message: .message
        case .read: .read
        case .control: .control
        }
    }
}
