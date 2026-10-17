import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

/// Keeps the status-only recovery policy shared by both providers. Only an
/// explicit login rejection permits reconnecting without the pane credential.
struct ProviderHookStatusReporting {
    let environment: [String: String]
    let configuration: AgentStudioIPCClientConfiguration
    let delivery: ProviderHookDelivery
    let deadline: CallDeadline
    let diagnosticSink: (String) -> Void

    static func configuration(environment: [String: String]) -> AgentStudioIPCClientConfiguration? {
        guard let socket = environment["AGENTSTUDIO_IPC_SOCKET"], !socket.isEmpty else { return nil }
        let token = environment["AGENTSTUDIO_PANE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        guard token != nil || paneClaim(environment: environment) != nil else { return nil }
        return .init(socketPath: socket, authToken: token)
    }

    static func paneClaim(environment: [String: String]) -> IPCPaneClaim? {
        guard let pane = environment["AGENTSTUDIO_PANE_ID"].flatMap(UUID.init(uuidString:)),
            let workspace = environment["AGENTSTUDIO_WORKSPACE_ID"].flatMap(UUID.init(uuidString:))
        else { return nil }
        return .init(paneId: pane, workspaceId: workspace)
    }

    func event(_ params: IPCSessionEventParams) {
        submit(
            report: .hook(
                event: params.event, provider: params.provider, providerSessionId: params.event.conversationId),
            correlationID: params.correlationId,
            authenticated: { try delivery.deliver(params, configuration, deadline) })
    }

    func refusal(_ params: IPCSessionRefusalParams) {
        let reason = IPCAgentConnectionRefusalReason(rawValue: params.reason.rawValue) ?? .undecodablePayload
        diagnosticSink(reason.rawValue)
        submit(
            report: .refusal(reason: reason), correlationID: params.correlationId,
            authenticated: { try delivery.recordRefusal(params, configuration, deadline) })
    }

    private func submit(
        report: IPCSessionStatusReport, correlationID: UUID, authenticated: () throws -> Void
    ) {
        guard deadline.remainingBudget > .zero else {
            diagnosticSink(IPCAgentConnectionRefusalReason.deadlineExceeded.rawValue)
            return
        }
        let tokenOutcome: IPCSessionTokenOutcome
        if configuration.authToken != nil {
            do {
                try authenticated()
                return
            } catch let failure as IPCDescriptorClientFailure where failure.disposition == .authenticationRejected {
                tokenOutcome = .rejected
            } catch {
                diagnosticSink(Self.reason(for: error, deadline: deadline).rawValue)
                return
            }
        } else {
            tokenOutcome = .absent
        }
        diagnosticSink(IPCAgentConnectionRefusalReason.credentialNotRecognized.rawValue)
        guard deadline.remainingBudget > .zero else {
            diagnosticSink(IPCAgentConnectionRefusalReason.deadlineExceeded.rawValue)
            return
        }
        guard let claim = Self.paneClaim(environment: environment) else {
            diagnosticSink(IPCAgentConnectionRefusalReason.paneNotFound.rawValue)
            return
        }
        do {
            try delivery.reportStatus(
                .init(paneClaim: claim, tokenOutcome: tokenOutcome, report: report, correlationId: correlationID),
                configuration.withAuthToken(nil), deadline)
        } catch {
            diagnosticSink(Self.reason(for: error, deadline: deadline).rawValue)
        }
    }

    static func reason(for error: any Error, deadline: CallDeadline) -> IPCAgentConnectionRefusalReason {
        if deadline.remainingBudget == .zero { return .deadlineExceeded }
        if let failure = error as? IPCDescriptorRemoteFailure,
            let label = failure.documentedReason,
            let reason = IPCAgentConnectionRefusalReason(rawValue: label)
        {
            return reason
        }
        if let failure = error as? ProviderHookFailure,
            case .rejected(let label) = failure,
            let reason = IPCAgentConnectionRefusalReason(rawValue: label)
        {
            return reason
        }
        return .appUnavailable
    }
}
