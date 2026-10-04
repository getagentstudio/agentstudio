import Foundation
import GRDB

extension SessionsRepositoryStorage {
    static func loadOperationReplay(
        database: Database,
        operation: SessionsRepositoryOperation
    ) throws -> SessionsMutationOutcome? {
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT * FROM sessions_operation
                    WHERE operation_scope = ? AND correlation_id = ?
                    """,
                arguments: [operation.operationScope, operation.correlationId.uuidString]
            )
        else {
            return nil
        }
        let storedFingerprint: String = row["semantic_fingerprint"]
        let version: Int? = row["fingerprint_version"]
        guard version == nil || storedFingerprint == operation.semanticFingerprint else {
            throw SessionsRepositoryError.correlationConflict(operation.correlationId)
        }
        return try decodeOperationOutcome(database: database, row: row)
    }

    static func loadOccurrenceReplay(
        database: Database,
        operation: SessionsRepositoryOperation
    ) throws -> SessionsMutationOutcome? {
        guard let providerOccurrence = operation.providerOccurrence else { return nil }
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT * FROM sessions_operation
                    WHERE operation_kind = ? AND outcome_occurrence_id = ?
                    ORDER BY commit_revision ASC
                    LIMIT 1
                    """,
                arguments: [providerOccurrence.kind.rawValue, providerOccurrence.occurrenceId.uuidString]
            )
        else {
            return nil
        }
        let version: Int? = row["fingerprint_version"]
        if version == nil { return try decodeOperationOutcome(database: database, row: row) }
        let storedScope: String = row["operation_scope"]
        let storedKind: String = row["operation_kind"]
        guard storedScope == operation.operationScope,
            storedKind == operation.operationKind,
            operation.operationKind == providerOccurrence.kind.rawValue
        else {
            throw SessionsRepositoryError.occurrenceConflict(providerOccurrence.occurrenceId)
        }
        let storedFingerprint: String = row["semantic_fingerprint"]
        guard storedFingerprint == operation.semanticFingerprint else {
            throw SessionsRepositoryError.occurrenceConflict(providerOccurrence.occurrenceId)
        }
        let outcome = try decodeOperationOutcome(database: database, row: row)
        try insertOperationAlias(
            database: database,
            operation: operation,
            retainedOperation: row
        )
        return outcome
    }

    static func insertOperation(
        database: Database,
        operation: SessionsRepositoryOperation,
        outcome: SessionsMutationOutcome
    ) throws -> Int64 {
        let storage = operationStorage(operation: operation, outcome: outcome)
        try database.execute(
            sql: """
                INSERT INTO sessions_operation(
                    operation_scope, correlation_id, operation_kind, semantic_fingerprint,
                    outcome_kind, outcome_entity_id, outcome_occurrence_id,
                    binding_generation_id, created_at, source_occurred_at, fingerprint_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
            arguments: [
                operation.operationScope,
                operation.correlationId.uuidString,
                operation.operationKind,
                operation.semanticFingerprint,
                storage.kind,
                storage.entityId,
                storage.occurrenceId,
                storage.bindingGenerationId,
                operation.createdAt.timeIntervalSince1970,
                operation.sourceOccurredAt?.timeIntervalSince1970,
            ]
        )
        return database.lastInsertedRowID
    }

    private static func insertOperationAlias(
        database: Database,
        operation: SessionsRepositoryOperation,
        retainedOperation: Row
    ) throws {
        let outcomeKind: String = retainedOperation["outcome_kind"]
        let outcomeEntityId: String? = retainedOperation["outcome_entity_id"]
        let outcomeOccurrenceId: String? = retainedOperation["outcome_occurrence_id"]
        let bindingGenerationId: String? = retainedOperation["binding_generation_id"]
        try database.execute(
            sql: """
                INSERT INTO sessions_operation(
                    operation_scope, correlation_id, operation_kind, semantic_fingerprint,
                    outcome_kind, outcome_entity_id, outcome_occurrence_id,
                    binding_generation_id, created_at, source_occurred_at, fingerprint_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
            arguments: [
                operation.operationScope,
                operation.correlationId.uuidString,
                operation.operationKind,
                operation.semanticFingerprint,
                outcomeKind,
                outcomeEntityId,
                outcomeOccurrenceId,
                bindingGenerationId,
                operation.createdAt.timeIntervalSince1970,
                operation.sourceOccurredAt?.timeIntervalSince1970,
            ]
        )
    }
}

extension SessionsRepositoryStorage {
    fileprivate struct OperationStorage {
        let kind: String
        let entityId: String?
        let occurrenceId: String?
        let bindingGenerationId: String?
    }

    fileprivate static func operationStorage(
        operation: SessionsRepositoryOperation,
        outcome: SessionsMutationOutcome
    ) -> OperationStorage {
        let storedOutcome = outcomeStorage(outcome)
        guard let providerOccurrence = operation.providerOccurrence else {
            return storedOutcome
        }
        return OperationStorage(
            kind: storedOutcome.kind,
            entityId: storedOutcome.entityId,
            occurrenceId: providerOccurrence.occurrenceId.uuidString,
            bindingGenerationId: storedOutcome.bindingGenerationId
        )
    }

