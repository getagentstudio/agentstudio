import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCLIStore

extension CLIStoreTests {
    @Test(
        "writer open refreshes its remaining timeout through verification and caps notice writes at 50 ms",
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
            let restoration = try #require(timeoutMutations.first { $0.element == "PRAGMA busy_timeout = 50" })
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
            let checkpointsPrivateStore = initialSchema == .missing && index == 0
            #expect(timeoutMutations.count == 4 + (migrates ? 1 : 0) + (checkpointsPrivateStore ? 1 : 0))
            for mutation in timeoutMutations where mutation.offset != restoration.offset {
                #expect(mutation.element == "PRAGMA busy_timeout = \(callBudget.expectedMilliseconds)")
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
        #expect(
            observed.afterOpenStatements.filter { $0.lowercased().hasPrefix("pragma busy_timeout =") }
                == ["PRAGMA busy_timeout = 50"])
        switch observed.notice {
        case .notice(let notice):
            #expect(notice.id > 0)
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
