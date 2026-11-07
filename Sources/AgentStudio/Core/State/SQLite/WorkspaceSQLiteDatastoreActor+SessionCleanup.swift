import Foundation

extension WorkspaceSQLiteDatastoreActor {
    package func stopPendingIncompatibleTerminalSession(
        sessionID: ZmxSessionID, identity: Data?, operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withWorkspacePersistenceOrder { datastore in
            try datastore.requireJournalMutationAdmission()
            let repository = try datastore.journalRepository()
            guard try repository.terminalSessionIsPending(sessionID, identity: identity),
                try repository.terminalSessionProtocolVersion(sessionID) != ZmxProtocol.version
            else { return }
            do {
                try await operation()
                _ = try repository.completeTerminalSessionCleanup(
                    sessionID: sessionID, expectedIdentity: identity, completedAt: Date())
            } catch let failure as ZmxSessionControlFailure {
                try repository.recordTerminalSessionCleanupFailure(
                    sessionID: sessionID, expectedIdentity: identity, failure: failure)
                throw failure
            }
        }
    }

    package func pruneCompletedHistoryBatch() async throws -> Bool {
        try await withWorkspacePersistenceOrder { datastore in
            try datastore.requireJournalMutationAdmission()
            return try datastore.journalRepository().pruneCompletedHistoryBatch()
        }
    }

    package func terminalSessionCleanupBatch(after sessionID: ZmxSessionID?) async throws
        -> [WorkspaceTerminalSessionCleanupWork]
    {
        try await withWorkspacePersistenceOrder { datastore in
            try datastore.requireJournalMutationAdmission()
            return try datastore.journalRepository().terminalSessionCleanupBatch(after: sessionID)
        }
    }

    /// Preserve the existing ownership order through the bounded observation and its write.
    /// No SQLite transaction is held across the await; the callback must not reenter this writer.
    package func observePendingTerminalSession(
        sessionID: ZmxSessionID, observation: @escaping @Sendable () async throws -> Data?
    ) async throws {
        try await withWorkspacePersistenceOrder { datastore in
            try datastore.requireJournalMutationAdmission()
            let repository = try datastore.journalRepository()
            guard try repository.terminalSessionNeedsIdentity(sessionID) else { return }
            do {
                if let identity = try await observation() {
                    guard try repository.recordTerminalSessionIdentity(sessionID: sessionID, identity: identity) else {
                        throw ZmxSessionControlFailure.invalidIdentity
                    }
                } else {
                    _ = try repository.completeTerminalSessionCleanup(
                        sessionID: sessionID, expectedIdentity: nil, completedAt: Date())
                }
            } catch let failure as ZmxSessionControlFailure {
                try repository.recordTerminalSessionCleanupFailure(
                    sessionID: sessionID, expectedIdentity: nil, failure: failure)
                throw failure
            }
        }
    }

    package func retirePendingTerminalSession(
        sessionID: ZmxSessionID, identity: Data,
        operation: @escaping @Sendable () async throws -> ZmxSessionCleanupStatus
    ) async throws -> ZmxSessionCleanupStatus? {
        try await withWorkspacePersistenceOrder { datastore in
            try datastore.requireJournalMutationAdmission()
            let repository = try datastore.journalRepository()
            guard try repository.terminalSessionIsPending(sessionID, identity: identity) else { return nil }
            do {
                let result = try await operation()
                switch result {
                case .completed:
                    _ = try repository.completeTerminalSessionCleanup(
                        sessionID: sessionID, expectedIdentity: identity, completedAt: Date())
                case .pending:
                    try repository.recordTerminalSessionCleanupFailure(
                        sessionID: sessionID, expectedIdentity: identity, failure: .awaitingProcessExit)
                }
                return result
            } catch let failure as ZmxSessionControlFailure {
                try repository.recordTerminalSessionCleanupFailure(
                    sessionID: sessionID, expectedIdentity: identity, failure: failure)
                throw failure
            }
        }
    }

}
