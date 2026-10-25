import AgentStudioCore
import Foundation
import GRDB

struct ForegroundEvidenceRecord: Sendable {
    let evidence: PaneForegroundEvidence
    let look: PaneForegroundLook?
}

/// The SQLite representation owns typed identity columns; the Core identity stays opaque.
enum ForegroundEvidenceRow {
    private static let lookColumns = [
        "zmx_session_id", "program", "identity_version", "boot_id", "daemon_pid", "daemon_start_seconds",
        "daemon_start_microseconds", "leader_pid", "leader_start_seconds", "leader_start_microseconds",
        "process_group_id", "session_created_at",
    ]
    private static let reportedColumns = ["reported_provider", "reported_conversation_id", "unreadable_reason"]
    static func canStore(identity: ZmxSessionIdentity, sequence: UInt64) -> Bool {
        [
            sequence, identity.daemon.startSeconds, identity.daemon.startMicroseconds,
            identity.terminalLeader.startSeconds, identity.terminalLeader.startMicroseconds,
            identity.sessionCreatedAt,
        ].allSatisfy { Int64(exactly: $0) != nil }
    }

    static func load(paneId: UUID, in database: Database) throws -> ForegroundEvidenceRecord? {
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
        var look: PaneForegroundLook?
        switch kind {
        case "look":
            guard columnsAreNull(reportedColumns, in: row), let sessionText: String = value(row, "zmx_session_id"),
                let session = ZmxSessionID(restoring: sessionText),
                let programText: String = value(row, "program"), let program = ForegroundProgram(rawValue: programText),
                let identity = decodeIdentity(row)
            else { return nil }
            evidence = .look(program, sessionIdentity: identity)
            look = PaneForegroundLook(
                paneId: paneId, zmxSessionId: session, sessionIdentity: identity, bindingGenerationId: generation,
                program: program, observerLaunchId: launchId, sequence: sequence, observedAt: observedAt)
        case "reportedEnd":
            guard columnsAreNull(lookColumns + reportedColumns, in: row) else { return nil }
            evidence = .reportedEnd
        case "reportedOtherSessionEnd", "reportedOtherStart":
            guard columnsAreNull(lookColumns + ["unreadable_reason"], in: row),
                let providerText: String = value(row, "reported_provider"),
                let provider = ResumeProvider(providerIdentifier: providerText),
                let conversation: String = value(row, "reported_conversation_id")
            else { return nil }
            let session = ReportedSession(provider: provider, conversationId: conversation)
            evidence = kind == "reportedOtherStart" ? .reportedOtherStart(session) : .reportedOtherSessionEnd(session)
        case "reportsUnreadable":
            guard columnsAreNull(lookColumns + ["reported_provider", "reported_conversation_id"], in: row),
                let reasonText: String = value(row, "unreadable_reason"),
                let reason = ReportsUnreadableReason(rawValue: reasonText)
            else { return nil }
            evidence = .reportsUnreadable(reason)
        default: return nil
        }
        return .init(
            evidence: .init(
                paneId: paneId, bindingGenerationId: generation, observerLaunchId: launchId, sequence: sequence,
                observedAt: observedAt, value: evidence),
            look: look)
    }

    static func write(_ look: PaneForegroundLook, identity: ZmxSessionIdentity, in database: Database) throws {
        try database.execute(
            sql: """
                INSERT OR REPLACE INTO terminal_pane_foreground_evidence (
                    pane_id,evidence_kind,binding_generation_id,observer_launch_id,sequence,observed_at,
                    zmx_session_id,program,identity_version,boot_id,daemon_pid,daemon_start_seconds,
                    daemon_start_microseconds,leader_pid,leader_start_seconds,leader_start_microseconds,
                    process_group_id,session_created_at
                ) VALUES (?,'look',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                look.paneId.uuidString, look.bindingGenerationId?.uuidString, look.observerLaunchId.uuidString,
                Int64(look.sequence), timestampFormatter().string(from: look.observedAt),
                look.zmxSessionId.rawValue, look.program.rawValue, identity.version, identity.bootID,
                identity.daemon.pid, Int64(identity.daemon.startSeconds), Int64(identity.daemon.startMicroseconds),
                identity.terminalLeader.pid, Int64(identity.terminalLeader.startSeconds),
                Int64(identity.terminalLeader.startMicroseconds), identity.processGroupID,
                Int64(identity.sessionCreatedAt),
            ])
    }

    static func writeReported(
        _ record: PaneForegroundEvidence, in database: Database
    ) throws {
        let kind: String
        var reported: ReportedSession?
        var unreadable: ReportsUnreadableReason?
        switch record.value {
        case .look: preconditionFailure("A look uses the typed identity writer")
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

    private static func decodeIdentity(_ row: Row) -> Data? {
        guard let version: Int = value(row, "identity_version"), let boot: String = value(row, "boot_id"),
            let daemonPid: Int32 = value(row, "daemon_pid"), let leaderPid: Int32 = value(row, "leader_pid"),
            let daemonSeconds: Int64 = value(row, "daemon_start_seconds"),
            let daemonMicros: Int64 = value(row, "daemon_start_microseconds"),
            let leaderSeconds: Int64 = value(row, "leader_start_seconds"),
            let leaderMicros: Int64 = value(row, "leader_start_microseconds"),
            let created: Int64 = value(row, "session_created_at"), let group: Int32 = value(row, "process_group_id"),
            let daemonStart = UInt64(exactly: daemonSeconds), let daemonFraction = UInt64(exactly: daemonMicros),
            let leaderStart = UInt64(exactly: leaderSeconds), let leaderFraction = UInt64(exactly: leaderMicros),
            let sessionCreated = UInt64(exactly: created)
        else { return nil }
        let identity = ZmxSessionIdentity(
            version: version, bootID: boot,
            daemon: .init(pid: daemonPid, startSeconds: daemonStart, startMicroseconds: daemonFraction),
            terminalLeader: .init(pid: leaderPid, startSeconds: leaderStart, startMicroseconds: leaderFraction),
            processGroupID: group, sessionCreatedAt: sessionCreated)
        guard let encoded = try? identity.encoded(), (try? ZmxSessionIdentity.decode(encoded)) != nil else {
            return nil
        }
        return encoded
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
