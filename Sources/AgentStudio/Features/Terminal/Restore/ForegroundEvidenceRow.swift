import AgentStudioCore
import Foundation
import GRDB

/// Reads and writes report kinds in migration 030's retained table.
enum ForegroundEvidenceRow {
    private static let retiredObservationColumns = [
        "zmx_session_id", "program", "identity_version", "boot_id", "daemon_pid", "daemon_start_seconds",
        "daemon_start_microseconds", "leader_pid", "leader_start_seconds", "leader_start_microseconds",
        "process_group_id", "session_created_at",
    ]
    private static let reportedColumns = ["reported_provider", "reported_conversation_id", "unreadable_reason"]
    static func load(paneId: UUID, in database: Database) throws -> PaneForegroundEvidence? {
        guard
            let row = try Row.fetchOne(
                database, sql: "SELECT * FROM terminal_pane_foreground_evidence WHERE pane_id = ?",
                arguments: [paneId.uuidString])
        else { return nil }
        guard let launchText: String = value(row, "observer_launch_id"),
            let launchId = UUID(uuidString: launchText),
            let signedSequence: Int64 = value(row, "sequence"), let sequence = UInt64(exactly: signedSequence),
            let timestamp: String = value(row, "observed_at"),
            let observedAt = timestampFormatter().date(from: timestamp),
            let kind: String = value(row, "evidence_kind")
        else { return nil }
        let rawGeneration: DatabaseValue = row["binding_generation_id"]
        let generation: UUID?
        if rawGeneration.isNull {
            generation = nil
        } else {
            guard let text = String.fromDatabaseValue(rawGeneration), let parsed = UUID(uuidString: text) else {
                return nil
            }
            generation = parsed
        }
        let evidence: ForegroundEvidence
        switch kind {
        case "look": return nil
        case "reportedEnd":
            guard columnsAreNull(retiredObservationColumns + reportedColumns, in: row) else { return nil }
            evidence = .reportedEnd
        case "reportedOtherSessionEnd", "reportedOtherStart":
            guard columnsAreNull(retiredObservationColumns + ["unreadable_reason"], in: row),
                let providerText: String = value(row, "reported_provider"),
                let provider = ResumeProvider(providerIdentifier: providerText),
                let conversation: String = value(row, "reported_conversation_id")
            else { return nil }
            let session = ReportedSession(provider: provider, conversationId: conversation)
            evidence = kind == "reportedOtherStart" ? .reportedOtherStart(session) : .reportedOtherSessionEnd(session)
        case "reportsUnreadable":
            guard
                columnsAreNull(retiredObservationColumns + ["reported_provider", "reported_conversation_id"], in: row),
                let reasonText: String = value(row, "unreadable_reason"),
                let reason = ReportsUnreadableReason(rawValue: reasonText)
            else { return nil }
            evidence = .reportsUnreadable(reason)
        default: return nil
        }
        return .init(
            paneId: paneId, bindingGenerationId: generation, observerLaunchId: launchId, sequence: sequence,
            observedAt: observedAt, value: evidence)
    }

    static func writeReported(
        _ record: PaneForegroundEvidence, in database: Database
    ) throws {
        let kind: String
        var reported: ReportedSession?
        var unreadable: ReportsUnreadableReason?
        switch record.value {
        case .reportedEnd: kind = "reportedEnd"
        case .reportedOtherSessionEnd(let session):
            kind = "reportedOtherSessionEnd"
            reported = session
        case .reportedOtherStart(let session):
            kind = "reportedOtherStart"
            reported = session
        case .reportsUnreadable(let reason):
            kind = "reportsUnreadable"
            unreadable = reason
        }
        let provider = reported.map { $0.provider == .claudeCode ? "claude-code" : "codex" }
        try database.execute(
            sql: """
                INSERT OR REPLACE INTO terminal_pane_foreground_evidence (
                    pane_id,evidence_kind,binding_generation_id,observer_launch_id,sequence,observed_at,
                    reported_provider,reported_conversation_id,unreadable_reason
                ) VALUES (?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                record.paneId.uuidString, kind, record.bindingGenerationId?.uuidString,
                record.observerLaunchId.uuidString,
                Int64(record.sequence), timestampFormatter().string(from: record.observedAt), provider,
                reported?.conversationId, unreadable?.rawValue,
            ])
    }

    private static func value<Value: DatabaseValueConvertible>(_ row: Row, _ name: String) -> Value? {
        Value.fromDatabaseValue(row[name])
    }

    private static func columnsAreNull(_ columns: [String], in row: Row) -> Bool {
        columns.allSatisfy { column in
            let raw: DatabaseValue = row[column]
            return raw.isNull
        }
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
