import Foundation

extension WorkspaceSQLiteDatastoreActor {
    /// Reads the last persisted graph; membership can trail in-memory edits until their persistence flush.
    package func liveZmxSessionsByPane(workspaceId: UUID) async throws -> [UUID: ZmxSessionID] {
        try await journalRepository().liveZmxSessionsByPane(workspaceId: workspaceId)
    }
}
