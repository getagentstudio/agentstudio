import Foundation
import GRDB

package struct SessionsRepository: Sendable {
    let sqliteAccess: any SessionsSQLiteAccess
    package init(sqliteAccess: any SessionsSQLiteAccess) { self.sqliteAccess = sqliteAccess }

    package func applyHook(_ hook: SessionsHookAdmission, commitParticipant: (any SessionsCommitParticipant)? = nil)
        async throws -> SessionsHookCommit
    {
        try await sqliteAccess.write { database in
            let context = try SessionsRepositoryStorage.loadContext(
                database: database,
                query: .bind(
                    paneId: hook.paneId, providerIdentifier: hook.providerIdentifier,
                    providerConversationId: hook.sessionId))
            let (reduction, decision) = SessionsEvidenceReducer.reduceHook(hook, context: context)
            let revision = try SessionsRepositoryStorage.insertHookOperation(
                database: database, hook: hook,
                disposition: decision.disposition, binding: decision.binding)
            try SessionsRepositoryStorage.apply(reduction: reduction, commitRevision: revision, database: database)
            try commitParticipant?.commit(in: database)
            var evidence = reduction.evidenceChanges[0]
            evidence.admissionSequence = revision
            let binding =
                reduction.bindingChanges.last(where: { $0.bindingGenerationId == decision.binding.bindingGenerationId })
                ?? decision.binding
            return .init(
                disposition: decision.disposition, binding: binding,
                endedBindings: reduction.bindingChanges.filter {
                    $0.status == .ended && $0.bindingGenerationId != binding.bindingGenerationId
                }, evidence: evidence, revision: revision)
        }
    }

    package func snapshot(_ query: SessionsSnapshotQuery) async throws -> SessionsSnapshot {
        try await sqliteAccess.read { try SessionsRepositoryStorage.loadSnapshot(database: $0, query: query) }
    }

    package func bindingForProviderConversation(
        paneId: UUID, providerIdentifier: String, providerConversationId: String
    )
        async throws -> SessionsBindingRecord?
    {
        try await sqliteAccess.read {
            try SessionsRepositoryStorage.loadBindingForProviderConversation(
                database: $0, paneId: paneId,
                providerIdentifier: providerIdentifier, providerConversationId: providerConversationId)
        }
    }
}

package enum SessionsRepositoryStorage {}
