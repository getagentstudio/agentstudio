import Foundation
import GRDB

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
            let bindings = try loadBindings(database: database, paneId: paneId)
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
                evidence: try loadEvidence(database: database, paneId: paneId),
                attention: try loadAttention(database: database, paneId: paneId),
                results: try loadResults(database: database, paneId: paneId)
            )
        case .pane(let paneId), .source(let paneId, _):
            let bindings = try loadBindings(database: database, paneId: paneId)
            return SessionsRepositoryContext(
                revision: revision,
                matchingConversation: nil,
                currentBinding: bindings.first,
                bindings: bindings,
                sources: try loadSources(database: database, paneId: paneId),
                evidence: try loadEvidence(database: database, paneId: paneId),
                attention: try loadAttention(database: database, paneId: paneId),
                results: try loadResults(database: database, paneId: paneId)
            )
        case .allActiveSources:
            let bindings = try loadActiveBindings(database: database)
            return SessionsRepositoryContext(
                revision: revision,
                matchingConversation: nil,
                currentBinding: nil,
                bindings: bindings,
                sources: try loadActiveSources(database: database),
                evidence: [],
                attention: try loadActiveAttention(database: database),
                results: []
            )
        }
    }

    static func loadSnapshot(database: Database, query: SessionsSnapshotQuery) throws -> SessionsSnapshot {
        let paneId: UUID
        switch query {
        case .pane(let identifier): paneId = identifier
        }
        let context = try loadContext(database: database, query: .pane(paneId))
        let historicalEvidence: [SessionsEvidenceRecord]
        if let binding = context.currentBinding {
            let activeSources = Set(context.sources.filter { $0.status == .active }.map(\.sourceGenerationId))
            let endedSources = Set(context.sources.filter { $0.status != .active }.map(\.sourceGenerationId))
            let currentTurnId = SessionsEvidenceReducer.currentTurnId(
                evidence: context.evidence, bindingGenerationId: binding.bindingGenerationId,
                activeSourceGenerationIds: activeSources)
            historicalEvidence = context.evidence.sorted(by: SessionsEvidenceReducer.evidenceOrder).filter {
                $0.conversationId != binding.conversationId
                    || $0.bindingGenerationId != binding.bindingGenerationId
                    || $0.freshness != .live
                    || endedSources.contains($0.sourceGenerationId)
                    || (currentTurnId != nil && $0.turnId != currentTurnId)
            }
        } else {
            historicalEvidence = context.evidence.filter { $0.freshness != .live }
        }
        return SessionsSnapshot(
            revision: context.revision, currentBinding: context.currentBinding,
            staleAttention: context.attention.filter { $0.disposition == .stale }.map { attention in
                SessionsAttentionProjection(
                    id: attention.id, requestId: attention.requestId, explanation: attention.explanation,
                    sourceGenerationId: attention.sourceGenerationId, turnId: attention.turnId,
                    subject: attention.subject, origin: attention.origin, freshness: attention.freshness,
                    disposition: attention.disposition, openedOccurrenceId: attention.openedOccurrenceId,
                    openedAt: attention.openedAt)
            },
            results: context.results,
            historicalOccurrenceIds: historicalEvidence.map(\.occurrenceId),
            losses: try loadLosses(database: database, paneId: paneId))
    }

}

