import AgentStudioCore
import Foundation

package enum ForegroundEvidenceAdmission: Equatable, Sendable {
    case admitted, retiredPane, bindingChanged, olderLook, invalidIdentity, reportedEvidence
}

package struct ForegroundPaneBinding: Equatable, Sendable {
    package let paneId: UUID
    package let sessionId: ZmxSessionID
    package let bindingGenerationId: UUID?
}

package protocol PaneForegroundEvidenceRepository: Sendable {
    func eligiblePanes() async throws -> [ForegroundPaneBinding]
    func admit(_ look: PaneForegroundLook) async throws -> ForegroundEvidenceAdmission
    func load(paneId: UUID) async throws -> PaneForegroundLook?
    func loadEvidence(paneId: UUID) async throws -> PaneForegroundEvidence?
    func clearReportedEvidenceForChangedBinding(paneId: UUID) async throws
    func retire(paneId: UUID) async throws
}
