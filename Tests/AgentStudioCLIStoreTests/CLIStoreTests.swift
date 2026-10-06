import AgentStudioPrimitives
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCLIStore

@Suite("CLI store")
struct CLIStoreTests {
    @Test("writer migrates an empty file and reopens the same UUIDv7 identity")
    func writerCreatesAndPreservesIdentity() async throws {
        let observed = try await valueFromDedicatedThread {
            // Arrange
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }

            // Act
            let first = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let second = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()

            return try first.databaseQueue.read { database in
                StoreIdentityObservation(
                    first: first.identity, second: second.identity,
                    identityCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM cli_store_identity"),
                    hasOutbox: try database.tableExists("cli_outbox"),
                    migrations: try CLIStoreMigrator.makeMigrator(channel: .debug).appliedMigrations(database))
            }
        }
        // Assert in the test task; all database observations were read off-pool.
        #expect(UUIDv7.isV7(observed.first.storeID))
        #expect(observed.first == observed.second)
        #expect(observed.first.channel == .debug)
        #expect(observed.identityCount == 1)
        #expect(observed.hasOutbox)
        #expect(observed.migrations == [CLIStoreMigrator.identityMigration, CLIStoreMigrator.outboxMigration])
    }

    @Test("the schema uses only TEXT and INTEGER with no enum CHECK, triggers or foreign keys")
    func schemaPreservesAdditiveEvolution() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let store = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()

            return try store.databaseQueue.read { database in
                let tables = try ["cli_store_identity", "cli_outbox"].map { table in
                    let types = try String.fetchAll(
                        database, sql: "SELECT type FROM pragma_table_info(?)", arguments: [table])
                    let storedSchema = try String.fetchOne(
                        database, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [table])
                    return (types: types, storedSchema: storedSchema)
                }
                return (
                    tables: tables,
                    triggerCount: try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'")
                )
            }
        }
        for table in observed.tables {
            #expect(!table.types.isEmpty)
            #expect(table.types.allSatisfy { $0 == "TEXT" || $0 == "INTEGER" })
            let schema = try #require(table.storedSchema)
            #expect(!schema.uppercased().contains("CHECK"))
            #expect(!schema.uppercased().contains("REFERENCES"))
        }
        #expect(observed.triggerCount == 0)
    }

    @Test("file connections use WAL and a 50 ms SQLite busy timeout")
    func connectionsUseWALAndShortBusyTimeout() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()

            return try [writer, reader].map { store in
                try store.databaseQueue.read { database in
                    (
                        journalMode: try String.fetchOne(database, sql: "PRAGMA journal_mode"),
                        busyTimeout: try Int.fetchOne(database, sql: "PRAGMA busy_timeout")
                    )
                }
            }
        }
        for connection in observed {
            #expect(connection.journalMode == "wal")
            #expect(connection.busyTimeout == 50)
        }
    }

    @Test("a previous-version reader does not migrate; the next writer upgrades without replacing identity")
    func previousVersionIsReadOnlyUntilWriterMigrates() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let previous = try DatabaseQueue(path: fixture.databaseURL.path)
            let migrator = CLIStoreMigrator.makeMigrator(channel: .beta)
            try migrator.migrate(previous, upTo: CLIStoreMigrator.identityMigration)
            let storedIdentity = try previous.read { database in
                try String.fetchOne(database, sql: "SELECT store_id FROM cli_store_identity")
            }
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .beta).get()
            let readerEntries = try reader.readOutbox(after: 0).get().entries
            let previousSchema = try previous.read { database in
                (
                    migrations: try migrator.appliedMigrations(database),
                    hasOutbox: try database.tableExists("cli_outbox")
                )
            }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .beta).get()
            return PreviousVersionObservation(
                storedIdentity: storedIdentity, readerIdentity: reader.identity, readerEntries: readerEntries,
                previousMigrations: previousSchema.migrations, previousHasOutbox: previousSchema.hasOutbox,
                writerIdentity: writer.identity,
                writerHasOutbox: try writer.databaseQueue.read { try $0.tableExists("cli_outbox") })
        }
        let originalIdentity = try #require(observed.storedIdentity)
        #expect(observed.readerIdentity.storeID.uuidString == originalIdentity)
        #expect(observed.readerEntries.isEmpty)
        #expect(observed.previousMigrations == [CLIStoreMigrator.identityMigration])
        #expect(!observed.previousHasOutbox)
        #expect(observed.writerIdentity.storeID.uuidString == originalIdentity)
        #expect(observed.writerIdentity.channel == .beta)
        #expect(observed.writerHasOutbox)
    }

    @Test("writer WAL commits use synchronous FULL for power-loss durability")
    func writerUsesFullSynchronization() async throws {
        let synchronous = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            return try writer.databaseQueue.read { database in
                try Int.fetchOne(database, sql: "PRAGMA synchronous")
            }
        }
        #expect(synchronous == 2)
    }

    @Test("reader refuses an unknown migration without changing the store bytes or modification time")
    func supersededReaderDoesNotTouchFile() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            try writer.databaseQueue.write { database in
                try database.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: ["003_unknown_cli_migration"])
            }
            try writer.databaseQueue.writeWithoutTransaction { database in
                _ = try database.checkpoint(.truncate)
            }
            let beforeBytes = try Data(contentsOf: fixture.databaseURL)
            let beforeDate =
                try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)[.modificationDate]
                as? Date
            let readerFailure = failure(in: CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug))
            let afterBytes = try Data(contentsOf: fixture.databaseURL)
            let afterDate =
                try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)[.modificationDate]
                as? Date
            return (
                failure: readerFailure, bytes: (before: beforeBytes, after: afterBytes),
                dates: (before: beforeDate, after: afterDate)
            )
        }
        #expect(observed.failure == .superseded)
        #expect(observed.bytes.after == observed.bytes.before)
        let beforeDate = try #require(observed.dates.before)
        let afterDate = try #require(observed.dates.after)
        #expect(afterDate == beforeDate)
    }

    @Test("an append round trips a typed immutable notice; the wire payload stays opaque")
    func noticeRoundTripsWithoutInterpretingPayload() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let paneID = UUIDv7.generate()
            let messageID = UUIDv7.generate()
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            let inserted = try writer.appendNotice(
                paneID: paneID, messageID: messageID,
                payloadJSON: "opaque to the store; decoded only by live admission", createdAt: createdAt
            ).get()
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()

            let batch = try reader.readOutbox(after: 0).get()
            return NoticeRoundTripObservation(
                batch: batch, inserted: inserted, paneID: paneID, messageID: messageID, createdAt: createdAt,
                laterEntries: try reader.readOutbox(after: inserted.id).get().entries)
        }
        #expect(observed.batch.entries == [observed.inserted])
        #expect(observed.batch.lastReadID == observed.inserted.id)
        guard case .notice(let notice) = observed.inserted else { return }
        #expect(notice.paneID == observed.paneID)
        #expect(notice.messageID == observed.messageID)
        #expect(notice.createdAt == observed.createdAt)
        #expect(notice.payloadJSON == "opaque to the store; decoded only by live admission")
        #expect(observed.laterEntries.isEmpty)
    }

    @Test("duplicate message ids preserve the first notice without mutating it")
    func duplicateAppendPreservesOriginalNotice() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let paneID = UUIDv7.generate()
            let messageID = UUIDv7.generate()
            let original = try writer.appendNotice(
                paneID: paneID, messageID: messageID, payloadJSON: "original", createdAt: fixture.createdAt
            ).get()

            let duplicate = try writer.appendNotice(
                paneID: paneID, messageID: messageID, payloadJSON: "must not replace original",
                createdAt: fixture.createdAt.addingTimeInterval(10)
            ).get()

            return (duplicate: duplicate, original: original, entries: try writer.readOutbox(after: 0).get().entries)
        }
        #expect(observed.duplicate == observed.original)
        #expect(observed.entries == [observed.original])
    }

    @Test("outbox ids keep increasing after every prior row has been purged")
    func deletedPrefixDoesNotReuseIDs() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let first = try fixture.append(to: writer)
            try writer.databaseQueue.write { database in
                try database.execute(sql: "DELETE FROM cli_outbox")
            }

            let second = try fixture.append(to: writer)

            return (first: first, second: second, entries: try writer.readOutbox(after: first.id).get().entries)
        }
        #expect(observed.second.id > observed.first.id)
        #expect(observed.entries == [observed.second])
    }

    @Test("an actual write through the app reader fails at the SQLite boundary")
    func readerCannotWrite() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let original = try fixture.append(to: writer)
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()

            let writeAttempt = Result<Void, any Error> {
                try reader.databaseQueue.writeWithoutTransaction { database in
                    try database.execute(sql: "DELETE FROM cli_outbox")
                }
            }
            let appendFailure = failure(
                in: reader.appendNotice(
                    paneID: UUIDv7.generate(), messageID: UUIDv7.generate(),
                    payloadJSON: "reader write", createdAt: fixture.createdAt))
            return (
                writeAttempt: writeAttempt, appendFailure: appendFailure,
                contents: (entries: try writer.readOutbox(after: 0).get().entries, original: original)
            )
        }
        #expect(throws: (any Error).self) { try observed.writeAttempt.get() }
        #expect(observed.appendFailure == .readOnly)
        #expect(observed.contents.entries == [observed.contents.original])
    }

    @Test("a reader never creates a missing store or its parent")
    func missingReaderFailsOpenWithoutCreatingFiles() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let missingURL = fixture.rootURL.appending(path: "absent/cli.sqlite")

            return (
                failure: failure(in: CLIStore.openReader(url: missingURL, expectedChannel: .debug)),
                parentExists: FileManager.default.fileExists(atPath: missingURL.deletingLastPathComponent().path)
            )
        }
        #expect(observed.failure == .unavailable)
        #expect(!observed.parentExists)
    }

    @Test("corruption is fail-open and the original bytes are preserved")
    func corruptStoreFailsOpenWithoutReplacement() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let corrupt = Data("not a SQLite database".utf8)
            try corrupt.write(to: fixture.databaseURL)

            return (
                writerFailure: failure(in: CLIStore.openWriter(url: fixture.databaseURL, channel: .debug)),
                readerFailure: failure(in: CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug)),
                bytes: (actual: try Data(contentsOf: fixture.databaseURL), expected: corrupt)
            )
        }
        #expect(observed.writerFailure == .unavailable)
        #expect(observed.readerFailure == .unavailable)
        #expect(observed.bytes.actual == observed.bytes.expected)
    }

    @Test("a store from a newer migrator disables writes and preserves its rows")
    func supersededWriterDoesNotTouchRows() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let original = try fixture.append(to: writer)
            var futureMigrator = CLIStoreMigrator.makeMigrator(channel: .debug)
            futureMigrator.registerMigration("003_future_cli_schema") { database in
                try database.execute(sql: "CREATE TABLE future_cli_table (value TEXT)")
            }
            try futureMigrator.migrate(writer.databaseQueue)

            return (
                failure: failure(in: CLIStore.openWriter(url: fixture.databaseURL, channel: .debug)),
                contents: (entries: try writer.readOutbox(after: 0).get().entries, original: original),
                hasFutureTable: try writer.databaseQueue.read { try $0.tableExists("future_cli_table") }
            )
        }
        #expect(observed.failure == .superseded)
        #expect(observed.contents.entries == [observed.contents.original])
        #expect(observed.hasFutureTable)
    }

    @Test("a held writer lock produces a typed busy outcome without a queued row")
    func heldWriteLockFailsOpen() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let holder = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            // GRDB owns this transaction's lifetime; leaving a manual BEGIN
            // open across queue calls violates its unsafe-transaction check.
            return try holder.databaseQueue.write { database in
                let outcome = writer.appendNotice(
                    paneID: UUIDv7.generate(), messageID: UUIDv7.generate(),
                    payloadJSON: "locked", createdAt: fixture.createdAt)

                return (
                    failure: failure(in: outcome),
                    rowCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM cli_outbox")
                )
            }
        }
        #expect(observed.rowCount == 0)
        let busyFailure = try #require(observed.failure)
        guard case .busy(let extendedResultCode, let stage) = busyFailure else {
            Issue.record("A held writer lock did not return SQLite busy")
            return
        }
        let code = try #require(extendedResultCode)
        #expect(code & 0xFF == 5)
        #expect(stage == .append)
    }

    @Test("writer and reader refuse a foreign channel without changing identity")
    func mismatchedChannelIsRefused() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let original = try CLIStore.openWriter(url: fixture.databaseURL, channel: .beta).get()

            return (
                writerFailure: failure(in: CLIStore.openWriter(url: fixture.databaseURL, channel: .stable)),
                readerFailure: failure(in: CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug)),
                identities: (
                    reopened: try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .beta).get().identity,
                    original: original.identity
                )
            )
        }
        #expect(observed.writerFailure == .channelMismatch)
        #expect(observed.readerFailure == .channelMismatch)
        #expect(observed.identities.reopened == observed.identities.original)
    }

    @Test("unknown identity channels fail closed instead of defaulting to stable")
    func unknownIdentityChannelIsRefused() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let original = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            try original.databaseQueue.write { database in
                try database.execute(sql: "UPDATE cli_store_identity SET channel = 'future-channel'")
            }

            return (
                writerFailure: failure(in: CLIStore.openWriter(url: fixture.databaseURL, channel: .debug)),
                readerFailure: failure(in: CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug))
            )
        }
        #expect(observed.writerFailure == .invalidIdentity)
        #expect(observed.readerFailure == .invalidIdentity)
    }

    @Test("unknown outbox kinds are skipped and logged with the field, while later notices survive")
    func unknownKindIsSkippedAndLogged() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let first = try fixture.append(to: writer)
            try writer.databaseQueue.write { database in
                try database.execute(
                    sql: "UPDATE cli_outbox SET kind = 'future-kind' WHERE id = ?", arguments: [first.id])
            }
            let second = try fixture.append(to: writer)
            let issues = Mutex<[CLIStoreDecodeIssue]>([])
            let reader = try CLIStore.openReader(
                url: fixture.databaseURL, expectedChannel: .debug,
                logDecodeIssue: { issue in issues.withLock { $0.append(issue) } }
            ).get()

            let batch = try reader.readOutbox(after: 0).get()

            return UnknownKindObservation(
                batch: batch, first: first, second: second, issues: issues.withLock { $0 },
                rowCount: try writer.databaseQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cli_outbox") }
            )
        }
        #expect(observed.batch.entries == [observed.second])
        #expect(observed.batch.lastReadID == observed.second.id)
        #expect(observed.issues == [.init(rowID: observed.first.id, field: .kind)])
        #expect(observed.rowCount == 2)
    }

    @Test("a skipped final row remains part of the read prefix")
    func skippedFinalRowStillReportsReadPosition() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            let last = try fixture.append(to: writer)
            try writer.databaseQueue.write { database in
                try database.execute(sql: "UPDATE cli_outbox SET kind = 'future-kind'")
            }

            let batch = try writer.readOutbox(after: 0).get()

            return (batch: batch, last: last, nextReadID: try writer.readOutbox(after: last.id).get().lastReadID)
        }
        #expect(observed.batch.entries.isEmpty)
        #expect(observed.batch.lastReadID == observed.last.id)
        #expect(observed.nextReadID == observed.last.id)
    }

    @Test("two real CLI writer processes preserve every successful append and monotonic ids")
    func multipleProcessesAppendToOneFile() async throws {
        let fixture = try CLIStoreFileFixture()
        defer { fixture.remove() }
        _ = try await valueFromDedicatedThread {
            try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
        }
        let executableURL = try fixture.processExecutableURL()

        async let first = runProcessToExit(
            executableURL: executableURL, arguments: [fixture.databaseURL.path, UUIDv7.generate().uuidString])
        async let second = runProcessToExit(
            executableURL: executableURL, arguments: [fixture.databaseURL.path, UUIDv7.generate().uuidString])
        let outputs = try await [first, second]

        var reportedIDs: [Int64] = []
        for output in outputs {
            let standardError = String(bytes: output.standardError, encoding: .utf8) ?? "<non-UTF8 stderr>"
            #expect(output.terminationStatus == 0, "stderr: \(standardError)")
            let standardOutput = try #require(String(bytes: output.standardOutput, encoding: .utf8))
            let lines = standardOutput.split(separator: "\n")
            #expect(lines.count == 16)
            #expect(lines.allSatisfy { $0 == "busy" || Int64($0) != nil })
            let successfulIDs = lines.compactMap { Int64($0) }
            #expect(successfulIDs == successfulIDs.sorted())
            reportedIDs.append(contentsOf: successfulIDs)
        }
        #expect(!reportedIDs.isEmpty)
        #expect(Set(reportedIDs).count == reportedIDs.count)
        let expectedIDs = reportedIDs.sorted()
        #expect(expectedIDs == Array(Int64(1)...Int64(max(1, expectedIDs.count))))
        let actualIDs = try await valueFromDedicatedThread {
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()
            return try reader.readOutbox(after: 0).get().entries.map(\.id)
        }
        #expect(actualIDs == expectedIDs)
    }
}

