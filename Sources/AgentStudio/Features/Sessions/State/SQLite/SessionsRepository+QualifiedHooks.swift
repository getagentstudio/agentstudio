import AgentStudioInfrastructure
import Foundation
import GRDB

extension SessionsRepository {
    /// One FIFO entry, one SQLite transaction. The caller's original hook owns
    /// replay authority before its optional bind writes anything. Bind and hook
    /// retain distinct ordered revisions, including replacement followed by End.
    func applyQualifiedHook(
        correlationId: UUID, submission: SessionsQualifiedHookSubmission,
        commitParticipant: (any SessionsCommitParticipant)? = nil
    ) async throws -> SessionsQualifiedHookCommitResult {
        let operation = try submission.repositoryOperation(correlationId: correlationId)
        return try await sqliteAccess.write { database in
            if let replay = try Self.loadReplay(database: database, operation: operation) {
                try commitParticipant?.commit(in: database)
                return .init(result: replay, committedMutations: [])
            }
            let context = try SessionsRepositoryStorage.loadContext(database: database, query: operation.contextQuery)
            let resolution = try submission.resolve(against: context)
            var committed: [SessionsCommittedMutation] = []
            if let bind = resolution.impliedBind {
                let mutation = SessionsMutation.bind(bind)
                let bindOperation = try mutation.repositoryOperation(correlationId: UUIDv7.generate())
                let result = try Self.applyInTransaction(database: database, operation: bindOperation) {
                    try SessionsEvidenceReducer.reduce(mutation: mutation, against: $0)
                }
                committed.append(.init(mutation: mutation, result: result))
            }
            // The first replay check and both reductions share this transaction;
            // nothing can install a competing generation between them. Reloading
            // the context here observes the just-committed binding and revision.
            let result = try Self.applyNewOperation(database: database, operation: operation) {
                try SessionsEvidenceReducer.reduce(mutation: resolution.mutation, against: $0)
            }
            committed.append(.init(mutation: resolution.mutation, result: result))
            try commitParticipant?.commit(in: database)
            return .init(result: result, committedMutations: committed)
        }
    }
}
