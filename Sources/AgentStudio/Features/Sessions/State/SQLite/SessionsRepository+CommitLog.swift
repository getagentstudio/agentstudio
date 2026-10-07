import AgentStudioInfrastructure
import Foundation
import GRDB

extension SessionsRepositoryStorage {
    /// The existing operation table is a revision log only. Hook record ids are
    /// fresh; no correlation, occurrence or fingerprint is ever looked up.
    static func insertHookOperation(
        database: Database, hook: SessionsHookAdmission,
        disposition: SessionsHookDisposition, binding: SessionsBindingRecord
    ) throws -> Int64 {
        let kind = disposition == .bound ? "bind" : (hook.eventName == .sessionEnd ? "sourceEnded" : "evidence")
        try database.execute(
            sql: """
                INSERT INTO sessions_operation(operation_scope, correlation_id, operation_kind, semantic_fingerprint,
                    outcome_kind, outcome_occurrence_id, binding_generation_id, created_at)
                VALUES (?, ?, ?, '', ?, ?, ?, ?)
                """,
            arguments: [
                "pane:\(hook.paneId.uuidString)", hook.recordId.uuidString, kind,
                disposition.rawValue, hook.recordId.uuidString, binding.bindingGenerationId.uuidString,
                hook.admittedAt.timeIntervalSince1970,
            ])
        return database.lastInsertedRowID
    }

    static func insertCommandFinishedOperation(
        database: Database, paneId: UUID, binding: SessionsBindingRecord, endedAt: Date
    ) throws -> Int64 {
        try database.execute(
            sql: """
                INSERT INTO sessions_operation(
                    operation_scope, correlation_id, operation_kind, semantic_fingerprint,
                    outcome_kind, outcome_entity_id, binding_generation_id, created_at
                ) VALUES (?, ?, 'sourceEnded', '', 'applied', ?, ?, ?)
                """,
            arguments: [
                "pane:\(paneId.uuidString)", UUIDv7.generate().uuidString,
                binding.bindingGenerationId.uuidString, binding.bindingGenerationId.uuidString,
                endedAt.timeIntervalSince1970,
            ])
        return database.lastInsertedRowID
    }
}
