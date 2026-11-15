import AgentStudioInfrastructure
import Foundation

extension WorkspaceSQLiteDatastoreActor {
    package func persistedPaneIds(workspaceId: UUID) async throws -> Set<UUID> {
        try await journalRepository().persistedPaneIds(workspaceId: workspaceId)
    }

}
