import AgentStudioPrimitives
import Foundation
import GRDB

package enum CLIStateKind: String, Sendable {
    case titleWriteNumber
    case lineWriteNumber
    case answerPosition
}

package struct CLIStateKey: Sendable {
    package let kind: CLIStateKind
    package let paneID: UUID
    package let sessionRef: String

    package init(kind: CLIStateKind, paneID: UUID, sessionRef: String) {
        self.kind = kind
        self.paneID = paneID
        self.sessionRef = sessionRef
    }
}

package struct CLIAllocatedWriteNumber: Sendable {
    package let epoch: Int64
    package let counter: Int64
}

package enum CLIWriteReservation: Sendable {
    case claim(UUID)
    case allocated(CLIAllocatedWriteNumber)
}

extension CLIStore {
    /// The pending identity commits before network I/O. Concurrent first users
    /// therefore retry the same claim, not competing newly generated epochs.
    package func reserveWrite(_ key: CLIStateKey) throws -> CLIWriteReservation {
        guard key.kind != .answerPosition else { throw CLIStoreFailure.unavailable }
        return try stateTransaction { database in
            try Self.ensureStateRow(key, in: database)
            let row = try Self.stateRow(key, in: database)
            if let epoch: Int64 = row["epoch"] {
                return .allocated(try Self.allocateNumber(key, epoch: epoch, in: database))
            }
            if let stored: String = row["claim_id"] {
                guard let claim = UUID(uuidString: stored), UUIDv7.isV7(claim) else {
                    throw CLIStoreFailure.unavailable
                }
                return .claim(claim)
            }
            let claim = UUIDv7.generate()
            try database.execute(
                sql: "UPDATE cli_state SET claim_id = ? WHERE id = ?",
                arguments: [claim.uuidString, row["id"] as String])
            return .claim(claim)
        }
    }

    package func acceptClaim(_ key: CLIStateKey, claimID: UUID, epoch: Int64) throws -> CLIAllocatedWriteNumber {
        guard epoch > 0 else { throw CLIStoreFailure.unavailable }
        return try stateTransaction { database in
            let row = try Self.stateRow(key, in: database)
            let storedClaim: String? = row["claim_id"]
            guard storedClaim == claimID.uuidString else { throw CLIStoreFailure.unavailable }
            if let storedEpoch: Int64 = row["epoch"] {
                guard storedEpoch == epoch else { throw CLIStoreFailure.unavailable }
            } else {
                try database.execute(
                    sql: "UPDATE cli_state SET epoch = ?, value = 0 WHERE id = ?",
                    arguments: [epoch, row["id"] as String])
            }
            return try Self.allocateNumber(key, epoch: epoch, in: database)
        }
    }

    /// Refusal is final for the payload. Only the next intent can reserve a
    /// new claim. A delayed refusal cannot clear a sibling's newer epoch.
    package func clearSupersededEpoch(_ key: CLIStateKey, epoch: Int64) throws {
        try stateTransaction { database in
            try database.execute(
                sql: """
                    UPDATE cli_state SET epoch = NULL, claim_id = NULL, value = 0
                    WHERE kind = ? AND pane_id = ? AND session_ref = ? AND epoch = ?
                    """, arguments: [key.kind.rawValue, key.paneID.uuidString, key.sessionRef, epoch])
        }
    }

    package func retainLastAccepted(_ key: CLIStateKey, epoch: Int64, counter: Int64) throws {
        guard counter >= 0 else { throw CLIStoreFailure.unavailable }
        try stateTransaction { database in
            try database.execute(
                sql: """
                    UPDATE cli_state SET value = max(value, ?)
                    WHERE kind = ? AND pane_id = ? AND session_ref = ? AND epoch = ?
                    """, arguments: [counter, key.kind.rawValue, key.paneID.uuidString, key.sessionRef, epoch])
        }
    }

    package func answerPosition(_ key: CLIStateKey) throws -> Int64 {
        guard key.kind == .answerPosition else { throw CLIStoreFailure.unavailable }
        return try stateTransaction { database in
            try Self.ensureStateRow(key, in: database)
            let row = try Self.stateRow(key, in: database)
            let value: Int64 = row["value"]
            guard value >= 0 else { throw CLIStoreFailure.unavailable }
            return value
        }
    }

    package func advanceAnswerPosition(_ key: CLIStateKey, to position: Int64) throws {
        guard key.kind == .answerPosition, position >= 0 else { throw CLIStoreFailure.unavailable }
        try stateTransaction { database in
            try Self.ensureStateRow(key, in: database)
            try database.execute(
                sql: """
                    UPDATE cli_state SET value = max(value, ?)
                    WHERE kind = ? AND pane_id = ? AND session_ref = ?
                    """, arguments: [position, key.kind.rawValue, key.paneID.uuidString, key.sessionRef])
        }
    }

    package func close() throws { try databaseQueue.close() }

    private func stateTransaction<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) throws -> Output {
        try budgetedWriteTransaction(stage: .append, operation)
    }

    /// Each write retains the ordinary short wait while clipping it to the
    /// original call's remaining budget, including notice append and cleanup.
    func budgetedWriteTransaction<Output: Sendable>(
        stage: CLIStoreFailure.Stage, _ operation: @Sendable (Database) throws -> Output
    ) throws -> Output {
        guard !databaseQueue.configuration.readonly else { throw CLIStoreFailure.readOnly }
        return try databaseQueue.writeWithoutTransaction { database in
            if let remaining = callBudget() {
                guard remaining > .zero else { throw CLIStoreFailure.busy(extendedResultCode: nil, stage: stage) }
                let milliseconds = Int(
                    min(CLIStorePolicy.busyTimeout * 1000, (remaining / .milliseconds(1)).rounded(.down)))
                try database.execute(sql: "PRAGMA busy_timeout = \(milliseconds)")
            }
            var result: Output?
            try database.inTransaction(.immediate) {
                result = try operation(database)
                return .commit
            }
            guard let result else { throw CLIStoreFailure.unavailable }
            return result
        }
    }

    private static func ensureStateRow(_ key: CLIStateKey, in database: Database) throws {
        guard !key.sessionRef.isEmpty else { throw CLIStoreFailure.unavailable }
        try database.execute(
            sql: """
                INSERT INTO cli_state(id, kind, pane_id, session_ref, epoch, claim_id, value)
                VALUES (?, ?, ?, ?, NULL, NULL, 0)
                ON CONFLICT(kind, pane_id, session_ref) DO NOTHING
                """,
            arguments: [UUIDv7.generate().uuidString, key.kind.rawValue, key.paneID.uuidString, key.sessionRef])
    }

    private static func stateRow(_ key: CLIStateKey, in database: Database) throws -> Row {
        guard
            let row = try Row.fetchOne(
                database, sql: "SELECT * FROM cli_state WHERE kind = ? AND pane_id = ? AND session_ref = ?",
                arguments: [key.kind.rawValue, key.paneID.uuidString, key.sessionRef])
        else { throw CLIStoreFailure.unavailable }
        return row
    }

    private static func allocateNumber(_ key: CLIStateKey, epoch: Int64, in database: Database) throws
        -> CLIAllocatedWriteNumber
    {
        let row = try stateRow(key, in: database)
        let value: Int64 = row["value"]
        guard epoch > 0, value >= 0, value < Int64.max else { throw CLIStoreFailure.unavailable }
        let counter = value + 1
        try database.execute(
            sql: "UPDATE cli_state SET value = ? WHERE id = ?", arguments: [counter, row["id"] as String])
        return CLIAllocatedWriteNumber(epoch: epoch, counter: counter)
    }
}