    private static func outcomeStorage(_ outcome: SessionsMutationOutcome) -> OperationStorage {
        switch outcome {
        case .binding(.established(let binding)):
            OperationStorage(
                kind: "bindingEstablished",
                entityId: nil,
                occurrenceId: nil,
                bindingGenerationId: binding.bindingGenerationId.uuidString
            )
        case .binding(.replaced(let previous, let current)):
            OperationStorage(
                kind: "bindingReplaced",
                entityId: previous.bindingGenerationId.uuidString,
                occurrenceId: nil,
                bindingGenerationId: current.bindingGenerationId.uuidString
            )
        case .binding(.unchanged(let binding)):
            OperationStorage(
                kind: "bindingUnchanged",
                entityId: nil,
                occurrenceId: nil,
                bindingGenerationId: binding.bindingGenerationId.uuidString
            )
        case .evidenceRecorded(let occurrenceId):
            OperationStorage(
                kind: "evidenceRecorded",
                entityId: nil,
                occurrenceId: occurrenceId.uuidString,
                bindingGenerationId: nil
            )
        case .historical(let occurrenceId):
            OperationStorage(
                kind: "historical",
                entityId: nil,
                occurrenceId: occurrenceId.uuidString,
                bindingGenerationId: nil
            )
        case .sourceEnded(let sourceGenerationId):
            OperationStorage(
                kind: "sourceEnded",
                entityId: sourceGenerationId.uuidString,
                occurrenceId: nil,
                bindingGenerationId: nil
            )
        case .lossRecorded(let id):
            OperationStorage(
                kind: "lossRecorded",
                entityId: id.uuidString,
                occurrenceId: nil,
                bindingGenerationId: nil
            )
        case .launchPrepared(let activeSourcesEnded):
            OperationStorage(
                kind: "launchPrepared",
                entityId: String(activeSourcesEnded),
                occurrenceId: nil,
                bindingGenerationId: nil
            )
        }
    }

    fileprivate static func decodeOperationOutcome(database: Database, row: Row) throws -> SessionsMutationOutcome {
        let kind: String = row["outcome_kind"]
        let entityId: String? = row["outcome_entity_id"]
        let occurrenceId: String? = row["outcome_occurrence_id"]
        let bindingGenerationId: String? = row["binding_generation_id"]
        switch kind {
        case "bindingEstablished", "bindingUnchanged":
            let binding = bindingAsActive(
                try loadBinding(database: database, id: required(bindingGenerationId, kind: kind))
            )
            return .binding(kind == "bindingEstablished" ? .established(binding) : .unchanged(binding))
        case "bindingReplaced":
            let current = bindingAsActive(
                try loadBinding(database: database, id: required(bindingGenerationId, kind: kind))
            )
            let previous = bindingAsEnded(
                try loadBinding(database: database, id: required(entityId, kind: kind)),
                endedAt: current.startedAt
            )
            return .binding(.replaced(previous, current))
        case "evidenceRecorded":
            return .evidenceRecorded(occurrenceId: try decodeUuid(required(occurrenceId, kind: kind)))
        case "historical":
            return .historical(occurrenceId: try decodeUuid(required(occurrenceId, kind: kind)))
        case "sourceEnded":
            return .sourceEnded(sourceGenerationId: try decodeUuid(required(entityId, kind: kind)))
        case "lossRecorded":
            return .lossRecorded(id: try decodeUuid(required(entityId, kind: kind)))
        case "launchPrepared":
            guard let count = Int(try required(entityId, kind: kind)) else {
                throw SessionsRepositoryError.invalidStoredValue(entityId ?? "nil")
            }
            return .launchPrepared(activeSourcesEnded: count)
        default:
            throw SessionsRepositoryError.invalidStoredValue(kind)
        }
    }

    fileprivate static func loadBinding(database: Database, id: String) throws -> SessionsBindingRecord {
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT binding.*, conversation.provider_identifier, conversation.provider_conversation_id
                    FROM sessions_pane_binding AS binding
                    JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                    WHERE binding.binding_generation_id = ?
                    """,
                arguments: [id]
            )
        else {
            throw SessionsRepositoryError.invalidStoredValue(id)
        }
        return try decodeBinding(row)
    }

    fileprivate static func required(_ value: String?, kind: String) throws -> String {
        guard let value else { throw SessionsRepositoryError.invalidStoredValue(kind) }
        return value
    }

    fileprivate static func bindingAsActive(_ binding: SessionsBindingRecord) -> SessionsBindingRecord {
        SessionsBindingRecord(
            bindingGenerationId: binding.bindingGenerationId,
            paneId: binding.paneId,
            conversationId: binding.conversationId,
            providerIdentifier: binding.providerIdentifier,
            providerConversationId: binding.providerConversationId,
            sourceGenerationId: binding.sourceGenerationId,
            transitionOccurrenceId: binding.transitionOccurrenceId,
            origin: binding.origin,
            status: .active,
            startedAt: binding.startedAt,
            endedAt: nil,
            resumeHint: binding.resumeHint,
            ownerPaneId: binding.ownerPaneId
        )
    }

    fileprivate static func bindingAsEnded(
        _ binding: SessionsBindingRecord,
        endedAt: Date
    ) -> SessionsBindingRecord {
        SessionsBindingRecord(
            bindingGenerationId: binding.bindingGenerationId,
            paneId: binding.paneId,
            conversationId: binding.conversationId,
            providerIdentifier: binding.providerIdentifier,
            providerConversationId: binding.providerConversationId,
            sourceGenerationId: binding.sourceGenerationId,
            transitionOccurrenceId: binding.transitionOccurrenceId,
            origin: binding.origin,
            status: .ended,
            startedAt: binding.startedAt,
            endedAt: endedAt,
            resumeHint: binding.resumeHint,
            ownerPaneId: binding.ownerPaneId
        )
    }
}
