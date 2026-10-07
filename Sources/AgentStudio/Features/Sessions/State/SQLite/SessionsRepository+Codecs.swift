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
        let kind: SessionsEvidenceKind
        switch evidenceKind {
        case "activityStarted": kind = .activityStarted
        case "completed": kind = .completed
        case "aborted": kind = .aborted
        case "needsYouOpened": kind = .needsYouOpened
        case "needsYouResolved": kind = .needsYouResolved
        default:
            throw SessionsRepositoryError.invalidStoredValue(evidenceKind)
        }
        return SessionsEvidenceRecord(
            recordId: try decodeUuid(row["occurrence_id"]),
            conversationId: try decodeUuid(row["conversation_id"]),
            bindingGenerationId: try decodeUuid(row["binding_generation_id"]),
            sourceGenerationId: try decodeUuid(row["source_generation_id"]),
            turnId: row["turn_id"],
            subject: try decodeSubject(kind: row["subject_kind"], identifier: row["subject_identifier"]),
            kind: kind,
            origin: try decodeEnum(row["origin"], as: SessionsEvidenceOrigin.self),
            statusEffect: try decodeEnum(row["status_effect"], as: SessionsEvidenceStatusEffect.self),
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
            admissionSequence: row["admission_sequence"],
            providerSignal: try decodeProviderSignal(row, database: database)
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
}
