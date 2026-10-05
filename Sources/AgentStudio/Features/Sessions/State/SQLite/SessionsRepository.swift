import Foundation
import GRDB

package struct SessionsRepository: Sendable {
    let sqliteAccess: any SessionsSQLiteAccess

    package init(sqliteAccess: any SessionsSQLiteAccess) {
        self.sqliteAccess = sqliteAccess
    }

    package func apply(
        operation: SessionsRepositoryOperation,
        commitParticipant: (any SessionsCommitParticipant)? = nil,
        reducing: @Sendable (SessionsRepositoryContext) throws -> SessionsRepositoryReduction
    ) async throws -> SessionsSubmissionResult {
        try await sqliteAccess.write { database in
            let result = try Self.applyInTransaction(database: database, operation: operation, reducing: reducing)
            try commitParticipant?.commit(in: database)
            return result
        }
    }

    static func loadReplay(
        database: Database, operation: SessionsRepositoryOperation
    ) throws -> SessionsSubmissionResult? {
        if let outcome = try SessionsRepositoryStorage.loadOperationReplay(database: database, operation: operation) {
            return .init(outcome: outcome, disposition: .replayed)
        }
        if let outcome = try SessionsRepositoryStorage.loadOccurrenceReplay(database: database, operation: operation) {
            return .init(outcome: outcome, disposition: .replayed)
        }
        return nil
    }

    static func applyInTransaction(
        database: Database, operation: SessionsRepositoryOperation,
        reducing: @Sendable (SessionsRepositoryContext) throws -> SessionsRepositoryReduction
    ) throws -> SessionsSubmissionResult {
        if let replay = try loadReplay(database: database, operation: operation) { return replay }
        return try applyNewOperation(database: database, operation: operation, reducing: reducing)
    }

    static func applyNewOperation(
        database: Database, operation: SessionsRepositoryOperation,
        reducing: @Sendable (SessionsRepositoryContext) throws -> SessionsRepositoryReduction
    ) throws -> SessionsSubmissionResult {
        let context = try SessionsRepositoryStorage.loadContext(database: database, query: operation.contextQuery)
        let reduction = try reducing(context)
        let revision = try SessionsRepositoryStorage.insertOperation(
            database: database, operation: operation, outcome: reduction.outcome)
        try SessionsRepositoryStorage.apply(reduction: reduction, commitRevision: revision, database: database)
        return .init(outcome: reduction.outcome, disposition: .inserted, commitRevision: revision)
    }

    package func snapshot(_ query: SessionsSnapshotQuery) async throws -> SessionsSnapshot {
        try await sqliteAccess.read { database in
            try SessionsRepositoryStorage.loadSnapshot(database: database, query: query)
        }
    }

    /// One pane binding addressed by the conversation that opened it, which a
    /// snapshot cannot answer: it carries the current generation only, and a
    /// delayed provider event names the generation it was written against.
    package func bindingForProviderConversation(
        paneId: UUID,
        providerIdentifier: String,
        providerConversationId: String
    ) async throws -> SessionsBindingRecord? {
        try await sqliteAccess.read { database in
            try SessionsRepositoryStorage.loadBindingForProviderConversation(
                database: database,
                paneId: paneId,
                providerIdentifier: providerIdentifier,
                providerConversationId: providerConversationId
            )
        }
    }
}

package enum SessionsRepositoryStorage {}
