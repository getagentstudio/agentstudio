import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import GRDB
import SQLite3
import Synchronization
import Testing

@testable import AgentStudioCLIStore

@Suite("Lifecycle append lock budget")
struct CLILifecycleWriterBudgetTests {
    @Test("a real held SQLite lock exhausts the lifecycle append budget without a row")
    func busyLifecycleAppendExhaustsBudget() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let owner = try CLIStore.openWriter(url: fixture.databaseURL, channel: .debug).get()
            defer { try? owner.close() }
            let budget = LifecycleStoreBusyBudget()
            let writer = try CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                migrationLockWaitBudget: { budget.remaining },
                prepareConnection: { database in
                    let connection = database.sqliteConnection
                    database.trace { event in
                        guard case .statement(let statement) = event,
                            statement.sql.hasPrefix("BEGIN IMMEDIATE")
                        else { return }
                        sqlite3_busy_handler(
                            connection, lifecycleStoreBusyCallback, Unmanaged.passUnretained(budget).toOpaque())
                    }
                }
            ).get()
            defer { try? writer.close() }
            let blocker = try DatabaseQueue(path: fixture.databaseURL.path)
            defer { try? blocker.close() }
            let appended = try blocker.writeWithoutTransaction { database in
                var result: Result<CLIOutboxEntry, CLIStoreFailure> = .failure(.unavailable)
                try database.inTransaction(.immediate) {
                    result = writer.appendSessionLifecycle(
                        paneID: UUIDv7.generate(), messageID: UUIDv7.generate(), payloadJSON: "{}",
                        reportedAt: fixture.createdAt)
                    return .rollback
                }
                return result
            }
            let failure: CLIStoreFailure? = if case .failure(let failure) = appended { failure } else { nil }
            return (
                failure: failure, remaining: budget.remaining, busyCalls: budget.busyCalls,
                entries: try owner.readOutbox(after: 0).get().entries
            )
        }
        #expect(observed.busyCalls == 1)
        #expect(observed.remaining == .zero)
        #expect(observed.failure == .busy(extendedResultCode: 5, stage: .append))
        #expect(observed.entries.isEmpty)
    }
}

private final class LifecycleStoreBusyBudget: Sendable {
    private let state = Mutex((remaining: Duration.milliseconds(250), busyCalls: 0))
    var remaining: Duration { state.withLock { $0.remaining } }
    var busyCalls: Int { state.withLock { $0.busyCalls } }
    func exhaust() {
        state.withLock {
            $0.remaining = .zero
            $0.busyCalls += 1
        }
    }
}

private func lifecycleStoreBusyCallback(context: UnsafeMutableRawPointer?, attempts: Int32) -> Int32 {
    guard let context else { return 0 }
    Unmanaged<LifecycleStoreBusyBudget>.fromOpaque(context).takeUnretainedValue().exhaust()
    return 0
}
