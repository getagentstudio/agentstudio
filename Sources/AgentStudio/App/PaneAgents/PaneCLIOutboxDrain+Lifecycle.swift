import AgentStudioCLIStore
import AgentStudioCore
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import GRDB

extension PaneCLIOutboxDrain {
    /// Decode once before committing any row: ids order commits, times order runs.
    func lifecycleItems(in entries: [CLIOutboxEntry]) async throws -> [Int64: ClosedAppOutboxItem] {
        let parsed = entries.compactMap { entry -> DecodedLifecycleEntry? in
            guard case .sessionLifecycle(let report) = entry,
                report.payloadJSON.utf8.count <= maximumPayloadBytes,
                let descriptor = descriptors["session.event"],
                let normalized = try? descriptor.normalizeParameters(Data(report.payloadJSON.utf8)),
                let params = try? JSONDecoder().decode(IPCSessionEventParams.self, from: normalized.data),
                ResumeProvider(providerIdentifier: params.provider.identifier) != nil,
                params.event.name == .sessionStart || params.event.name == .sessionEnd,
                params.handle == "self" || params.handle == report.paneID.uuidString
            else { return nil }
            return .init(entry: report, params: params)
        }
        var items: [Int64: ClosedAppOutboxItem] = [:]
        for case .sessionLifecycle(let entry) in entries {
            guard let current = parsed.first(where: { $0.entry.id == entry.id }), try await paneExists(entry.paneID)
            else {
                items[entry.id] = .refused(paneId: entry.paneID)
                continue
            }
            let sameSession = parsed.filter { current.sameSession(as: $0) }
            let hasLaterStart = sameSession.contains {
                $0.params.event.name == .sessionStart && $0.entry.reportedAt >= entry.reportedAt
            }
            let newest = !sameSession.contains {
                $0.entry.reportedAt > entry.reportedAt
                    || ($0.entry.reportedAt == entry.reportedAt && $0.entry.id > entry.id)
            }
            items[entry.id] = .report(
                .init(
                    reportId: entry.messageID, paneId: entry.paneID,
                    providerIdentifier: current.params.provider.identifier,
                    providerConversationId: current.params.event.conversationId,
                    event: current.params.event.name == .sessionStart ? .sessionStart : .sessionEnd,
                    reportedAt: entry.reportedAt, newerOrEqualSameSessionStartInRead: hasLaterStart,
                    isNewestInRead: newest))
        }
        return items
    }

    func importLifecycle(_ item: ClosedAppOutboxItem, cursor: CLIOutboxCursorCommitParticipant) async throws {
        _ = try await ingestion.admitClosedAppOutboxItem(item, restoreEvidence: restoreEvidence, participants: [cursor])
    }

    /// Initial adoption is not a loss, including databases with pre-R3 notice cursors.
    func checkHistory(presentStoreId: UUID?) async throws -> Bool {
        let prior: AdoptedOutboxHistory = try await sqliteAccess.read { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT store_id FROM terminal_restore_outbox_identity")
            else {
                return .unadopted
            }
            let raw: String? = row["store_id"]
            guard let raw else { return .adopted(nil) }
            guard let id = UUID(uuidString: raw) else {
                throw SessionsRepositoryError.invalidStoredValue("restore outbox identity")
            }
            return .adopted(id)
        }
        switch prior {
        case .adopted(let priorId) where priorId != nil && priorId != presentStoreId:
            _ = try await ingestion.admitClosedAppOutboxItem(
                .historyLost(adopting: presentStoreId), restoreEvidence: restoreEvidence, participants: [])
            return true
        case .unadopted:
            try await sqliteAccess.write { try ClosedAppRestoreEvidenceParticipant.adopt(presentStoreId, in: $0) }
            return false
        case .adopted(nil) where presentStoreId != nil:
            try await sqliteAccess.write { try ClosedAppRestoreEvidenceParticipant.adopt(presentStoreId, in: $0) }
            return false
        case .adopted: return false
        }
    }
}

private enum AdoptedOutboxHistory: Sendable {
    case unadopted
    case adopted(UUID?)
}

private struct DecodedLifecycleEntry {
    let entry: CLISessionLifecycleEntry
    let params: IPCSessionEventParams

    func sameSession(as other: Self) -> Bool {
        entry.paneID == other.entry.paneID && params.provider.identifier == other.params.provider.identifier
            && params.event.conversationId == other.params.event.conversationId
    }
}
