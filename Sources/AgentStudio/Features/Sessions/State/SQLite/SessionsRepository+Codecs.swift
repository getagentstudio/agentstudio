import Foundation
import GRDB

extension SessionsRepositoryStorage {
    static func decodeBinding(_ row: Row) throws -> SessionsBindingRecord {
        SessionsBindingRecord(
            bindingGenerationId: try decodeUuid(row["binding_generation_id"]),
            paneId: try decodeUuid(row["pane_id"]),
            conversationId: try decodeUuid(row["conversation_id"]),
            providerIdentifier: row["provider_identifier"],
            providerConversationId: row["provider_conversation_id"],
            sourceGenerationId: try decodeUuid(row["source_generation_id"]),
            transitionOccurrenceId: try decodeUuid(row["transition_occurrence_id"]),
            origin: try decodeEnum(row["origin"], as: SessionsEvidenceOrigin.self),
            status: try decodeEnum(row["status"], as: SessionsBindingStatus.self),
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            endedAt: decodeDate(row["ended_at"]),
            resumeHint: row["resume_hint"],
            ownerPaneId: try decodeOptionalUuid(row["owner_pane_id"])
        )
    }

    static func decodeSource(_ row: Row) throws -> SessionsSourceRecord {
        SessionsSourceRecord(
            id: try decodeUuid(row["id"]),
            bindingGenerationId: try decodeUuid(row["binding_generation_id"]),
            sourceIdentifier: row["source_identifier"],
            sourceGenerationId: try decodeUuid(row["source_generation_id"]),
            providerIdentifier: row["provider_identifier"],
            providerVersion: row["provider_version"],
            providerMode: row["provider_mode"],
            qualification: row["qualification"],
            status: try decodeEnum(row["status"], as: SessionsSourceStatus.self),
            lastCursor: row["last_cursor"],
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            endedAt: decodeDate(row["ended_at"])
        )
    }

    static func decodeEvidence(_ row: Row, database: Database) throws -> SessionsEvidenceRecord {
        let evidenceKind: String = row["evidence_kind"]
        let requestId: String? = row["evidence_request_id"]
        let explanation: String? = row["evidence_explanation_text"]
        let kind: SessionsEvidenceKind
        switch evidenceKind {
        case "activityStarted": kind = .activityStarted
        case "completed": kind = .completed
        case "aborted": kind = .aborted
        case "needsYouOpened":
            guard let requestId else { throw SessionsRepositoryError.invalidStoredValue(evidenceKind) }
            kind = .needsYouOpened(requestId: requestId, explanation: explanation)
        case "needsYouResolved":
            guard let requestId else { throw SessionsRepositoryError.invalidStoredValue(evidenceKind) }
            kind = .needsYouResolved(requestId: requestId)
        default:
            throw SessionsRepositoryError.invalidStoredValue(evidenceKind)
        }
        return SessionsEvidenceRecord(
            occurrenceId: try decodeUuid(row["occurrence_id"]),
            conversationId: try decodeUuid(row["conversation_id"]),
            bindingGenerationId: try decodeUuid(row["binding_generation_id"]),
            sourceGenerationId: try decodeUuid(row["source_generation_id"]),
            turnId: row["turn_id"],
            subject: try decodeSubject(kind: row["subject_kind"], identifier: row["subject_identifier"]),
            kind: kind,
            origin: try decodeEnum(row["origin"], as: SessionsEvidenceOrigin.self),
            freshness: try decodeEnum(row["freshness"], as: SessionsEvidenceFreshness.self),
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
            admissionSequence: row["admission_sequence"],
            sourceOccurredAt: decodeDate(row["source_occurred_at"]),
            providerSignal: try decodeProviderSignal(row, database: database)
        )
    }

    static func decodeAttention(_ row: Row) throws -> SessionsStoredAttentionRecord {
        SessionsStoredAttentionRecord(
            id: try decodeUuid(row["id"]),
            conversationId: try decodeUuid(row["conversation_id"]),
            bindingGenerationId: try decodeUuid(row["binding_generation_id"]),
            sourceId: try decodeOptionalUuid(row["source_id"]),
            sourceGenerationId: try decodeUuid(row["source_generation_id"]),
            sourceKind: row["source_kind"],
            turnId: row["turn_id"],
            subject: try decodeSubjectKey(row["subject_key"]),
            requestId: row["request_id"],
            attentionKind: row["attention_kind"],
            origin: try decodeEnum(row["origin"], as: SessionsEvidenceOrigin.self),
            freshness: try decodeEnum(row["freshness"], as: SessionsEvidenceFreshness.self),
            explanation: row["explanation_text"],
            disposition: try decodeEnum(row["disposition"], as: SessionsAttentionDisposition.self),
            openedOccurrenceId: try decodeUuid(row["opened_occurrence_id"]),
            resolutionOccurrenceId: try decodeOptionalUuid(row["resolution_occurrence_id"]),
            openedAt: Date(timeIntervalSince1970: row["opened_at"]),
            resolvedAt: decodeDate(row["resolved_at"])
        )
    }

    static func decodeResult(_ row: Row) throws -> SessionsResultRecord {
        let isSeen: Int = row["is_seen"]
        return SessionsResultRecord(
            id: try decodeUuid(row["id"]),
            conversationId: try decodeUuid(row["conversation_id"]),
            bindingGenerationId: try decodeUuid(row["binding_generation_id"]),
            sourceGenerationId: try decodeUuid(row["source_generation_id"]),
            turnId: row["turn_id"],
            subject: try decodeSubjectKey(row["subject_key"]),
            completionOccurrenceId: try decodeUuid(row["completion_occurrence_id"]),
            origin: try decodeEnum(row["origin"], as: SessionsEvidenceOrigin.self),
            freshness: try decodeEnum(row["freshness"], as: SessionsEvidenceFreshness.self),
            disposition: isSeen == 0 ? .unseen : .seen,
            seenAt: decodeDate(row["seen_at"]),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    static func decodeUuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw SessionsRepositoryError.invalidStoredValue(value)
        }
        return uuid
    }

    static func decodeOptionalUuid(_ value: String?) throws -> UUID? {
        guard let value else { return nil }
        return try decodeUuid(value)
    }

    static func decodeDate(_ value: Double?) -> Date? {
        value.map(Date.init(timeIntervalSince1970:))
    }

    static func decodeEnum<StoredValue: RawRepresentable>(
        _ rawValue: String,
        as type: StoredValue.Type
    ) throws -> StoredValue where StoredValue.RawValue == String {
        guard let value = StoredValue(rawValue: rawValue) else {
            throw SessionsRepositoryError.invalidStoredValue(rawValue)
        }
        return value
    }

    static func decodeSubject(kind: String, identifier: String?) throws -> SessionsEvidenceSubject {
        switch (kind, identifier) {
        case ("root", nil): .root
        case ("tool", .some(let identifier)): .tool(identifier)
        case ("subagent", .some(let identifier)): .subagent(identifier)
        default: throw SessionsRepositoryError.invalidStoredValue("\(kind):\(identifier ?? "nil")")
        }
    }

    static func decodeSubjectKey(_ key: String) throws -> SessionsEvidenceSubject {
        if key == "root" { return .root }
        if key.hasPrefix("tool:") { return .tool(String(key.dropFirst("tool:".count))) }
        if key.hasPrefix("subagent:") { return .subagent(String(key.dropFirst("subagent:".count))) }
        throw SessionsRepositoryError.invalidStoredValue(key)
    }
}
