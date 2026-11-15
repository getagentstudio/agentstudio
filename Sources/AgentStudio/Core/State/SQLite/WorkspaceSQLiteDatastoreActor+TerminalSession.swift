import Foundation

extension WorkspaceSQLiteDatastoreActor {
    package func terminalSessionProtocolVersion(_ sessionID: ZmxSessionID) async throws -> UInt8? {
        try await withWorkspacePersistenceOrder(cancelBeforeAdmission: true) { datastore in
            try datastore.journalRepository().terminalSessionProtocolVersion(sessionID)
        }
    }

    package func recordTerminalSessionProtocolVersion(_ sessionID: ZmxSessionID, version: UInt8) async throws {
        try await withWorkspacePersistenceOrder { datastore in
            try datastore.requireJournalMutationAdmission()
            try datastore.journalRepository().recordTerminalSessionProtocolVersion(sessionID, version: version)
        }
    }

    package func terminalSessionID(for paneId: UUID) async throws -> ZmxSessionID? {
        try await withWorkspacePersistenceOrder(cancelBeforeAdmission: true) { datastore in
            try await datastore.journalRepository().terminalSessionID(for: paneId)
        }
    }
}
