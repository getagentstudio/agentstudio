import AgentStudioCore
import Foundation

package enum ForegroundEvidenceAdmission: Equatable, Sendable {
    case admitted, retiredPane, bindingChanged, invalidIdentity, reportedEvidence
}

/// Retained closed-app reports; this boundary never observes processes.
package protocol PaneForegroundEvidenceRepository: Sendable {
    func loadEvidence(paneId: UUID) async throws -> PaneForegroundEvidence?
    func clearReportedEvidenceForChangedBinding(paneId: UUID) async throws
    func retire(paneId: UUID) async throws
}
