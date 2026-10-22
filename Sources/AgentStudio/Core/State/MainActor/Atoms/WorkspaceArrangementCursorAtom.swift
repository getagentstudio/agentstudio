import AgentStudioInfrastructure
import Foundation
import Observation

struct ArrangementDrawerCursorKey: Hashable, Sendable {
    let arrangementId: UUID
    let drawerId: UUID
}

struct ArrangementPaneCursorState: Equatable, Hashable, Sendable {
    var activePaneId: UUID?
}

struct ArrangementDrawerCursorState: Equatable, Hashable, Sendable {
    var activeChildId: UUID?
}

@MainActor
@Observable
package final class WorkspaceArrangementCursorAtom {
    @ObservationIgnored private let activeArrangementFamily = AtomFamily<UUID, UUID>(
        telemetryLabel: "workspace_active_arrangement",
        isContentEqual: ==
    )
    @ObservationIgnored private let paneCursorFamily = AtomFamily<UUID, ArrangementPaneCursorState>(
        telemetryLabel: "workspace_arrangement_pane_cursor",
        isContentEqual: ==
    )
    @ObservationIgnored private let drawerCursorFamily = AtomFamily<
        ArrangementDrawerCursorKey,
        ArrangementDrawerCursorState
    >(
        telemetryLabel: "workspace_arrangement_drawer_cursor",
        isContentEqual: ==
    )
    @ObservationIgnored private let acceptedCommitRevision = AtomRevision()

    package var activeArrangementIdsByTabId: [UUID: UUID] {
        _ = acceptedCommitRevision.value
        return activeArrangementFamily.snapshot()
    }

    var paneCursorsByArrangementId: [UUID: ArrangementPaneCursorState] {
        _ = acceptedCommitRevision.value
        return paneCursorFamily.snapshot()
    }

    var drawerCursorsByKey: [ArrangementDrawerCursorKey: ArrangementDrawerCursorState] {
        _ = acceptedCommitRevision.value
        return drawerCursorFamily.snapshot()
    }

    func replaceCursors(
        activeArrangementIdsByTabId: [UUID: UUID],
        paneCursorsByArrangementId: [UUID: ArrangementPaneCursorState],
        drawerCursorsByKey: [ArrangementDrawerCursorKey: ArrangementDrawerCursorState]
    ) {
        let mutation = AtomMutationContext(aggregateRevision: acceptedCommitRevision)
        activeArrangementFamily.replaceAll(activeArrangementIdsByTabId, mutation: mutation)
        paneCursorFamily.replaceAll(paneCursorsByArrangementId, mutation: mutation)
        drawerCursorFamily.replaceAll(drawerCursorsByKey, mutation: mutation)
        mutation.commit()
    }

    package func activeArrangementId(forTab tabId: UUID) -> UUID? {
        activeArrangementFamily.value(for: tabId)
    }

    package func activeArrangementRevision(forTab tabId: UUID) -> Int {
        activeArrangementFamily.revision(for: tabId)
    }

    func activePaneId(forArrangement arrangementId: UUID) -> UUID? {
        paneCursorFamily.value(for: arrangementId)?.activePaneId
    }

    package func paneCursorRevision(forArrangement arrangementId: UUID) -> Int {
        paneCursorFamily.revision(for: arrangementId)
    }

    func activeChildId(forArrangement arrangementId: UUID, drawerId: UUID) -> UUID? {
        drawerCursorFamily.value(
            for: ArrangementDrawerCursorKey(arrangementId: arrangementId, drawerId: drawerId)
        )?.activeChildId
    }

    package func drawerCursorRevision(arrangementId: UUID, drawerId: UUID) -> Int {
        drawerCursorFamily.revision(
            for: ArrangementDrawerCursorKey(arrangementId: arrangementId, drawerId: drawerId)
        )
    }

}
