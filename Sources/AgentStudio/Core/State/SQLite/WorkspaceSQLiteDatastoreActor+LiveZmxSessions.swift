import Foundation

extension WorkspaceSQLiteDatastoreActor {
    package func persistedPaneIds(workspaceId: UUID) async throws -> Set<UUID> {
        try await journalRepository().persistedPaneIds(workspaceId: workspaceId)
    }

    /// Reads the last persisted graph; membership can trail in-memory edits until their persistence flush.
    package func liveZmxSessionsByPane(workspaceId: UUID) async throws -> [UUID: ZmxSessionID] {
        try await journalRepository().liveZmxSessionsByPane(workspaceId: workspaceId)
    }
}
