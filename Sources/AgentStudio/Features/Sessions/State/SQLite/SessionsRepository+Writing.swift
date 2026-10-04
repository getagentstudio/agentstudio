import Foundation
import GRDB

extension SessionsRepositoryStorage {
    static func apply(
        reduction: SessionsRepositoryReduction,
        commitRevision: Int64,
        database: Database
    ) throws {
        for conversation in reduction.conversationChanges {
            try write(conversation: conversation, commitRevision: commitRevision, database: database)
        }
        for binding in reduction.bindingChanges {
            try write(binding: binding, commitRevision: commitRevision, database: database)
        }
        for source in reduction.sourceChanges {
            try write(source: source, commitRevision: commitRevision, database: database)
        }
        for attention in reduction.attentionChanges {
            try write(attention: attention, commitRevision: commitRevision, database: database)
        }

        for evidence in reduction.evidenceChanges {
            try write(evidence: evidence, commitRevision: commitRevision, database: database)
        }
        for result in reduction.resultChanges {
            try write(result: result, commitRevision: commitRevision, database: database)
        }

        for loss in reduction.lossChanges {
            try database.execute(
                sql: """
                    INSERT INTO sessions_loss(
                        id, pane_id, conversation_id, binding_generation_id,
                        source_generation_id, provider_identifier, event_kind,
                        outcome_kind, reason_code, lost_count, occurred_at,
                        committed_revision
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'throttled', ?, 1, ?, ?)
                    """,
                arguments: [
                    loss.id.uuidString,
                    loss.paneId.uuidString,
                    loss.conversationId?.uuidString,
                    loss.bindingGenerationId?.uuidString,
                    loss.sourceGenerationId?.uuidString,
                    loss.providerIdentifier,
                    loss.eventKind,
                    loss.reason.rawValue,
                    loss.occurredAt.timeIntervalSince1970,
                    commitRevision,
                ]
            )
        }
    }
}

extension SessionsRepositoryStorage {
    fileprivate static func write(
        conversation: SessionsConversationRecord,
        commitRevision: Int64,
        database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO sessions_conversation(
                    id, provider_identifier, provider_conversation_id, created_at, last_reported_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(provider_identifier, provider_conversation_id) DO UPDATE SET
                    last_reported_at = MAX(last_reported_at, excluded.last_reported_at)
                """,
            arguments: [
                conversation.id.uuidString,
                conversation.providerIdentifier,
                conversation.providerConversationId,
                conversation.createdAt.timeIntervalSince1970,
                conversation.lastReportedAt.timeIntervalSince1970,
            ]
        )
    }

    fileprivate static func write(
        binding: SessionsBindingRecord,
        commitRevision: Int64,
        database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO sessions_pane_binding(
                    binding_generation_id, pane_id, conversation_id, source_generation_id,
                    origin, status, transition_occurrence_id, started_at, ended_at,
                    committed_revision, resume_hint, owner_pane_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(binding_generation_id) DO UPDATE SET
                    status = excluded.status,
                    ended_at = excluded.ended_at,
                    committed_revision = excluded.committed_revision
                """,
            arguments: [
                binding.bindingGenerationId.uuidString,
                binding.paneId.uuidString,
                binding.conversationId.uuidString,
                binding.sourceGenerationId.uuidString,
                binding.origin.rawValue,
                binding.status.rawValue,
                binding.transitionOccurrenceId.uuidString,
                binding.startedAt.timeIntervalSince1970,
                binding.endedAt?.timeIntervalSince1970,
                commitRevision,
                binding.resumeHint,
                binding.ownerPaneId?.uuidString,
            ]
        )
    }

    fileprivate static func write(
        source: SessionsSourceRecord,
        commitRevision: Int64,
        database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO sessions_source(
                    id, binding_generation_id, source_identifier, source_generation_id,
                    provider_identifier, provider_version, provider_mode, qualification,
                    status, last_cursor, started_at, ended_at, committed_revision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    status = excluded.status,
                    last_cursor = excluded.last_cursor,
                    ended_at = excluded.ended_at,
                    committed_revision = excluded.committed_revision
                """,
            arguments: [
                source.id.uuidString,
                source.bindingGenerationId.uuidString,
                source.sourceIdentifier,
                source.sourceGenerationId.uuidString,
                source.providerIdentifier,
                source.providerVersion,
                source.providerMode,
                source.qualification,
                source.status.rawValue,
                source.lastCursor,
                source.startedAt.timeIntervalSince1970,
                source.endedAt?.timeIntervalSince1970,
                commitRevision,
            ]
        )
    }

    fileprivate static func write(
        attention: SessionsStoredAttentionRecord,
        commitRevision: Int64,
        database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO sessions_attention(
                    id, conversation_id, binding_generation_id, source_id,
                    source_generation_id, source_kind, turn_id, subject_key, request_id,
                    attention_kind, origin, freshness, explanation_text, disposition,
                    opened_occurrence_id, resolution_occurrence_id, opened_at, resolved_at,
                    committed_revision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    explanation_text = excluded.explanation_text,
                    disposition = excluded.disposition,
                    opened_occurrence_id = excluded.opened_occurrence_id,
                    resolution_occurrence_id = excluded.resolution_occurrence_id,
                    opened_at = excluded.opened_at,
                    resolved_at = excluded.resolved_at,
                    committed_revision = excluded.committed_revision
                """,
            arguments: [
                attention.id.uuidString,
                attention.conversationId.uuidString,
                attention.bindingGenerationId.uuidString,
                attention.sourceId?.uuidString,
                attention.sourceGenerationId.uuidString,
                attention.sourceKind,
                attention.turnId,
                attention.subject.storageKey,
                attention.requestId,
                attention.attentionKind,
                attention.origin.rawValue,
                attention.freshness.rawValue,
                attention.explanation,
                attention.disposition.rawValue,
                attention.openedOccurrenceId.uuidString,
                attention.resolutionOccurrenceId?.uuidString,
                attention.openedAt.timeIntervalSince1970,
                attention.resolvedAt?.timeIntervalSince1970,
                commitRevision,
            ]
        )
    }