private struct StoreIdentityObservation: Sendable {
    let first: CLIStoreIdentity
    let second: CLIStoreIdentity
    let identityCount: Int?
    let hasOutbox: Bool
    let migrations: [String]
}

private struct PreviousVersionObservation: Sendable {
    let storedIdentity: String?
    let readerIdentity: CLIStoreIdentity
    let readerEntries: [CLIOutboxEntry]
    let previousMigrations: [String]
    let previousHasOutbox: Bool
    let writerIdentity: CLIStoreIdentity
    let writerHasOutbox: Bool
}

private struct NoticeRoundTripObservation: Sendable {
    let batch: CLIOutboxReadBatch
    let inserted: CLIOutboxEntry
    let paneID: UUID
    let messageID: UUID
    let createdAt: Date
    let laterEntries: [CLIOutboxEntry]
}

private struct UnknownKindObservation: Sendable {
    let batch: CLIOutboxReadBatch
    let first: CLIOutboxEntry
    let second: CLIOutboxEntry
    let issues: [CLIStoreDecodeIssue]
    let rowCount: Int?
}

private func failure<Value>(in result: Result<Value, CLIStoreFailure>) -> CLIStoreFailure? {
    switch result {
    case .success: nil
    case .failure(let failure): failure
    }
}

struct CLIStoreFileFixture: Sendable {
    let rootURL: URL
    let databaseURL: URL
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "cli-store-\(UUIDv7.generate().uuidString)")
        databaseURL = rootURL.appending(path: "cli.sqlite")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func append(to writer: CLIStore) throws -> CLIOutboxEntry {
        try writer.appendNotice(
            paneID: UUIDv7.generate(), messageID: UUIDv7.generate(),
            payloadJSON: #"{"jsonrpc":"2.0","method":"session.message"}"#, createdAt: createdAt
        ).get()
    }

    func processExecutableURL() throws -> URL {
        let buildDirectory = try #require(ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"])
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let buildURL =
            buildDirectory.hasPrefix("/")
            ? URL(fileURLWithPath: buildDirectory) : projectRoot.appending(path: buildDirectory)
        return buildURL.appending(path: "debug/agentstudio-cli-store-process-fixture")
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
