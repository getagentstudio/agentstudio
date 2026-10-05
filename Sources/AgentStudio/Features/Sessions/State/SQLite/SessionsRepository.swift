import Foundation
import GRDB

package struct SessionsRepository: Sendable {
    private let sqliteAccess: any SessionsSQLiteAccess

    package init(sqliteAccess: any SessionsSQLiteAccess) {
        self.sqliteAccess = sqliteAccess
    }

    package func apply(
        operation: SessionsRepositoryOperation,
        commitParticipant: (any SessionsCommitParticipant)? = nil,
        reducing: @Sendable (SessionsRepositoryContext) throws -> SessionsRepositoryReduction
    ) async throws -> SessionsSubmissionResult {
        try await sqliteAccess.write { database in
            if let replay = try SessionsRepositoryStorage.loadOperationReplay(
                database: database,
                operation: operation
            ) {
                try commitParticipant?.commit(in: database)
                return SessionsSubmissionResult(outcome: replay, disposition: .replayed)
            }
            if let replay = try SessionsRepositoryStorage.loadOccurrenceReplay(
                database: database,
                operation: operation
            ) {
                try commitParticipant?.commit(in: database)
                return SessionsSubmissionResult(outcome: replay, disposition: .replayed)
            }
            let context = try SessionsRepositoryStorage.loadContext(
                database: database,
                query: operation.contextQuery
            )
            let reduction = try reducing(context)
            let commitRevision = try SessionsRepositoryStorage.insertOperation(
                database: database,
                operation: operation,
                outcome: reduction.outcome
            )
            try SessionsRepositoryStorage.apply(
                reduction: reduction,
                commitRevision: commitRevision,
                database: database
            )
            try commitParticipant?.commit(in: database)
            return SessionsSubmissionResult(outcome: reduction.outcome, disposition: .inserted)
        }
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

enum SessionsRepositoryStorage {}
