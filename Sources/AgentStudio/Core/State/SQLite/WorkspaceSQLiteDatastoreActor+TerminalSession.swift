import Foundation

extension WorkspaceSQLiteDatastoreActor {
    package func terminalSessionID(for paneId: UUID) async throws -> ZmxSessionID? {
        try await withWorkspacePersistenceOrder(cancelBeforeAdmission: true) { datastore in
            try await datastore.journalRepository().terminalSessionID(for: paneId)
        }
    }
}
