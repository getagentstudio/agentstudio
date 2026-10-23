import Foundation

package typealias ProcessIncarnation = ZmxProcessIncarnation

package enum ForegroundProgram: String, Codable, Equatable, Sendable {
    case shell, claudeCode, codex, other, unknown
}

package struct PaneForegroundLook: Equatable, Sendable {
    package let paneId: UUID
    package let zmxSessionId: ZmxSessionID
    package let sessionIdentity: Data
    package let bindingGenerationId: UUID?
    package let program: ForegroundProgram
    package let observerLaunchId: UUID
    package let sequence: UInt64
    package let observedAt: Date

    package var evidence: PaneForegroundEvidence {
        .init(
            paneId: paneId, bindingGenerationId: bindingGenerationId, observerLaunchId: observerLaunchId,
            sequence: sequence, observedAt: observedAt, value: .look(program, sessionIdentity: sessionIdentity))
    }

    package init(
        paneId: UUID, zmxSessionId: ZmxSessionID, sessionIdentity: Data,
        bindingGenerationId: UUID?, program: ForegroundProgram,
        observerLaunchId: UUID, sequence: UInt64, observedAt: Date
    ) {
        self.paneId = paneId
        self.zmxSessionId = zmxSessionId
        self.sessionIdentity = sessionIdentity
        self.bindingGenerationId = bindingGenerationId
        self.program = program
        self.observerLaunchId = observerLaunchId
        self.sequence = sequence
        self.observedAt = observedAt
    }
}
