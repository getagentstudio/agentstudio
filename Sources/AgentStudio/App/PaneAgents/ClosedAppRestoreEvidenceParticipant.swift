import AgentStudioCore
import AgentStudioSessions
import AgentStudioTerminal
import Foundation
import GRDB

/// Restore evidence and identity adoption join the Sessions/cursor transaction.
struct ClosedAppRestoreEvidenceParticipant: AgentStudioSessions.ClosedAppRestoreEvidenceParticipant {
    let repository: SQLitePaneForegroundEvidenceRepository

    func commit(in database: Database, item: ClosedAppOutboxItem, latestBindings: SessionsLatestBindings) throws {
        let sequence = try Int64.fetchOne(database, sql: "SELECT MAX(commit_revision) FROM sessions_operation") ?? 0
        switch item {
        case .report(let report):
            let latest = latestBindings.values.first
            let same =
                latest?.providerIdentifier == report.providerIdentifier
                && latest?.providerConversationId == report.providerConversationId
            let evidence: ForegroundEvidence
            switch (report.event, same) {
            case (.sessionStart, true): return
            case (.sessionEnd, true): evidence = .reportedEnd
            case (.sessionStart, false): evidence = .reportedOtherStart(try reportedSession(report))
            case (.sessionEnd, false): evidence = .reportedOtherSessionEnd(try reportedSession(report))
            }
            _ = try repository.write(
                in: database, evidence: evidence, paneId: report.paneId,
                bindingGenerationId: latest?.bindingGenerationId,
                sequence: UInt64(sequence), observedAt: report.reportedAt)
        case .refused(let paneId):
            if let paneId {
                try writeUnreadable(
                    .rowRefused, paneId: paneId, latest: latestBindings.values.first, sequence: sequence, in: database)
            } else {
                for latest in latestBindings.values {
                    try writeUnreadable(
                        .rowRefused, paneId: latest.paneId, latest: latest, sequence: sequence, in: database)
                }
            }
        case .historyLost(let storeId):
            for latest in latestBindings.values {
                try writeUnreadable(
                    .historyLost, paneId: latest.paneId, latest: latest, sequence: sequence, in: database)
            }
            try Self.adopt(storeId, in: database)
        }
    }

    static func adopt(_ storeId: UUID?, in database: Database) throws {
        try database.execute(sql: "DELETE FROM terminal_restore_outbox_identity")
        try database.execute(
            sql: "INSERT INTO terminal_restore_outbox_identity(store_id, adopted_at) VALUES (?, ?)",
            arguments: [storeId?.uuidString, ISO8601DateFormatter().string(from: Date())])
    }

    private func reportedSession(_ report: ClosedAppLifecycleReport) throws -> ReportedSession {
        guard let provider = ResumeProvider(providerIdentifier: report.providerIdentifier) else {
            throw SessionsRepositoryError.invalidStoredValue("closed-app provider")
        }
        return .init(provider: provider, conversationId: report.providerConversationId)
    }

    private func writeUnreadable(
        _ reason: ReportsUnreadableReason, paneId: UUID, latest: SessionsBindingRecord?, sequence: Int64,
        in database: Database
    ) throws {
        _ = try repository.write(
            in: database, evidence: .reportsUnreadable(reason), paneId: paneId,
            bindingGenerationId: latest?.bindingGenerationId, sequence: UInt64(sequence), observedAt: Date())
    }
}
