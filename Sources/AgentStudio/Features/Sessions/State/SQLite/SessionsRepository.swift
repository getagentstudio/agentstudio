import Foundation
import GRDB

package struct SessionsRepository: Sendable {
    let sqliteAccess: any SessionsSQLiteAccess
    package init(sqliteAccess: any SessionsSQLiteAccess) { self.sqliteAccess = sqliteAccess }

    package func applyHook(
        _ hook: SessionsHookAdmission,
        commitParticipant: (any SessionsCommitParticipant)? = nil,
        confirmedLiveBindingIds: Set<UUID>? = nil
    )
        async throws -> SessionsHookOutcome
    {
        try await sqliteAccess.write { database in
            let context = try SessionsRepositoryStorage.loadContext(
                database: database,
                query: .bind(
                    paneId: hook.paneId, providerIdentifier: hook.providerIdentifier,
                    providerConversationId: hook.sessionId))
            let confirmedLiveMain: Bool
            if let liveMain = context.bindings.first(where: { $0.status == .active }) {
                confirmedLiveMain = confirmedLiveBindingIds?.contains(liveMain.bindingGenerationId) ?? true
            } else {
                confirmedLiveMain = false
            }
            let (reduction, decision) = SessionsEvidenceReducer.reduceHook(
                hook, context: context, confirmedLiveMain: confirmedLiveMain)
            guard let reduction,
                case .accepted(let decisionBinding, let disposition, let supersededBinding) = decision
            else { return .ignored }
            let revision = try SessionsRepositoryStorage.insertHookOperation(
                database: database, hook: hook,
                disposition: disposition, binding: decisionBinding)
            try SessionsRepositoryStorage.apply(reduction: reduction, commitRevision: revision, database: database)
            try commitParticipant?.commit(in: database)
            var evidence = reduction.evidenceChanges[0]
            evidence.admissionSequence = revision
            let binding =
                reduction.bindingChanges.last(where: {
                    $0.bindingGenerationId == decisionBinding.bindingGenerationId
                }) ?? decisionBinding
            return .committed(
                .init(
                    disposition: disposition, binding: binding,
                    supersededBinding: supersededBinding, evidence: evidence, revision: revision))
        }
    }

    package func endLiveBinding(
        expectedBinding: SessionsBindingRecord, endedAt: Date
    ) async throws -> SessionsBindingEndCommit? {
        try await sqliteAccess.write { database in
            let context = try SessionsRepositoryStorage.loadContext(
                database: database,
                query: .bind(
                    paneId: expectedBinding.paneId,
                    providerIdentifier: expectedBinding.providerIdentifier,
                    providerConversationId: expectedBinding.providerConversationId))
            guard let binding = context.bindings.first(where: { $0.status == .active }),
                binding.bindingGenerationId == expectedBinding.bindingGenerationId
            else { return nil }
            guard
                let source = context.sources.first(where: {
                    $0.bindingGenerationId == binding.bindingGenerationId && $0.status == .active
                })
            else { throw SessionsRepositoryError.invalidStoredValue("active binding source") }

            let endedBinding = SessionsEvidenceReducer.replacing(binding, status: .ended, endedAt: endedAt)
            let endedSource = SessionsEvidenceReducer.replacing(source, status: .ended, endedAt: endedAt)
            let revision = try SessionsRepositoryStorage.insertCommandFinishedOperation(
                database: database, paneId: expectedBinding.paneId, binding: binding, endedAt: endedAt)
            try SessionsRepositoryStorage.apply(
                reduction: .init(bindingChanges: [endedBinding], sourceChanges: [endedSource], outcome: .applied),
                commitRevision: revision, database: database)
            return .init(binding: endedBinding, revision: revision, endedAt: endedAt)
        }
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
