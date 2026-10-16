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
    case claim(UUID, counter: Int64)
    case allocated(CLIAllocatedWriteNumber)
}

extension CLIStore {
    /// Reserve every candidate writer before network I/O in one transaction.
    /// Pending claims share an identity, but each intent keeps its own counter.
    package func reserveWrites(_ keys: [CLIStateKey]) throws -> [CLIWriteReservation] {
        guard keys.allSatisfy({ $0.kind != .answerPosition }) else { throw CLIStoreFailure.unavailable }
        return try stateTransaction { database in
            try keys.map { key in
                try Self.ensureStateRow(key, in: database)
                let row = try Self.stateRow(key, in: database)
                let counter = try Self.allocateCounter(key, in: database)
                if let epoch: Int64 = row["epoch"] {
                    guard epoch > 0 else { throw CLIStoreFailure.unavailable }
                    return .allocated(CLIAllocatedWriteNumber(epoch: epoch, counter: counter))
                }
                if let stored: String = row["claim_id"] {
                    guard let claim = UUID(uuidString: stored), UUIDv7.isV7(claim) else {
                        throw CLIStoreFailure.unavailable
                    }
                    return .claim(claim, counter: counter)
                }
                let claim = UUIDv7.generate()
                try database.execute(
                    sql: "UPDATE cli_state SET claim_id = ? WHERE id = ?",
                    arguments: [claim.uuidString, row["id"] as String])
                return .claim(claim, counter: counter)
            }
        }
    }

    package func acceptClaim(_ key: CLIStateKey, claimID: UUID, epoch: Int64, counter: Int64) throws
        -> CLIAllocatedWriteNumber
    {
        guard epoch > 0, counter > 0 else { throw CLIStoreFailure.unavailable }
        return try stateTransaction { database in
            let row = try Self.stateRow(key, in: database)
            let storedClaim: String? = row["claim_id"]
            let reservedCounter: Int64 = row["value"]
            guard storedClaim == claimID.uuidString, counter <= reservedCounter else {
                throw CLIStoreFailure.unavailable
            }
            if let storedEpoch: Int64 = row["epoch"] {
                guard storedEpoch == epoch else { throw CLIStoreFailure.unavailable }
            } else {
                try database.execute(
                    sql: "UPDATE cli_state SET epoch = ? WHERE id = ?",
                    arguments: [epoch, row["id"] as String])
            }
            return CLIAllocatedWriteNumber(epoch: epoch, counter: counter)
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

    private static func allocateCounter(_ key: CLIStateKey, in database: Database) throws -> Int64 {
        let row = try stateRow(key, in: database)
        let value: Int64 = row["value"]
        guard value >= 0, value < Int64.max else { throw CLIStoreFailure.unavailable }
        let counter = value + 1
        try database.execute(
            sql: "UPDATE cli_state SET value = ? WHERE id = ?", arguments: [counter, row["id"] as String])
        return counter
    }
}
