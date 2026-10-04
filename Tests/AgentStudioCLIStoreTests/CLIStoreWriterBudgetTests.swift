import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCLIStore

extension CLIStoreTests {
    @Test(
        "writer open retains its bounded timeout through verification and restores 50 ms before notice writes",
        arguments: WriterBudgetSchema.allCases, WriterCallBudget.allCases
    )
    func writerBudgetCoversOpenAndMigration(
        initialSchema: WriterBudgetSchema, callBudget: WriterCallBudget
    ) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            try initialSchema.seed(at: fixture.databaseURL)
            let connections = Mutex<[WriterBudgetTrace]>([])

            let writer = try CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                migrationLockWaitBudget: { callBudget.remaining },
                prepareConnection: { database in
                    // GRDB invokes preparation after installing the busy handler,
                    // before format validation or CLIStore's first admission read.
                    let milliseconds = try Int.fetchOne(database, sql: "PRAGMA busy_timeout")
                    let trace = WriterBudgetTrace()
                    trace.recordInitialTimeout(milliseconds)
                    database.trace { event in
                        guard case .statement(let statement) = event else { return }
                        // Observation only: never execute nested SQL in the trace callback.
                        trace.recordStatement(statement.sql)
                    }
                    connections.withLock { $0.append(trace) }
                }
            ).get()
            defer {
                writer.databaseQueue.writeWithoutTransaction { $0.trace(options: []) }
            }
            let traces = connections.withLock { $0 }
            guard let returnedTrace = traces.last else { throw WriterBudgetObservationError.missingConnection }
            let opening = traces.map { $0.snapshot() }
            let returnedOpening = returnedTrace.snapshot()
            let beforeNotice = try writer.databaseQueue.read { database in
                try Int.fetchOne(database, sql: "PRAGMA busy_timeout")
            }
            let notice = try fixture.append(to: writer)
            let complete = returnedTrace.snapshot()
            let afterNotice = try writer.databaseQueue.read { database in
                try Int.fetchOne(database, sql: "PRAGMA busy_timeout")
            }
            return WriterBudgetObservation(
                opening: opening,
                afterOpenStatements: Array(complete.statements.dropFirst(returnedOpening.statements.count)),
                beforeNotice: beforeNotice, afterNotice: afterNotice, notice: notice)
        }

        switch initialSchema {
        case .missing:
            #expect(observed.opening.count == 2)
        case .identityOnly, .current:
            #expect(observed.opening.count == 1)
        }
        for (index, opening) in observed.opening.enumerated() {
            // Pin each real connection: the private creator and published writer,
            // or the sole connection for an existing store.
            #expect(opening.initialTimeout == callBudget.expectedMilliseconds)
            let statements = opening.statements
            let timeoutMutations = statements.enumerated().filter { _, sql in
                sql.lowercased().hasPrefix("pragma busy_timeout =")
            }
            #expect(timeoutMutations.count == 1)
            let restoration = try #require(timeoutMutations.first)
            #expect(restoration.element == "PRAGMA busy_timeout = 50")
            let identityVerification = try #require(
                statements.lastIndex(of: "SELECT store_id, channel FROM cli_store_identity LIMIT 2"))
            let schemaVerification = try #require(
                statements.lastIndex(of: "SELECT identifier FROM grdb_migrations"))
            #expect(restoration.offset > identityVerification)
            #expect(restoration.offset > schemaVerification)
            let outboxCreation = statements.firstIndex { $0.hasPrefix("CREATE TABLE cli_outbox") }
            let migrationBegin = statements.firstIndex(of: "BEGIN IMMEDIATE TRANSACTION")
            let migrates: Bool
            switch initialSchema {
            case .missing, .identityOnly: migrates = index == 0
            case .current: migrates = false
            }
            if migrates {
                let creation = try #require(outboxCreation)
                let begin = try #require(migrationBegin)
                #expect(begin < creation)
                #expect(creation < identityVerification)
                #expect(creation < restoration.offset)
            } else {
                #expect(outboxCreation == nil)
                #expect(migrationBegin == nil)
                #expect(!statements.contains("PRAGMA journal_mode = WAL"))
            }
        }
        #expect(observed.beforeNotice == 50)
        #expect(observed.afterNotice == 50)
        #expect(observed.afterOpenStatements.contains { $0.hasPrefix("INSERT INTO cli_outbox") })
        let noticeTimeoutMutations = observed.afterOpenStatements.filter {
            $0.lowercased().hasPrefix("pragma busy_timeout =")
        }
        switch callBudget {
        case .belowCap, .aboveCap:
            // Both remaining call budgets exceed the ordinary write cap.
            #expect(noticeTimeoutMutations == ["PRAGMA busy_timeout = 50"])
        case .noDeadline:
            // With no original call budget, the configured ordinary cap remains in force.
            #expect(noticeTimeoutMutations.isEmpty)
        }
        switch observed.notice {
        case .notice(let notice):
            #expect(notice.id > 0)
        }
    }

    @Test(
        "append and purge clip the ordinary timeout to remaining budget and refuse exhaustion",
        arguments: [17, 375, 0])
    func noticeWritesClipRemainingBudget(remainingMilliseconds: Int) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            let remaining = Mutex<Duration?>(.seconds(1))
            let writer = try CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                migrationLockWaitBudget: { remaining.withLock { $0 } }
            ).get()
            defer { try? writer.close() }
            let original = try fixture.append(to: writer)
            let trace = WriterBudgetTrace()
            writer.databaseQueue.writeWithoutTransaction { database in
                database.trace { event in
                    guard case .statement(let statement) = event else { return }
                    trace.recordStatement(statement.sql)
                }
            }
            defer { writer.databaseQueue.writeWithoutTransaction { $0.trace(options: []) } }
            remaining.withLock { $0 = .milliseconds(remainingMilliseconds) }
            let appended = writer.appendNotice(
                paneID: UUIDv7.generate(), messageID: UUIDv7.generate(),
                payloadJSON: "budgeted append", createdAt: fixture.createdAt)
            let purged = writer.purgeHandledOutbox(
                expectedStoreID: writer.identity.storeID, through: original.id,
                now: fixture.createdAt.addingTimeInterval(CLIStorePolicy.handledRetention + 1))
            let appendFailure: CLIStoreFailure? = if case .failure(let failure) = appended { failure } else { nil }
            let purgeFailure: CLIStoreFailure? = if case .failure(let failure) = purged { failure } else { nil }
            let purgedCount: Int? = if case .success(let count) = purged { count } else { nil }
            let entries = try writer.readOutbox(after: 0).get().entries
            let timeoutMutations = trace.snapshot().statements.filter {
                $0.lowercased().hasPrefix("pragma busy_timeout =")
            }
            return (
                appendFailure: appendFailure, purgeFailure: purgeFailure, purgedCount: purgedCount,
                timeoutMutations: timeoutMutations, entries: entries, original: original
            )
        }
        if remainingMilliseconds == 0 {
            #expect(observed.appendFailure == .busy(extendedResultCode: nil, stage: .append))
            #expect(observed.purgeFailure == .busy(extendedResultCode: nil, stage: .purge))
            #expect(observed.timeoutMutations.isEmpty)
            #expect(observed.purgedCount == nil)
            #expect(observed.entries == [observed.original])
        } else {
            let expectedMilliseconds = min(50, remainingMilliseconds)
            #expect(observed.appendFailure == nil)
            #expect(observed.purgeFailure == nil)
            #expect(
                observed.timeoutMutations == [
                    "PRAGMA busy_timeout = \(expectedMilliseconds)", "PRAGMA busy_timeout = \(expectedMilliseconds)",
                ])
            #expect(observed.purgedCount == 1)
            #expect(observed.entries.count == 1)
            #expect(!observed.entries.contains(observed.original))
        }
    }
}

