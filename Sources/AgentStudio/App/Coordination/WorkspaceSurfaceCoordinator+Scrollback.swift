import AgentStudioInfrastructure
import Foundation
import os.log

extension WorkspaceSurfaceCoordinator {
    /// Pass the existing IDs unchanged; the actor owns conversion,
    /// tombstones, capture cancellation, deletion and its completion facts.
    func submitScrollbackRetirement(_ paneIDs: Set<UUID>) {
        guard let snapshotter = scrollbackSnapshotter, !paneIDs.isEmpty else { return }
        let operationID = UUIDv7.generate()
        scrollbackRetirementTasksByID[operationID] = Task { [weak self] in
            do { try await snapshotter.retire(operationID: operationID, paneUUIDs: paneIDs) } catch {
                // Never include captured data, paths or an OS error payload.
                Self.logger.warning("Scrollback retirement could not delete a snapshot")
            }
            self?.scrollbackRetirementTasksByID.removeValue(forKey: operationID)
        }
    }
}
