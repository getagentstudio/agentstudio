import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package enum AppIPCConnectionEndCause: Equatable, Sendable {
    case eof
    case error
    case stopping
}

package struct AppIPCConnectionContext: Sendable {
    package let contextId: UUID
    package let peerProcess: AppIPCPeerProcess?
    package let channel: AgentStudioIPCChannel
    package let authenticatedContext: AgentStudioIPCAuthenticatedContext?
    package var principal: IPCPrincipal? { requestPrincipal ?? authenticatedContext?.principal }
    private let requestPrincipal: IPCPrincipal?
    package let paneClaimAdmission: AppIPCPaneClaimAdmission?
    private let runtimeId: UUID?
    package let replyEnvelopeOverheadBytes: Int
    private let authenticateConnection: @Sendable (IPCAuthLoginParams) async throws -> IPCAuthStatusResult
    private let readAuthenticationStatus: @Sendable () -> IPCAuthStatusResult
    package let eventSubscriber: any IPCEventSubscriber
    private let readConnectionEndCause: @Sendable () -> AppIPCConnectionEndCause

    package var connectionEndCause: AppIPCConnectionEndCause { readConnectionEndCause() }

    package init(
        contextId: UUID,
        channel: AgentStudioIPCChannel,
        authenticatedContext: AgentStudioIPCAuthenticatedContext?,
        authenticate: @escaping @Sendable (IPCAuthLoginParams) async throws -> IPCAuthStatusResult,
        authenticationStatus: @escaping @Sendable () -> IPCAuthStatusResult,
        eventSubscriber: any IPCEventSubscriber,
        connectionEndCause: @escaping @Sendable () -> AppIPCConnectionEndCause = { .eof },
        replyEnvelopeOverheadBytes: Int = 0,
        paneClaimAdmission: AppIPCPaneClaimAdmission? = nil,
        runtimeId: UUID? = nil,
        requestPrincipal: IPCPrincipal? = nil,
        peerProcess: AppIPCPeerProcess? = nil
    ) {
        self.requestPrincipal = requestPrincipal
        self.peerProcess = peerProcess
        self.paneClaimAdmission = paneClaimAdmission
        self.runtimeId = runtimeId
        self.contextId = contextId
        self.replyEnvelopeOverheadBytes = replyEnvelopeOverheadBytes
        self.channel = channel
        self.authenticatedContext = authenticatedContext
        self.authenticateConnection = authenticate
        self.readAuthenticationStatus = authenticationStatus
        self.eventSubscriber = eventSubscriber
        self.readConnectionEndCause = connectionEndCause
    }

    func admittingClaim(parameters: Data, intent: IPCCallIntent) throws -> Self {
        guard principal == nil else { return self }
        guard let paneClaimAdmission, let runtimeId else {
            throw AppIPCTypedMethodRegistrationError.authenticationRequired
        }
        let principal = try paneClaimAdmission.admit(
            parameters: parameters, intent: intent, runtimeId: runtimeId, contextId: contextId)
        return Self(
            contextId: contextId, channel: channel, authenticatedContext: nil,
            authenticate: authenticateConnection, authenticationStatus: readAuthenticationStatus,
            eventSubscriber: eventSubscriber, connectionEndCause: readConnectionEndCause,
            replyEnvelopeOverheadBytes: replyEnvelopeOverheadBytes,
            paneClaimAdmission: paneClaimAdmission, runtimeId: runtimeId, requestPrincipal: principal,
            peerProcess: peerProcess)
    }

    package func revalidatePaneClaim() throws {
        guard case .paneClaim(let paneId, let workspaceId)? = principal?.kind else { return }
        guard let paneClaimAdmission else { throw AppIPCPaneClaimError(reason: .intentRequiresToken) }
        try paneClaimAdmission.validate(.init(paneId: paneId, workspaceId: workspaceId))
    }

    package func authenticate(_ parameters: IPCAuthLoginParams) async throws -> IPCAuthStatusResult {
        try await authenticateConnection(parameters)
    }

    package func authenticationStatus() -> IPCAuthStatusResult {
        readAuthenticationStatus()
    }
}
