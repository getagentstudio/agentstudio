import AgentStudioProgrammaticControl
import Foundation

package enum AppIPCConnectionEndCause: Equatable, Sendable {
    case eof
    case error
    case stopping
}

package struct AppIPCConnectionContext: Sendable {
    package let contextId: UUID
    package let channel: AgentStudioIPCChannel
    package let authenticatedContext: AgentStudioIPCAuthenticatedContext?
    package var principal: IPCPrincipal? { authenticatedContext?.principal }
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
        replyEnvelopeOverheadBytes: Int = 0
    ) {
        self.contextId = contextId
        self.replyEnvelopeOverheadBytes = replyEnvelopeOverheadBytes
        self.channel = channel
        self.authenticatedContext = authenticatedContext
        self.authenticateConnection = authenticate
        self.readAuthenticationStatus = authenticationStatus
        self.eventSubscriber = eventSubscriber
        self.readConnectionEndCause = connectionEndCause
    }

    package func authenticate(_ parameters: IPCAuthLoginParams) async throws -> IPCAuthStatusResult {
        try await authenticateConnection(parameters)
    }

    package func authenticationStatus() -> IPCAuthStatusResult {
        readAuthenticationStatus()
    }
}
