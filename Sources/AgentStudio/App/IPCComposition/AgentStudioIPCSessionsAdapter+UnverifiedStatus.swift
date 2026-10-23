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
        let hook = try observedUnverifiedHook(
            paneId: paneId, params: params, peerProcess: peerProcess, revalidateClaim: revalidateClaim)
        let instant = hook?.admissionInstant ?? continuousNow()
        let at = hook?.admittedAt ?? now()
        let reason: AgentConnectionRefusalReason
        let eventName: String?
        switch params.report {
        case .refusal(let refusal):
            reason = Self.domainRefusal(refusal)
            eventName = nil
        case .hook(let event, _, _):
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

    private func observedUnverifiedHook(
        paneId: UUID, params: IPCSessionStatusParams, peerProcess: AppIPCPeerProcess?,
        revalidateClaim: @Sendable () throws -> Void
    ) throws -> SessionsHookAdmission? {
        switch params.report {
        case .refusal:
            try revalidateClaim()
            return nil
        case .hook(let event, let provider, let providerSessionId):
            let chain = observeProcessChain(peerProcess: peerProcess, providerIdentifier: provider.identifier)
            try revalidateClaim()
            guard !providerSessionId.isEmpty, event.conversationId == providerSessionId else {
                throw AppIPCSessionsError(reason: .validationRejected)
            }
            let signal = try Self.providerSignal(for: event)
            let instant = continuousNow()
            let at = now()
            return .init(
                paneId: paneId, providerIdentifier: provider.identifier, providerVersion: provider.version,
                sessionId: providerSessionId, eventName: signal.name, turnId: event.turnId,
                signal: signal, recordId: UUIDv7.generate(), admissionInstant: instant, admittedAt: at, chain: chain)
        }
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
