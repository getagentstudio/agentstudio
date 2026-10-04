import AgentStudioInfrastructure
import Foundation
import GRDB

@testable import AgentStudioCore
@testable import AgentStudioSessions

enum SessionsTestError: Error {
    case unexpectedOutcome(String)
}

func makeSessionsSnapshotQuery(paneId: UUID) -> SessionsSnapshotQuery {
    SessionsSnapshotQuery(paneId: paneId)
}

struct SessionsDatabaseFixture {
    let databaseQueue: DatabaseQueue
    let sqliteAccess: TestSessionsSQLiteAccess

    init() throws {
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(
            label: "AgentStudio.sqlite.sessions-tests"
        )
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        self.databaseQueue = databaseQueue
        sqliteAccess = TestSessionsSQLiteAccess(databaseQueue: databaseQueue)
    }

    func makeRepository() -> SessionsRepository {
        SessionsRepository(sqliteAccess: sqliteAccess)
    }

    func rejectLossWrites() async throws {
        try await sqliteAccess.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_sessions_loss
                    BEFORE INSERT ON sessions_loss
                    BEGIN
                        SELECT RAISE(ABORT, 'forced sessions loss failure');
                    END
                    """
            )
        }
    }
}

struct SessionsFileDatabaseFixture {
    let rootDirectory: URL
    let databaseURL: URL

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-sessions-\(UUIDv7.generate())")
        databaseURL = rootDirectory.appending(path: "local.sqlite")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func makeRepository() throws -> SessionsRepository {
        let databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        return SessionsRepository(
            sqliteAccess: TestSessionsSQLiteAccess(databaseQueue: databaseQueue)
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

struct TestSessionsSQLiteAccess: SessionsSQLiteAccess {
    let databaseQueue: DatabaseQueue

    func read<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await databaseQueue.read(operation)
    }

    func write<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await databaseQueue.write(operation)
    }
}

func withSessionsIngestion<Output: Sendable>(
    repository: SessionsRepository,
    operation: @Sendable (SessionsIngestion) async throws -> Output
) async throws -> Output {
    let ingestion = SessionsIngestion(
        repository: repository,
        limits: SessionsIngestionLimits(
            maximumPendingPerPane: 32,
            maximumPendingGlobal: 128
        ),
        probe: { _ in }
    )
    do {
        let output = try await operation(ingestion)
        await ingestion.finish()
        return output
    } catch {
        await ingestion.finish()
        throw error
    }
}

func withOwnedSessionsIngestion<Output: Sendable>(
    _ ingestion: SessionsIngestion,
    operation: @Sendable (SessionsIngestion) async throws -> Output
) async throws -> Output {
    do {
        let output = try await operation(ingestion)
        await ingestion.finish()
        return output
    } catch {
        await ingestion.finish()
        throw error
    }
}

actor FirstWriteBarrierSessionsSQLiteAccess: SessionsSQLiteAccess {
    private let base: TestSessionsSQLiteAccess
    private var blocksNextWrite = true
    private var firstWriteStarted = false
    private var firstWriteReleased = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: TestSessionsSQLiteAccess) {
        self.base = base
    }

    func read<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await base.read(operation)
    }

    func write<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        if blocksNextWrite {
            blocksNextWrite = false
            firstWriteStarted = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !firstWriteReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        return try await base.write(operation)
    }

    func waitUntilFirstWriteStarts() async {
        if firstWriteStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        firstWriteReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

final class SessionsIngestionProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var maximumPaneDepthStorage = 0
    private var maximumGlobalDepthStorage = 0

    func record(_ statistics: SessionsIngestionStatistics) {
        lock.lock()
        maximumPaneDepthStorage = max(maximumPaneDepthStorage, statistics.pendingForPane)
        maximumGlobalDepthStorage = max(maximumGlobalDepthStorage, statistics.pendingGlobal)
        lock.unlock()
    }

    var maximumPaneDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumPaneDepthStorage
    }

    var maximumGlobalDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumGlobalDepthStorage
    }
}

func makeSessionsEvidence(
    conversationId: UUID,
    bindingGenerationId: UUID,
    sourceGenerationId: UUID,
    turnId: String = "turn-root",
    subject: SessionsEvidenceSubject = .root,
    kind: SessionsEvidenceKind,
    origin: SessionsEvidenceOrigin,
    freshness: SessionsEvidenceFreshness = .live,
    timestamp: TimeInterval
) -> SessionsEvidenceRecord {
    SessionsEvidenceRecord(
        occurrenceId: UUIDv7.generate(),
        conversationId: conversationId,
        bindingGenerationId: bindingGenerationId,
        sourceGenerationId: sourceGenerationId,
        turnId: turnId,
        subject: subject,
        kind: kind,
        origin: origin,
        freshness: freshness,
        occurredAt: Date(timeIntervalSince1970: timestamp)
    )
}

func makeQualifiedBindMutation(
    paneId: UUID,
    providerConversationId: String,
    sourceGenerationId: UUID,
    occurrenceId: UUID = UUIDv7.generate(),
    freshness: SessionsEvidenceFreshness = .live,
    reportedAt: TimeInterval
) -> SessionsBindMutation {
    SessionsBindMutation(
        paneId: paneId,
        providerIdentifier: "qualified-test-provider",
        providerVersion: "1.0.0",
        providerMode: "test",
        providerConversationId: providerConversationId,
        sourceId: "qualified-source",
        sourceGenerationId: sourceGenerationId,
        transition: .qualifiedSessionStart(occurrenceId: occurrenceId),
        freshness: freshness,
        reportedAt: Date(timeIntervalSince1970: reportedAt)
    )
}

func makeSessionsEvidenceMutation(
    paneId: UUID, sourceGenerationId: UUID, kind: SessionsEvidenceKind,
    occurrenceId: UUID = UUIDv7.generate(), at timestamp: TimeInterval
) -> SessionsEvidenceMutation {
    SessionsEvidenceMutation(
        context: .sourceGeneration(paneId: paneId, sourceGenerationId: sourceGenerationId),
        occurrenceId: occurrenceId, turnId: "turn-test", subject: .root, kind: kind,
        origin: .reported, freshness: .live, occurredAt: Date(timeIntervalSince1970: timestamp), sourceCursor: nil)
}
