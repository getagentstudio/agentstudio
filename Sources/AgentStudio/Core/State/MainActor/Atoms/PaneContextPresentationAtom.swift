import AgentStudioInfrastructure
import Observation

@MainActor
@Observable
package final class PaneContextPresentationAtom {
    @ObservationIgnored private let displays = AtomFamily<PaneId, PaneContextDisplay>(
        telemetryLabel: "pane_context_presentation", isContentEqual: ==)
    @ObservationIgnored private let aggregateRevision = AtomRevision()

    package init() {}

    package func value(for paneId: PaneId) -> PaneContextDisplay? { displays.value(for: paneId) }

    package func apply(_ batch: [PaneId: PaneContextPublication]) {
        let mutation = AtomMutationContext(aggregateRevision: aggregateRevision)
        for (paneId, publication) in batch {
            switch publication {
            case .set(let display): displays.setValue(display, for: paneId, mutation: mutation)
            case .remove: displays.removeValue(for: paneId, mutation: mutation)
            }
        }
        mutation.commit()
    }

    package func remove(_ paneIds: [PaneId]) {
        let mutation = AtomMutationContext(aggregateRevision: aggregateRevision)
        for paneId in paneIds { displays.removeValue(for: paneId, mutation: mutation) }
        mutation.commit()
    }
}
