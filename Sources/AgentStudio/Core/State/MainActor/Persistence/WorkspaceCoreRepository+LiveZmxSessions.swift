import AgentStudioInfrastructure
import Foundation
import GRDB

extension WorkspaceCoreRepository {
    func persistedPaneIds(workspaceId: UUID) async throws -> Set<UUID> {
        try await databaseWriter.read { database in
            try Set(
                String.fetchAll(
                    database, sql: "SELECT id FROM pane WHERE workspace_id = ?", arguments: [workspaceId.uuidString]
                ).map { value in
                    guard let paneId = UUID(uuidString: value) else {
                        throw WorkspaceUndoJournalFailure.invalidStoredIdentifier
                    }
                    return paneId
                })
        }
    }

}
