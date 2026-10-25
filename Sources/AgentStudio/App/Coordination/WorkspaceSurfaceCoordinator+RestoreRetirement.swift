import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation
import os.log

extension WorkspaceSurfaceCoordinator {
    enum ForegroundRetirementRoute {
        case awaitingReady(pendingPaneIDs: Set<UUID>)
        case ready(sink: @Sendable (UUID) async -> Void)
    }

    /// The sink and optional schema must both be installed before foreground delivery.
    /// Reuse the owned retirement route; snapshot deletion on replay is idempotent.
    func markRestoreForegroundRetirementReady() {
        guard case .awaitingReady(let pendingPaneIDs) = restoreForegroundRetirementRoute,
            let sink = restorePaneRetirementSink
        else { return }
        restoreForegroundRetirementRoute = .ready(sink: sink)
        submitRestoreRetirement(pendingPaneIDs)
    }

    /// Capture availability never gates retirement. The snapshotter joins
    /// active captures when installed; the same store owns deletion either way.
    func submitRestoreRetirement(_ paneIDs: Set<UUID>) {
        guard !paneIDs.isEmpty else { return }
        let snapshotter = scrollbackSnapshotter
        let scrollback = scrollbackStore
        let retireForeground: (@Sendable (UUID) async -> Void)?
        switch restoreForegroundRetirementRoute {
        case .awaitingReady(var pendingPaneIDs):
            pendingPaneIDs.formUnion(paneIDs)
            restoreForegroundRetirementRoute = .awaitingReady(pendingPaneIDs: pendingPaneIDs)
            retireForeground = nil
        case .ready(let sink):
            retireForeground = sink
        }
        guard snapshotter != nil || scrollback != nil || retireForeground != nil else { return }
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
            for paneId in paneIDs { await retireForeground?(paneId) }
            self?.restoreRetirementTasksByID.removeValue(forKey: operationID)
        }
    }

    @concurrent nonisolated private static func retireScrollbackSnapshots(
        _ paneIDs: Set<UUID>, using scrollback: ScrollbackStore
    ) async throws {
        try await scrollback.retire(paneIds: Set(paneIDs.map { PaneId(existingUUID: $0) }))
    }
}