    fileprivate static func write(
        evidence: SessionsEvidenceRecord,
        commitRevision: Int64,
        database: Database
    ) throws {
        let sourceId = try String.fetchOne(
            database,
            sql: "SELECT id FROM sessions_source WHERE source_generation_id = ?",
            arguments: [evidence.sourceGenerationId.uuidString]
        )
        let attentionId: String?
        switch evidence.kind {
        case .needsYouOpened(let requestId, _), .needsYouResolved(let requestId):
            attentionId = try String.fetchOne(
                database,
                sql: """
                    SELECT id FROM sessions_attention
                    WHERE binding_generation_id = ?
                      AND source_generation_id = ?
                      AND turn_id IS ?
                      AND subject_key = ?
                      AND request_id = ?
                    """,
                arguments: [
                    evidence.bindingGenerationId.uuidString,
                    evidence.sourceGenerationId.uuidString,
                    evidence.turnId,
                    evidence.subject.storageKey,
                    requestId,
                ]
            )
        case .activityStarted, .completed, .aborted:
            attentionId = nil
        }
        try database.execute(
            sql: """
                INSERT INTO sessions_evidence(
                    occurrence_id, conversation_id, binding_generation_id, source_id,
                    source_generation_id, turn_id, subject_kind, subject_identifier,
                    evidence_kind, attention_id, origin, freshness, occurred_at,
                    committed_revision, admission_sequence, source_occurred_at,
                    provider_event, tool_name, tool_call_id, failure_summary,
                    elicitation_id, prompt_summary, has_questions, permission_handling
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(occurrence_id) DO NOTHING
                """,
            arguments: [
                evidence.occurrenceId.uuidString,
                evidence.conversationId.uuidString,
                evidence.bindingGenerationId.uuidString,
                sourceId,
                evidence.sourceGenerationId.uuidString,
                evidence.turnId,
                evidence.subject.kind,
                evidence.subject.identifier,
                evidence.kind.storageKind,
                attentionId,
                evidence.origin.rawValue,
                evidence.freshness.rawValue,
                evidence.occurredAt.timeIntervalSince1970,
                commitRevision,
                commitRevision,
                evidence.sourceOccurredAt?.timeIntervalSince1970,
                evidence.providerSignal?.name.rawValue,
                evidence.providerSignal?.toolName,
                evidence.providerSignal?.toolCallId,
                evidence.providerSignal?.failureSummary,
                evidence.providerSignal?.elicitationId,
                evidence.providerSignal?.summary,
                evidence.providerSignal?.questions == nil ? 0 : 1,
                evidence.providerSignal?.permissionHandling?.rawValue,
            ]
        )
        try writeProviderQuestions(evidence: evidence, database: database)
    }

    fileprivate static func write(
        result: SessionsResultRecord,
        commitRevision: Int64,
        database: Database
    ) throws {
        let sourceId = try String.fetchOne(
            database,
            sql: "SELECT id FROM sessions_source WHERE source_generation_id = ?",
            arguments: [result.sourceGenerationId.uuidString]
        )
        try database.execute(
            sql: """
                INSERT INTO sessions_result(
                    id, conversation_id, binding_generation_id, source_id,
                    source_generation_id, turn_id, subject_key, completion_occurrence_id,
                    origin, freshness, is_seen, seen_at, created_at, updated_at,
                    committed_revision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(binding_generation_id, turn_id, subject_key) DO UPDATE SET
                    completion_occurrence_id = excluded.completion_occurrence_id,
                    origin = excluded.origin,
                    freshness = excluded.freshness,
                    updated_at = excluded.updated_at,
                    committed_revision = excluded.committed_revision
                """,
            arguments: [
                result.id.uuidString,
                result.conversationId.uuidString,
                result.bindingGenerationId.uuidString,
                sourceId,
                result.sourceGenerationId.uuidString,
                result.turnId,
                result.subject.storageKey,
                result.completionOccurrenceId.uuidString,
                result.origin.rawValue,
                result.freshness.rawValue,
                result.disposition == .seen ? 1 : 0,
                result.seenAt?.timeIntervalSince1970,
                result.createdAt.timeIntervalSince1970,
                result.updatedAt.timeIntervalSince1970,
                commitRevision,
            ]
        )
    }
}
