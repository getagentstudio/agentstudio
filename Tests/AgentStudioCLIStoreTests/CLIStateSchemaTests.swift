import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCLIStore

@Suite("CLI state schema")
struct CLIStateSchemaTests {
    @Test("an exhausted original call budget refuses append and purge without changing the outbox")
    func exhaustedCallBudgetPreservesOutbox() async throws {
        let observation = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let remaining = Mutex<Duration>(.seconds(1))
            let writer = try CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                migrationLockWaitBudget: { remaining.withLock { $0 } }
            ).get()
            defer { try? writer.close() }
            let original = try writer.appendNotice(
                paneID: UUIDv7.generate(), messageID: UUIDv7.generate(),
                payloadJSON: "retained", createdAt: fixture.createdAt
            ).get()
            remaining.withLock { $0 = .zero }
            let appended = writer.appendNotice(
                paneID: UUIDv7.generate(), messageID: UUIDv7.generate(),
                payloadJSON: "refused", createdAt: fixture.createdAt)
            let purged = writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: original.id,
                now: fixture.createdAt.addingTimeInterval(CLIStorePolicy.handledRetention + 1))
            let appendFailure: CLIStoreFailure? = if case .failure(let failure) = appended { failure } else { nil }
            let purgeFailure: CLIStoreFailure? = if case .failure(let failure) = purged { failure } else { nil }
            let entries = try writer.readOutbox(after: 0).get().entries
            return (appendFailure: appendFailure, purgeFailure: purgeFailure, entries: entries, original: original)
        }
        #expect(observation.appendFailure == .busy(extendedResultCode: nil, stage: .append))
        #expect(observation.purgeFailure == .busy(extendedResultCode: nil, stage: .purge))
        #expect(observation.entries == [observation.original])
    }

    @Test("the real CLI writer migrates the additive state table with exact storage columns")
    func writerMigratesCLIState() async throws {
        let observation = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            defer { try? writer.databaseQueue.close() }
            return try writer.databaseQueue.read { database in
                let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(cli_state)")
                let columnNames: [String] = columns.map { $0["name"] }
                let columnTypes: [String] = columns.map { $0["type"] }
                let primaryKeys: [String] = columns.compactMap { row in
                    let position: Int = row["pk"]
                    return position == 0 ? nil : row["name"]
                }
                let schema = try String.fetchOne(
                    database, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'cli_state'")
                let triggers = try String.fetchAll(
                    database, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'cli_state'")
                return CLIStateSchemaObservation(
                    columnNames: columnNames, columnTypes: columnTypes, primaryKeys: primaryKeys,
                    schema: schema, triggers: triggers)
            }
        }
        #expect(observation.columnNames == ["id", "kind", "pane_id", "session_ref", "epoch", "claim_id", "value"])
        #expect(observation.columnTypes == ["TEXT", "TEXT", "TEXT", "TEXT", "INTEGER", "TEXT", "INTEGER"])
        #expect(observation.primaryKeys == ["id"])
        let schema = try #require(observation.schema)
        let compactSchema = schema.lowercased().filter { !$0.isWhitespace }
        #expect(compactSchema.contains("unique(kind,pane_id,session_ref)"))
        #expect(!compactSchema.contains("check("))
        #expect(observation.triggers.isEmpty)
    }
}

private struct CLIStateSchemaObservation: Sendable {
    let columnNames: [String]
    let columnTypes: [String]
    let primaryKeys: [String]
    let schema: String?
    let triggers: [String]
}