enum WriterBudgetSchema: CaseIterable, Sendable {
    case missing
    case identityOnly
    case current

    func seed(at url: URL) throws {
        switch self {
        case .missing:
            return
        case .identityOnly:
            let databaseQueue = try DatabaseQueue(path: url.path)
            try CLIStoreMigrator.makeMigrator(channel: .debug).migrate(
                databaseQueue, upTo: CLIStoreMigrator.identityMigration)
        case .current:
            _ = try CLIStore.openWriter(url: url, channel: .debug).get()
        }
    }
}

enum WriterCallBudget: CaseIterable, Sendable {
    case belowCap
    case aboveCap
    case noDeadline

    var remaining: Duration? {
        switch self {
        case .belowCap: .milliseconds(375)
        case .aboveCap: .seconds(2)
        case .noDeadline: nil
        }
    }

    var expectedMilliseconds: Int {
        switch self {
        case .belowCap: 375
        case .aboveCap, .noDeadline: 1000
        }
    }
}

private struct WriterBudgetSnapshot: Sendable {
    var initialTimeout: Int?
    var statements: [String] = []
}

private final class WriterBudgetTrace: Sendable {
    private let observations = Mutex(WriterBudgetSnapshot())

    func recordInitialTimeout(_ milliseconds: Int?) {
        observations.withLock { $0.initialTimeout = milliseconds }
    }

    func recordStatement(_ sql: String) {
        observations.withLock { $0.statements.append(sql) }
    }

    func snapshot() -> WriterBudgetSnapshot {
        observations.withLock { $0 }
    }
}

private struct WriterBudgetObservation: Sendable {
    let opening: [WriterBudgetSnapshot]
    let afterOpenStatements: [String]
    let beforeNotice: Int?
    let afterNotice: Int?
    let notice: CLIOutboxEntry
}

private enum WriterBudgetObservationError: Error {
    case missingConnection
}