extension SessionsRepositoryStorage {
    fileprivate static func loadBindings(database: Database, paneId: UUID) throws -> [SessionsBindingRecord] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT binding.*, conversation.provider_identifier, conversation.provider_conversation_id
                FROM sessions_pane_binding AS binding
                JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                WHERE binding.pane_id = ?
                ORDER BY CASE binding.status WHEN 'active' THEN 0 ELSE 1 END,
                         binding.committed_revision DESC,
                         binding.binding_generation_id ASC
                """,
            arguments: [paneId.uuidString]
        ).map(decodeBinding)
    }

    /// The pane's binding for one provider conversation, whether that binding
    /// is still the current generation or one that has since been retired.
    ///
    /// A snapshot carries only the current binding, which cannot say which
    /// generation a delayed provider event belongs to. Ordering matches
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
                JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                WHERE binding.pane_id = ?
                  AND conversation.provider_identifier = ?
                  AND conversation.provider_conversation_id = ?
                ORDER BY CASE binding.status WHEN 'active' THEN 0 ELSE 1 END,
                         binding.committed_revision DESC,
                         binding.binding_generation_id ASC
                LIMIT 1
                """,
            arguments: [paneId.uuidString, providerIdentifier, providerConversationId]
        ).map(decodeBinding)
    }

    fileprivate static func loadActiveBindings(database: Database) throws -> [SessionsBindingRecord] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT binding.*, conversation.provider_identifier, conversation.provider_conversation_id
                FROM sessions_pane_binding AS binding
                JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                WHERE binding.status = 'active'
                ORDER BY binding.pane_id, binding.started_at
                """
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

    fileprivate static func loadActiveSources(database: Database) throws -> [SessionsSourceRecord] {
        try Row.fetchAll(
            database,
            sql: "SELECT * FROM sessions_source WHERE status = 'active' ORDER BY started_at, id"
        ).map(decodeSource)
    }

    fileprivate static func loadEvidence(database: Database, paneId: UUID) throws -> [SessionsEvidenceRecord] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT evidence.*,
                       attention.request_id AS evidence_request_id,
                       attention.explanation_text AS evidence_explanation_text
                FROM sessions_evidence AS evidence
                JOIN sessions_pane_binding AS binding
                  ON binding.binding_generation_id = evidence.binding_generation_id
                LEFT JOIN sessions_attention AS attention ON attention.id = evidence.attention_id
                WHERE binding.pane_id = ?
                ORDER BY evidence.admission_sequence IS NOT NULL,
                         evidence.admission_sequence,
                         evidence.occurred_at, evidence.occurrence_id
                """,
            arguments: [paneId.uuidString]
        ).map { try decodeEvidence($0, database: database) }
    }

    fileprivate static func loadAttention(database: Database, paneId: UUID) throws -> [SessionsStoredAttentionRecord] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT attention.*
                FROM sessions_attention AS attention
                JOIN sessions_pane_binding AS binding
                  ON binding.binding_generation_id = attention.binding_generation_id
                WHERE binding.pane_id = ?
                ORDER BY attention.opened_at, attention.id
                """,
            arguments: [paneId.uuidString]
        ).map(decodeAttention)
    }

    fileprivate static func loadActiveAttention(database: Database) throws -> [SessionsStoredAttentionRecord] {
        try Row.fetchAll(
            database,
            sql: "SELECT * FROM sessions_attention WHERE disposition = 'current' ORDER BY opened_at, id"
        ).map(decodeAttention)
    }

    fileprivate static func loadResults(database: Database, paneId: UUID) throws -> [SessionsResultRecord] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT result.*
                FROM sessions_result AS result
                JOIN sessions_pane_binding AS binding
                  ON binding.binding_generation_id = result.binding_generation_id
                WHERE binding.pane_id = ?
                ORDER BY result.updated_at, result.id
                """,
            arguments: [paneId.uuidString]
        ).map(decodeResult)
    }

    fileprivate static func loadLosses(database: Database, paneId: UUID) throws -> [SessionsLossRecord] {
        try Row.fetchAll(
            database,
            sql: "SELECT * FROM sessions_loss WHERE pane_id = ? ORDER BY occurred_at, id",
            arguments: [paneId.uuidString]
        ).map { row in
            SessionsLossRecord(
                id: try decodeUuid(row["id"]),
                paneId: try decodeUuid(row["pane_id"]),
                conversationId: try decodeOptionalUuid(row["conversation_id"]),
                bindingGenerationId: try decodeOptionalUuid(row["binding_generation_id"]),
                sourceGenerationId: try decodeOptionalUuid(row["source_generation_id"]),
                providerIdentifier: row["provider_identifier"],
                eventKind: row["event_kind"],
                reason: try decodeEnum(row["reason_code"], as: SessionsLossReason.self),
                occurredAt: Date(timeIntervalSince1970: row["occurred_at"])
            )
        }
    }

}
