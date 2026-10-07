import AgentStudioCore
import AgentStudioInfrastructure
import Observation

@MainActor
@Observable
package final class SessionStatusAtom {
    @ObservationIgnored private let statuses = AtomFamily<PaneId, AgentSessionStatus>(
        telemetryLabel: "sessions_status", isContentEqual: ==)
    @ObservationIgnored private let aggregateRevision = AtomRevision()

    package init() {}

    package func value(for paneId: PaneId) -> AgentSessionStatus? {
        statuses.value(for: paneId)
    }

    package func apply(_ batch: [PaneId: SessionStatusPublication]) {
        let mutation = AtomMutationContext(aggregateRevision: aggregateRevision)
        for (paneId, publication) in batch {
            switch publication {
            case .set(let status): statuses.setValue(status, for: paneId, mutation: mutation)
            case .remove: statuses.removeValue(for: paneId, mutation: mutation)
            }
        }
        mutation.commit()
    }
}
