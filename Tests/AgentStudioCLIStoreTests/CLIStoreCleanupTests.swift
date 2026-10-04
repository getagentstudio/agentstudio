import AgentStudioPrimitives
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCLIStore

@Suite("CLI store cleanup")
struct CLIStoreCleanupTests {
    @Test("only old handled rows are purged; unread rows survive any age")
    func cleanupKeepsRecentAndUnreadRows() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreCleanupFixture()
            defer { fixture.removeFiles() }
            let writer = try fixture.openWriter()
            let oldHandled = try fixture.append(to: writer)
            fixture.clock.advance(by: .seconds(43_200))
            let recentHandled = try fixture.append(to: writer)
            let unread = try fixture.append(to: writer, createdAt: fixture.originDate)
            fixture.clock.advance(by: .seconds(43_201))
            let firstRemoved = try writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: recentHandled.id, now: fixture.now
            ).get()
            let firstRows = try writer.readOutbox(after: 0).get().entries
            fixture.clock.advance(by: .seconds(30 * 86_400))
            let laterRemoved = try writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: recentHandled.id, now: fixture.now
            ).get()
            let laterRows = try writer.readOutbox(after: 0).get().entries
            return (
                oldHandled: oldHandled, recentHandled: recentHandled, unread: unread,
                firstRemoved: firstRemoved, firstRows: firstRows, laterRemoved: laterRemoved, laterRows: laterRows
            )
        }
        #expect(observed.firstRemoved == 1)
        #expect(observed.firstRows == [observed.recentHandled, observed.unread])
        #expect(observed.oldHandled.id < observed.recentHandled.id)
        #expect(observed.laterRemoved == 1)
        #expect(observed.laterRows == [observed.unread])
    }

    @Test("a handled row is kept at one day and removed only once older")
    func cleanupUsesStrictRetentionBoundary() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreCleanupFixture()
            defer { fixture.removeFiles() }
            let writer = try fixture.openWriter()
            let entry = try fixture.append(to: writer)
            fixture.clock.advance(by: .seconds(86_400))
            let atBoundary = try writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: entry.id, now: fixture.now
            ).get()
            let boundaryRows = try writer.readOutbox(after: 0).get().entries
            fixture.clock.advance(by: .seconds(1))
            let afterBoundary = try writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: entry.id, now: fixture.now
            ).get()
            let laterRows = try writer.readOutbox(after: 0).get().entries
            return (
                entry: entry, atBoundary: atBoundary, boundaryRows: boundaryRows,
                afterBoundary: afterBoundary, laterRows: laterRows
            )
        }
        #expect(observed.atBoundary == 0)
        #expect(observed.boundaryRows == [observed.entry])
        #expect(observed.afterBoundary == 1)
        #expect(observed.laterRows.isEmpty)
    }

    @Test(
        "foreign or replaced stores with overlapping ids cannot consume another store's mark",
        arguments: [false, true])
    func cleanupRefusesAnotherStoreIdentity(replacedFile: Bool) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreCleanupFixture()
            defer { fixture.removeFiles() }
            let original = try fixture.openWriter()
            let appRead = try fixture.append(to: original)
            let appStoreID = original.identity.storeID
            try original.databaseQueue.close()
            let writerURL: URL
            if replacedFile {
                try FileManager.default.moveItem(
                    at: fixture.storeURL, to: fixture.rootURL.appending(path: "old.sqlite"))
                writerURL = fixture.storeURL
            } else {
                writerURL = fixture.rootURL.appending(path: "foreign.sqlite")
            }
            let writer = try CLIStore.openWriter(url: writerURL, channel: .debug).get()
            let unread = try fixture.append(to: writer)
            fixture.clock.advance(by: .seconds(2 * 86_400))
            let removed = try writer.purgeHandledOutbox(
                expectedStoreID: appStoreID, through: appRead.id, now: fixture.now
            ).get()
            let rows = try writer.readOutbox(after: 0).get().entries
            return (
                writerStoreID: writer.identity.storeID, appStoreID: appStoreID,
                unread: unread, appRead: appRead, removed: removed, rows: rows
            )
        }
        #expect(observed.writerStoreID != observed.appStoreID)
        #expect(observed.unread.id == observed.appRead.id)
        #expect(observed.removed == 0)
        #expect(observed.rows == [observed.unread])
    }

    @Test("an empty handled prefix never deletes old unread notices")
    func zeroReadThroughKeepsUnreadRows() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreCleanupFixture()
            defer { fixture.removeFiles() }
            let writer = try fixture.openWriter()
            let unread = try fixture.append(to: writer)
            fixture.clock.advance(by: .seconds(60 * 86_400))
            let removed = try writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: 0, now: fixture.now
            ).get()
            let rows = try writer.readOutbox(after: 0).get().entries
            return (unread: unread, removed: removed, rows: rows)
        }
        #expect(observed.removed == 0)
        #expect(observed.rows == [observed.unread])
    }

    @Test("the app's readonly handle cannot purge even a fully handled old row")
    func readonlyStoreCannotPurge() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreCleanupFixture()
            defer { fixture.removeFiles() }
            let writer = try fixture.openWriter()
            let writableControl = try fixture.append(to: writer)
            let entry = try fixture.append(to: writer)
            fixture.clock.advance(by: .seconds(2 * 86_400))
            let writableRemoved = try writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: writableControl.id, now: fixture.now
            ).get()
            let reader = try CLIStore.openReader(url: fixture.storeURL, expectedChannel: .debug).get()
            let readonlyResult = reader.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: entry.id, now: fixture.now)
            let sqlError: DatabaseError?
            do {
                try reader.databaseQueue.write { database in try database.execute(sql: "DELETE FROM cli_outbox") }
                sqlError = nil
            } catch let error as DatabaseError {
                sqlError = error
            }
            let rows = try reader.readOutbox(after: 0).get().entries
            return (
                writableRemoved: writableRemoved, readonlyResult: readonlyResult,
                sqlError: sqlError, rows: rows, entry: entry
            )
        }
        #expect(observed.writableRemoved == 1)
        #expect(observed.readonlyResult == .failure(.readOnly))
        let sqlError = try #require(observed.sqlError)
        #expect(sqlError.resultCode == .SQLITE_READONLY)
        #expect(observed.rows == [observed.entry])
    }
}

private struct CLIStoreCleanupFixture: Sendable {
    let rootURL: URL
    let storeURL: URL
    let clock = TestPushClock()
    let originDate = Date(timeIntervalSince1970: 1_700_000_000)
    let originInstant: TestPushClock.Instant

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "cli-cleanup-\(UUIDv7.generate())")
        storeURL = rootURL.appending(path: "cli.sqlite")
        originInstant = clock.now
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    var now: Date {
        let elapsed = originInstant.duration(to: clock.now).components
        return originDate.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    func openWriter() throws -> CLIStore { try CLIStore.openWriter(url: storeURL, channel: .debug).get() }

    func append(to writer: CLIStore, createdAt: Date? = nil) throws -> CLIOutboxEntry {
        try writer.appendNotice(
            paneID: UUIDv7.generate(), messageID: UUIDv7.generate(), payloadJSON: "{}", createdAt: createdAt ?? now
        ).get()
    }

    func removeFiles() { try? FileManager.default.removeItem(at: rootURL) }
}
