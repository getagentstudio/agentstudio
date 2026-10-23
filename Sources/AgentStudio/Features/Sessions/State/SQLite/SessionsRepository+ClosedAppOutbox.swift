import Foundation
import GRDB

extension SessionsRepository {
    func admitClosedAppOutboxItem(
        _ item: ClosedAppOutboxItem, restoreEvidence: any ClosedAppRestoreEvidenceParticipant,
        participants: [any SessionsCommitParticipant]
    ) async throws -> ClosedAppOutboxCommit {
        try await sqliteAccess.write { database in
            let bindings = try SessionsRepositoryStorage.latestBindings(database: database, paneId: item.paneId)
            let committed: ClosedAppOutboxCommit
            switch item {
            case .report(let report):
                committed = try SessionsRepositoryStorage.applyClosedAppReport(
                    report, binding: bindings.values.first, database: database)
            case .refused: committed = .init(outcome: .unchanged(.refused), ended: nil)
            case .historyLost: committed = .init(outcome: .unchanged(.historyLost), ended: nil)
            }
            try restoreEvidence.commit(in: database, item: item, latestBindings: bindings)
            for participant in participants { try participant.commit(in: database) }
            return committed
        }
    }
}

extension SessionsRepositoryStorage {
    static func latestBindings(database: Database, paneId: UUID?) throws -> SessionsLatestBindings {
        if let paneId { return .init(values: Array(try loadBindings(database: database, paneId: paneId).prefix(1))) }
        let panes = try String.fetchAll(database, sql: "SELECT DISTINCT pane_id FROM sessions_pane_binding")
        return .init(
            values: try panes.compactMap { value in
                try loadBindings(database: database, paneId: decodeUuid(value)).first
            })
    }

    static func applyClosedAppReport(
        _ report: ClosedAppLifecycleReport, binding: SessionsBindingRecord?, database: Database
    ) throws -> ClosedAppOutboxCommit {
        guard let binding else { return .init(outcome: .unchanged(.noLiveMain), ended: nil) }
        guard binding.providerIdentifier == report.providerIdentifier,
            binding.providerConversationId == report.providerConversationId
        else { return .init(outcome: .unchanged(.otherSession), ended: nil) }
        if report.event == .sessionStart {
            try recordClosedAppStart(report, binding: binding, database: database)
            return .init(outcome: .unchanged(.start), ended: nil)
        }
        guard binding.status == .active else { return .init(outcome: .unchanged(.noLiveMain), ended: nil) }
        guard !report.newerOrEqualSameSessionStartInRead else {
            return .init(outcome: .unchanged(.laterStart), ended: nil)
        }
        guard report.isNewestInRead else {
            return .init(outcome: .unchanged(.newerEvidence), ended: nil)
        }
        let latest = try Double.fetchOne(
            database, sql: "SELECT MAX(occurred_at) FROM sessions_evidence WHERE binding_generation_id = ?",
            arguments: [binding.bindingGenerationId.uuidString])
        if let latest, floor(latest * 1000) >= floor(report.reportedAt.timeIntervalSince1970 * 1000) {
            return .init(outcome: .unchanged(.newerEvidence), ended: nil)
        }
        let context = try loadContext(database: database, query: .pane(binding.paneId))
        guard
            let source = context.sources.first(where: {
                $0.bindingGenerationId == binding.bindingGenerationId && $0.status == .active
            })
        else { throw SessionsRepositoryError.invalidStoredValue("active binding source") }
        let ended = SessionsEvidenceReducer.replacing(binding, status: .ended, endedAt: report.reportedAt)
        let revision = try insertCommandFinishedOperation(
            database: database, paneId: binding.paneId, binding: binding, endedAt: report.reportedAt)
        try apply(
            reduction: .init(
                bindingChanges: [ended],
                sourceChanges: [SessionsEvidenceReducer.replacing(source, status: .ended, endedAt: report.reportedAt)],
                outcome: .applied), commitRevision: revision, database: database)
        try database.execute(
            sql: "UPDATE sessions_pane_binding SET transition_occurrence_id = ? WHERE binding_generation_id = ?",
            arguments: [report.reportId.uuidString, binding.bindingGenerationId.uuidString])
        let committedBinding = try loadBindings(database: database, paneId: binding.paneId).first
        guard let committedBinding else { throw SessionsRepositoryError.invalidStoredValue("closed main") }
        return .init(
            outcome: .endedOwnMain(bindingGenerationId: binding.bindingGenerationId),
            ended: .init(binding: committedBinding, revision: revision, endedAt: report.reportedAt))
    }

    private static func recordClosedAppStart(
        _ report: ClosedAppLifecycleReport, binding: SessionsBindingRecord, database: Database
    ) throws {
        let hook = SessionsHookAdmission(
            paneId: report.paneId, providerIdentifier: report.providerIdentifier, providerVersion: "",
            sessionId: report.providerConversationId, eventName: .sessionStart, turnId: nil,
            signal: .sessionStart, recordId: report.reportId, admittedAt: report.reportedAt)
        let revision = try insertHookOperation(
            database: database, hook: hook, disposition: .recordedOnly, binding: binding)
        let fact = SessionsEvidenceRecord(
            recordId: report.reportId, conversationId: binding.conversationId,
            bindingGenerationId: binding.bindingGenerationId, sourceGenerationId: binding.sourceGenerationId,
            turnId: nil, subject: .root, kind: .activityStarted, origin: .reported, statusEffect: .recordedOnly,
            occurredAt: report.reportedAt, providerSignal: .sessionStart)
        try apply(
            reduction: .init(evidenceChanges: [fact], outcome: .recordedOnly), commitRevision: revision,
            database: database)
    }
}
