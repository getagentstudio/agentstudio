import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioCLIStore

@Suite("Lifecycle rows in the existing outbox")
struct CLILifecycleReportStoreTests {
    @Test("captured time is floored through the real writer and codec; notices keep their rounding")
    func floorsCapturedTime() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            defer { try? writer.close() }
            let pane = UUIDv7.generate()
            let reportId = UUIDv7.generate()
            let captured = Date(timeIntervalSince1970: 1.0006)
            let original = try writer.appendSessionLifecycle(
                paneID: pane, messageID: reportId, payloadJSON: "original", reportedAt: captured
            ).get()
            let duplicate = try writer.appendSessionLifecycle(
                paneID: pane, messageID: reportId, payloadJSON: "changed", reportedAt: Date()
            ).get()
            let notice = try writer.appendNotice(
                paneID: pane, messageID: UUIDv7.generate(), payloadJSON: "notice", createdAt: captured
            ).get()
            let reader = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()
            defer { try? reader.close() }
            let batch = try reader.readOutbox(after: 0).get()
            let readonly = reader.appendSessionLifecycle(
                paneID: pane, messageID: UUIDv7.generate(), payloadJSON: "refused", reportedAt: captured)
            let milliseconds = try writer.databaseQueue.read {
                try Int64.fetchAll($0, sql: "SELECT created_at FROM cli_outbox ORDER BY id")
            }
            return (
                originalEntry: original, duplicateEntry: duplicate, noticeEntry: notice, readBatch: batch,
                readerWrite: readonly, storedMilliseconds: milliseconds
            )
        }
        #expect(observed.originalEntry == observed.duplicateEntry)
        #expect(observed.readBatch.entries == [observed.originalEntry, observed.noticeEntry])
        #expect(observed.storedMilliseconds == [1000, 1001])
        guard case .sessionLifecycle(let report) = observed.originalEntry else {
            Issue.record("Missing lifecycle row")
            return
        }
        #expect(report.reportedAt == Date(timeIntervalSince1970: 1))
        #expect(report.payloadJSON == "original")
        #expect(UUIDv7.isV7(report.messageID))
        guard case .failure(.readOnly) = observed.readerWrite else {
            Issue.record("Reader admitted a write")
            return
        }
    }

    @Test("purging handled rows preserves an unhandled lifecycle report")
    func unreadLifecycleSurvivesPurge() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let writer = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            defer { try? writer.close() }
            let first = try writer.appendSessionLifecycle(
                paneID: UUIDv7.generate(), messageID: UUIDv7.generate(), payloadJSON: "handled",
                reportedAt: Date(timeIntervalSince1970: 1)
            ).get()
            let unread = try writer.appendSessionLifecycle(
                paneID: UUIDv7.generate(), messageID: UUIDv7.generate(), payloadJSON: "unread",
                reportedAt: Date(timeIntervalSince1970: 2)
            ).get()
            let removed = try writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: first.id,
                now: Date(timeIntervalSince1970: 200_000)
            ).get()
            return (removed: removed, entries: try writer.readOutbox(after: 0).get().entries, unread: unread)
        }
        #expect(observed.removed == 1)
        #expect(observed.entries == [observed.unread])
    }
}
