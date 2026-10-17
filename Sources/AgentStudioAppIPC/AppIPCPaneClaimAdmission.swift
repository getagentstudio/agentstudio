import AgentStudioProgrammaticControl
import Foundation

package struct AppIPCPaneClaimError: Error, Sendable, Equatable {
    package let reason: IPCAgentConnectionRefusalReason
    package init(reason: IPCAgentConnectionRefusalReason) { self.reason = reason }
}

/// Only installed on a context after the socket's same-user peer gate succeeds.
/// Its result is request-local and is never installed as connection authentication.
package struct AppIPCPaneClaimAdmission: Sendable {
    private let membershipRefusal: @Sendable (IPCPaneClaim) -> IPCAgentConnectionRefusalReason?

    package init(membershipRefusal: @escaping @Sendable (IPCPaneClaim) -> IPCAgentConnectionRefusalReason?) {
        self.membershipRefusal = membershipRefusal
    }

    package func validate(_ claim: IPCPaneClaim) throws {
        if let reason = membershipRefusal(claim) { throw AppIPCPaneClaimError(reason: reason) }
    }

    func admit(parameters: Data, intent: IPCCallIntent, runtimeId: UUID, contextId: UUID) throws -> IPCPrincipal {
        let envelope = try JSONDecoder().decode(ClaimEnvelope.self, from: parameters)
        guard intent.effective(hasSessionWriter: envelope.writer != nil) == .status else {
            throw AppIPCPaneClaimError(reason: .intentRequiresToken)
        }
        guard let claim = envelope.paneClaim else { throw AppIPCPaneClaimError(reason: .paneNotFound) }
        try validate(claim)
        return IPCPrincipal(
            principalId: contextId, runtimeId: runtimeId, accessMode: .agentStudioOnly,
            kind: .paneClaim(paneId: claim.paneId, workspaceId: claim.workspaceId),
            approvalAuthority: .noApprovalAuthority)
    }

    private struct ClaimEnvelope: Decodable {
        let paneClaim: IPCPaneClaim?
        let writer: IPCPaneWriterClaim?
    }
}
