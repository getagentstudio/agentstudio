import Foundation

extension WorkspaceSQLiteDatastoreActor: ScrollbackPaneBindingReading {
    package func scrollbackPaneBindings(workspaceID: UUID) async throws -> [ScrollbackPaneBinding] {
        try await withWorkspacePersistenceOrder(cancelBeforeAdmission: true) { datastore in
            try await datastore.journalRepository().scrollbackPaneBindings(workspaceID: workspaceID)
        }
    }
}
