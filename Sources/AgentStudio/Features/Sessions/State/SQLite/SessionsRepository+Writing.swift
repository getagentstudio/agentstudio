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

        for evidence in reduction.evidenceChanges {
            try write(evidence: evidence, commitRevision: commitRevision, database: database)
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
                    provider_version = excluded.provider_version,
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
        evidence: SessionsEvidenceRecord,
        commitRevision: Int64,
        database: Database
    ) throws {
        let sourceId = try String.fetchOne(
            database,
            sql: "SELECT id FROM sessions_source WHERE source_generation_id = ?",
            arguments: [evidence.sourceGenerationId.uuidString]
        )
        try database.execute(
            sql: """
                INSERT INTO sessions_evidence(
                    occurrence_id, conversation_id, binding_generation_id, source_id,
                    source_generation_id, turn_id, subject_kind, subject_identifier,
                    evidence_kind, origin, status_effect, occurred_at,
                    committed_revision, admission_sequence,
                    provider_event, tool_name, tool_call_id, failure_summary,
                    elicitation_id, prompt_summary, has_questions
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                evidence.recordId.uuidString,
                evidence.conversationId.uuidString,
                evidence.bindingGenerationId.uuidString,
                sourceId,
                evidence.sourceGenerationId.uuidString,
                evidence.turnId,
                evidence.subject.kind,
                evidence.subject.identifier,
                evidence.kind.storageKind,
                evidence.origin.rawValue,
                evidence.statusEffect.rawValue,
                evidence.occurredAt.timeIntervalSince1970,
                commitRevision,
                commitRevision,
                evidence.providerSignal?.name.rawValue,
                evidence.providerSignal?.toolName,
                evidence.providerSignal?.toolCallId,
                evidence.providerSignal?.failureSummary,
                evidence.providerSignal?.elicitationId,
                evidence.providerSignal?.summary,
                evidence.providerSignal?.questions == nil ? 0 : 1,
            ]
        )
        try writeProviderQuestions(evidence: evidence, database: database)
    }
}
