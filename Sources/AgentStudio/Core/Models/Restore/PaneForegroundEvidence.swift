import Foundation

/// Reported vetoes retain their binding and observation order just as looks do.
package struct PaneForegroundEvidence: Equatable, Sendable {
    package let paneId: UUID
    package let bindingGenerationId: UUID?
    package let observerLaunchId: UUID
    package let sequence: UInt64
    package let observedAt: Date
    package let value: ForegroundEvidence

    package init(
        paneId: UUID, bindingGenerationId: UUID?, observerLaunchId: UUID, sequence: UInt64,
        observedAt: Date, value: ForegroundEvidence
    ) {
        self.paneId = paneId
        self.bindingGenerationId = bindingGenerationId
        self.observerLaunchId = observerLaunchId
        self.sequence = sequence
        self.observedAt = observedAt
        self.value = value
    }
}
