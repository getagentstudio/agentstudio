import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation
import os.log

extension WorkspaceSurfaceCoordinator {
    /// Capture availability never gates retirement. The snapshotter joins
    /// active captures when installed; the same store owns deletion either way.
    func submitScrollbackRetirement(_ paneIDs: Set<UUID>) {
        guard !paneIDs.isEmpty else { return }
        let snapshotter = scrollbackSnapshotter
        let scrollback = scrollbackStore
        guard snapshotter != nil || scrollback != nil else { return }
        let operationID = UUIDv7.generate()
        scrollbackRetirementTasksByID[operationID] = Task { [weak self] in
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
            self?.scrollbackRetirementTasksByID.removeValue(forKey: operationID)
        }
    }

    @concurrent nonisolated private static func retireScrollbackSnapshots(
        _ paneIDs: Set<UUID>, using scrollback: ScrollbackStore
    ) async throws {
        try await scrollback.retire(paneIds: Set(paneIDs.map { PaneId(existingUUID: $0) }))
    }
}
