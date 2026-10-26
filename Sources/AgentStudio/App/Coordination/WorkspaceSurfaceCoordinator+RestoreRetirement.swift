import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation
import os.log

extension WorkspaceSurfaceCoordinator {
    enum RestoreEvidenceRetirementRoute {
        case awaitingReady(pendingPaneIDs: Set<UUID>)
        case ready(sink: @Sendable (UUID) async -> Void)
    }

    /// The sink and optional schema must both be installed before report/cold-resume retirement delivery.
    /// Reuse the owned retirement route; snapshot deletion on replay is idempotent.
    func markRestoreEvidenceRetirementReady() {
        guard case .awaitingReady(let pendingPaneIDs) = restoreEvidenceRetirementRoute,
            let sink = restorePaneRetirementSink
        else { return }
        restoreEvidenceRetirementRoute = .ready(sink: sink)
        submitRestoreRetirement(pendingPaneIDs)
    }

    /// Capture availability never gates retirement. The snapshotter joins
    /// active captures when installed; the same store owns deletion either way.
    func submitRestoreRetirement(_ paneIDs: Set<UUID>) {
        guard !paneIDs.isEmpty else { return }
        let snapshotter = scrollbackSnapshotter
        let scrollback = scrollbackStore
        let retireReports: (@Sendable (UUID) async -> Void)?
        switch restoreEvidenceRetirementRoute {
        case .awaitingReady(var pendingPaneIDs):
            pendingPaneIDs.formUnion(paneIDs)
            restoreEvidenceRetirementRoute = .awaitingReady(pendingPaneIDs: pendingPaneIDs)
            retireReports = nil
        case .ready(let sink):
            retireReports = sink
        }
        guard snapshotter != nil || scrollback != nil || retireReports != nil else { return }
        let operationID = UUIDv7.generate()
        restoreRetirementTasksByID[operationID] = Task { [weak self] in
            do {
                if let snapshotter {
                    try await snapshotter.retire(operationID: operationID, paneUUIDs: paneIDs)
                } else if let scrollback {
                    try await Self.retireScrollbackSnapshots(paneIDs, using: scrollback)
                }
            } catch {
                // Never include captured data, paths or an OS error payload.
                Self.logger.warning("Scrollback retirement could not delete a snapshot")
            }
            for paneId in paneIDs { await retireReports?(paneId) }
            self?.restoreRetirementTasksByID.removeValue(forKey: operationID)
        }
    }

    @concurrent nonisolated private static func retireScrollbackSnapshots(
        _ paneIDs: Set<UUID>, using scrollback: ScrollbackStore
    ) async throws {
        try await scrollback.retire(paneIds: Set(paneIDs.map { PaneId(existingUUID: $0) }))
    }
}
