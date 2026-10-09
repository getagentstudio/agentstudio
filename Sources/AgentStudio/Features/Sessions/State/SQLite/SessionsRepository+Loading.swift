import Foundation
import GRDB

private struct SessionsLoadedEvidence {
    let records: [SessionsEvidenceRecord]
    let bindingStartRecordIds: Set<UUID>
}

extension SessionsRepositoryStorage {
    fileprivate static func loadConversation(
        database: Database,
        providerIdentifier: String,
        providerConversationId: String
    ) throws -> SessionsConversationRecord? {
        try Row.fetchOne(
            database,
            sql: """
                SELECT * FROM sessions_conversation
                WHERE provider_identifier = ? AND provider_conversation_id = ?
                """,
            arguments: [providerIdentifier, providerConversationId]
        ).map { row in
            SessionsConversationRecord(
                id: try decodeUuid(row["id"]),
                providerIdentifier: row["provider_identifier"],
                providerConversationId: row["provider_conversation_id"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                lastReportedAt: Date(timeIntervalSince1970: row["last_reported_at"])
            )
        }
    }

    static func loadContext(
        database: Database,
        query: SessionsRepositoryContextQuery
    ) throws -> SessionsRepositoryContext {
        let revision = try Int64.fetchOne(database, sql: "SELECT MAX(commit_revision) FROM sessions_operation") ?? 0
        switch query {
        case .bind(let paneId, let providerIdentifier, let providerConversationId):
            // Binding decisions are pane-local; the conversation lookup below supplies only its shared FK identity.
            let bindings = try Row.fetchAll(
                database,
                sql: """
                    SELECT binding.*, conversation.provider_identifier, conversation.provider_conversation_id
                    FROM sessions_pane_binding binding JOIN sessions_conversation conversation ON conversation.id = binding.conversation_id
                    WHERE binding.pane_id = ?
                    ORDER BY CASE binding.status WHEN 'active' THEN 0 ELSE 1 END, binding.committed_revision DESC
                    """, arguments: [paneId.uuidString]
            ).map(decodeBinding)
            return SessionsRepositoryContext(
                revision: revision,
                matchingConversation: try loadConversation(
                    database: database,
                    providerIdentifier: providerIdentifier,
                    providerConversationId: providerConversationId
                ),
                currentBinding: bindings.first,
                bindings: bindings,
                sources: try loadSources(database: database, paneId: paneId),
                // Hook decisions use bindings; `.pane` owns lazy status-history hydration.
                evidence: [],
                bindingStartRecordIds: []
            )
        case .pane(let paneId):
            let bindings = try loadBindings(database: database, paneId: paneId)
            let evidence = try loadEvidence(database: database, paneId: paneId)
            return SessionsRepositoryContext(
                revision: revision,
                matchingConversation: nil,
                currentBinding: bindings.first,
                bindings: bindings,
                sources: try loadSources(database: database, paneId: paneId),
                evidence: evidence.records,
                bindingStartRecordIds: evidence.bindingStartRecordIds
            )

        }
    }
}

extension SessionsRepositoryStorage {
    fileprivate static func loadBindings(database: Database, paneId: UUID) throws -> [SessionsBindingRecord] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT binding.*, conversation.provider_identifier, conversation.provider_conversation_id
                FROM sessions_pane_binding AS binding
                JOIN sessions_operation AS operation ON operation.commit_revision = binding.committed_revision
                JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                WHERE binding.pane_id = ?
                ORDER BY CASE binding.status WHEN 'active' THEN 0 ELSE 1 END,
                         binding.committed_revision DESC,
                         CASE WHEN binding.binding_generation_id = operation.binding_generation_id THEN 0 ELSE 1 END,
                         binding.binding_generation_id ASC
                """,
            arguments: [paneId.uuidString]
        ).map(decodeBinding)
    }

    /// The pane's binding for one provider conversation, whether that binding
    /// is still the current generation or one that has since been retired.
    ///
    /// A current-context read cannot say which
    /// binding a delayed provider event belongs to. Ordering matches
    /// `loadBindings`, so a conversation that bound the same pane more than once
    /// resolves to the same generation either read would name first.
    static func loadBindingForProviderConversation(
        database: Database,
        paneId: UUID,
        providerIdentifier: String,
        providerConversationId: String
    ) throws -> SessionsBindingRecord? {
        try Row.fetchOne(
            database,
            sql: """
                SELECT binding.*, conversation.provider_identifier, conversation.provider_conversation_id
                FROM sessions_pane_binding AS binding
                JOIN sessions_operation AS operation ON operation.commit_revision = binding.committed_revision
                JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                WHERE binding.pane_id = ?
                  AND conversation.provider_identifier = ?
                  AND conversation.provider_conversation_id = ?
                ORDER BY CASE binding.status WHEN 'active' THEN 0 ELSE 1 END,
                         binding.committed_revision DESC,
                         CASE WHEN binding.binding_generation_id = operation.binding_generation_id THEN 0 ELSE 1 END,
                         binding.binding_generation_id ASC
                LIMIT 1
                """,
            arguments: [paneId.uuidString, providerIdentifier, providerConversationId]
        ).map(decodeBinding)
    }

    fileprivate static func loadSources(database: Database, paneId: UUID) throws -> [SessionsSourceRecord] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT source.*
                FROM sessions_source AS source
                JOIN sessions_pane_binding AS binding
                  ON binding.binding_generation_id = source.binding_generation_id
                WHERE binding.pane_id = ?
                ORDER BY source.started_at, source.id
                """,
            arguments: [paneId.uuidString]
        ).map(decodeSource)
    }

    private static func loadEvidence(database: Database, paneId: UUID) throws -> SessionsLoadedEvidence {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT evidence.*, operation.operation_kind AS admission_operation_kind
                FROM sessions_evidence AS evidence
                JOIN sessions_pane_binding AS binding
                  ON binding.binding_generation_id = evidence.binding_generation_id
                JOIN sessions_operation AS operation
                  ON operation.commit_revision = evidence.committed_revision
                WHERE binding.pane_id = ?
                ORDER BY evidence.admission_sequence IS NOT NULL,
                         evidence.admission_sequence,
                         evidence.occurred_at, evidence.occurrence_id
                """,
            arguments: [paneId.uuidString]
        )
        var bindingStartRecordIds = Set<UUID>()
        let records = try rows.map { row in
            let record = try decodeEvidence(row, database: database)
            let operationKind: String = row["admission_operation_kind"]
            if record.providerSignal == .sessionStart, operationKind == "bind" {
                bindingStartRecordIds.insert(record.recordId)
            }
            return record
        }
        return .init(records: records, bindingStartRecordIds: bindingStartRecordIds)
    }
}
