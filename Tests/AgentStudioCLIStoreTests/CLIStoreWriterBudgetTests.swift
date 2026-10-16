import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioCLIStore

extension CLIStoreTests {
    @Test(
        "migration exhaustion rolls back the identity-only schema and the next open recovers",
        arguments: MigrationBudgetExhaustionPoint.allCases)
    func migrationBudgetExhaustionRollsBack(point: MigrationBudgetExhaustionPoint) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try CLIStoreFileFixture()
            defer { fixture.remove() }
            try WriterBudgetSchema.identityOnly.seed(at: fixture.databaseURL)
            let original = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()
            let probe = MigrationBudgetExhaustionProbe(point: point)

            let attempted = CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug,
                migrationLockWaitBudget: { probe.remainingBudget },
                prepareConnection: { database in
                    database.trace { event in
                        guard case .statement(let statement) = event else { return }
                        probe.recordStatement(statement.sql)
                    }
                })

            let failure: CLIStoreFailure?
            switch attempted {
            case .failure(let value): failure = value
            case .success: failure = nil
            }
            let afterFailure = try CLIStore.openReader(url: fixture.databaseURL, expectedChannel: .debug).get()
            let failedState = try afterFailure.databaseQueue.read { database in
                MigrationSchemaObservation(
                    identity: afterFailure.identity,
                    identityCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM cli_store_identity"),
                    hasOutbox: try database.tableExists("cli_outbox"),
                    appliedIdentifiers: try CLIStoreMigrator.makeMigrator(channel: .debug).appliedIdentifiers(database))
            }
            let reachedExhaustion = probe.reachedExhaustion
            let migrationStatements = probe.migrationStatements
            probe.restoreBudget()
            let recovered = try CLIStore.openWriter(
                url: fixture.databaseURL, channel: .debug, migrationLockWaitBudget: { probe.remainingBudget }
            ).get()
            let recoveredState = try recovered.databaseQueue.read { database in
                MigrationSchemaObservation(
                    identity: recovered.identity,
                    identityCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM cli_store_identity"),
                    hasOutbox: try database.tableExists("cli_outbox"),
                    appliedIdentifiers: try CLIStoreMigrator.makeMigrator(channel: .debug).appliedIdentifiers(database))
            }
            return MigrationBudgetFailureObservation(
                failure: failure, originalIdentity: original.identity, reachedExhaustion: reachedExhaustion,
                migrationStatements: migrationStatements, failedState: failedState, recoveredState: recoveredState)
        }

        #expect(observed.reachedExhaustion)
        #expect(observed.failure == .busy(extendedResultCode: nil, stage: .migration))
        #expect(observed.migrationStatements.filter { $0 == "BEGIN IMMEDIATE TRANSACTION" }.count == 1)
        #expect(observed.migrationStatements.contains { $0.hasPrefix("ROLLBACK") })
        #expect(!observed.migrationStatements.contains { $0.hasPrefix("COMMIT") })
        switch point {
        case .lockAcquisition, .identityRead, .appliedIdentifiersRead:
            #expect(
                !observed.migrationStatements.contains {
                    $0.hasPrefix("CREATE TABLE") || $0.hasPrefix("INSERT INTO grdb_migrations")
                })
        case .migrationRecordWrite:
            #expect(observed.migrationStatements.contains { $0.hasPrefix("INSERT INTO grdb_migrations") })
        }
        #expect(observed.failedState.identity == observed.originalIdentity)
        #expect(observed.failedState.identityCount == 1)
        #expect(!observed.failedState.hasOutbox)
        #expect(observed.failedState.appliedIdentifiers == [CLIStoreMigrator.identityMigration])
        #expect(observed.recoveredState.identity == observed.originalIdentity)
        #expect(observed.recoveredState.identityCount == 1)
        #expect(observed.recoveredState.hasOutbox)
        #expect(observed.recoveredState.appliedIdentifiers == CLIStoreMigrator.knownMigrations)
    }

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
        let noticeTimeoutMutations = observed.afterOpenStatements.filter {
            $0.lowercased().hasPrefix("pragma busy_timeout =")
        }
        switch callBudget {
        case .belowCap, .aboveCap:
            #expect(noticeTimeoutMutations == ["PRAGMA busy_timeout = 50"])
        case .noDeadline:
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

enum MigrationBudgetExhaustionPoint: CaseIterable, Sendable {
    case lockAcquisition
    case identityRead
    case appliedIdentifiersRead
    case migrationRecordWrite

    func matches(_ sql: String) -> Bool {
        switch self {
        case .lockAcquisition: sql == "BEGIN IMMEDIATE TRANSACTION"
        case .identityRead: sql == "SELECT store_id, channel FROM cli_store_identity LIMIT 2"
        case .appliedIdentifiersRead: sql == "SELECT identifier FROM grdb_migrations"
        case .migrationRecordWrite: sql.hasPrefix("INSERT INTO grdb_migrations")
        }
    }
}

private final class MigrationBudgetExhaustionProbe: Sendable {
    private struct State: Sendable {
        var remainingBudget: Duration = .seconds(1)
        var insideMigration = false
        var reachedExhaustion = false
        var migrationStatements: [String] = []
    }

    private let state = Mutex(State())
    private let point: MigrationBudgetExhaustionPoint

    init(point: MigrationBudgetExhaustionPoint) { self.point = point }

    var remainingBudget: Duration { state.withLock { $0.remainingBudget } }
    var reachedExhaustion: Bool { state.withLock { $0.reachedExhaustion } }
    var migrationStatements: [String] { state.withLock { $0.migrationStatements } }

    func recordStatement(_ sql: String) {
        state.withLock { observation in
            if sql == "BEGIN IMMEDIATE TRANSACTION" { observation.insideMigration = true }
            guard observation.insideMigration else { return }
            observation.migrationStatements.append(sql)
            if point.matches(sql) {
                observation.remainingBudget = .zero
                observation.reachedExhaustion = true
            }
            if sql.hasPrefix("COMMIT") || sql.hasPrefix("ROLLBACK") { observation.insideMigration = false }
        }
    }

    func restoreBudget() { state.withLock { $0.remainingBudget = .seconds(1) } }
}

private struct MigrationSchemaObservation: Sendable {
    let identity: CLIStoreIdentity
    let identityCount: Int?
    let hasOutbox: Bool
    let appliedIdentifiers: Set<String>
}

private struct MigrationBudgetFailureObservation: Sendable {
    let failure: CLIStoreFailure?
    let originalIdentity: CLIStoreIdentity
    let reachedExhaustion: Bool
    let migrationStatements: [String]
    let failedState: MigrationSchemaObservation
    let recoveredState: MigrationSchemaObservation
}
