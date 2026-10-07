import AgentStudioCore
import Foundation

/// Split out of `WorkspaceSurfaceCoordinator.swift` (2026-09-30) to keep that
/// file under the 1000-line `file_length` lint gate: the `TopologyEffectHandler`
/// conformance and its two private helpers are already a self-contained unit
/// (Coordination Plane Decision Table: "Ordered post-topology effects" ->
/// `TopologyEffectHandler`, not via the bus), so extracting the whole block
/// verbatim needed no further restructuring.
extension WorkspaceSurfaceCoordinator: TopologyEffectHandler {
    func topologyDidChange(_ delta: WorktreeTopologyDelta) {
        applyTopologyRemovals(from: [delta])
        applyTopologyAdoptions(from: [delta])
        syncFilesystemRootsAndActivity()
    }

    func topologyDidChange(_ deltas: [WorktreeTopologyDelta]) {
        applyTopologyRemovals(from: deltas)
        applyTopologyAdoptions(from: deltas)
        syncFilesystemRootsAndActivity()
    }

    private func applyTopologyRemovals(from deltas: [WorktreeTopologyDelta]) {
        var removedWorktreeIDs = Set<UUID>()
        for delta in deltas {
            for entry in delta.removedWorktrees {
                removedWorktreeIDs.insert(entry.id)
                for _ in store.mutationCoordinator.clearPaneAssociations(forRemovedWorktreeID: entry.id) {
                    performanceTraceRecorder?.recordPaneAssociationOutcome(.topologyRemoved)
                }
            }
        }
        guard !removedWorktreeIDs.isEmpty else { return }
        // Scoped topology may already have cleared the source pane's optional facets.
        // The retained companion still carries the checkout whose authority must retire.
        for (sourcePaneID, companion) in store.panePresentationAtom.zoomCompanionsBySourcePaneId
        where removedWorktreeIDs.contains(companion.resolvedWorktreeId) {
            _ = reconcileZoomCompanion(sourcePaneId: sourcePaneID, owningTabId: companion.owningTabId)
        }
    }

    private func applyTopologyAdoptions(from deltas: [WorktreeTopologyDelta]) {
        let affectedWorktreeIDs = Set(
            deltas.flatMap { $0.addedWorktreeIds + $0.preservedWorktreeIds }
        )
        let adoptedPaneIDs = store.mutationCoordinator.reconcilePaneAssociationsForCurrentTopology(
            affectedWorktreeIDs: affectedWorktreeIDs
        )
        for _ in adoptedPaneIDs {
            performanceTraceRecorder?.recordPaneAssociationOutcome(.resolvedChanged)
        }
    }

    // MARK: - Tab Name Derivation

    /// Seed a stable tab name once at creation time from the pane's context.
    /// Worktree-backed panes get "folder · branch", others get the pane title.
    /// We intentionally do not auto-rename tabs later when enrichment changes.
    func tabNameForPane(_ pane: Pane) -> String {
        atom(\.tabDisplay).title(
            for: pane,
            workspaceRepositoryTopology: store.repositoryTopologyAtom,
            repoCache: atom(\.repoCache)
        )
    }
}
