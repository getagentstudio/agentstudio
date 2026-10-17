import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("EntityRecencyStore", .serialized)
struct EntityRecencyStoreTests {
    @Test("persisted entity recency contains stable identity without its raw path")
    func persistedApplicationRecencyContainsNoRawPath() throws {
        let rawPath = "/private/command-bar-recency/persistence-sentinel"
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let repository = WorkspaceLocalRepository(
            workspaceId: UUID(),
            databaseWriter: databaseQueue
        )
        let stableKey = StableKey.fromPath(URL(filePath: rawPath))
        try repository.replaceApplicationEntityRecency([
            ApplicationEntityRecency(
                entity: .repository(repositoryStableKey: stableKey),
                interaction: .opened,
                lastInteractedAt: Date(timeIntervalSince1970: 100)
            )
        ])

        let persistedText = try databaseQueue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT entity_kind, entity_key, interaction_kind
                    FROM local_entity_recency
                    """
            )
            .flatMap { row in
                [
                    row["entity_kind"] as String,
                    row["entity_key"] as String,
                    row["interaction_kind"] as String,
                ]
            }
            .joined(separator: "|")
        }

        #expect(persistedText.contains(stableKey))
        #expect(!persistedText.contains(rawPath))
    }

    @Test("both recency lanes round trip in one database with independent workspace cleanup")
    func bothLanesRoundTripWithWorkspaceIsolationAndCleanup() throws {
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let firstRepository = WorkspaceLocalRepository(
            workspaceId: firstWorkspaceID,
            databaseWriter: databaseQueue
        )
        let secondRepository = WorkspaceLocalRepository(
            workspaceId: secondWorkspaceID,
            databaseWriter: databaseQueue
        )
        let applicationRecency = try [
            ApplicationEntityRecency(
                entity: .repository(repositoryStableKey: "aaaaaaaaaaaaaaaa"),
                interaction: .opened,
                lastInteractedAt: Date(timeIntervalSince1970: 300)
            ),
            ApplicationEntityRecency(
                entity: .worktree(worktreeStableKey: "bbbbbbbbbbbbbbbb"),
                interaction: .opened,
                lastInteractedAt: Date(timeIntervalSince1970: 300)
            ),
        ]
        let firstWorkspaceRecency = try [
            WorkspaceEntityRecency(
                workspaceID: firstWorkspaceID,
                entity: .pane(paneID: UUID()),
                interaction: .focused,
                lastInteractedAt: Date(timeIntervalSince1970: 200)
            )
        ]
        let secondWorkspaceRecency = try [
            WorkspaceEntityRecency(
                workspaceID: secondWorkspaceID,
                entity: .pane(paneID: UUID()),
                interaction: .focused,
                lastInteractedAt: Date(timeIntervalSince1970: 100)
            )
        ]

        try firstRepository.replaceApplicationEntityRecency(applicationRecency)
        try firstRepository.replaceWorkspaceEntityRecency(firstWorkspaceRecency)
        try secondRepository.replaceWorkspaceEntityRecency(secondWorkspaceRecency)

        #expect(try secondRepository.fetchApplicationEntityRecency() == applicationRecency)
        #expect(try firstRepository.fetchWorkspaceEntityRecency() == firstWorkspaceRecency)
        #expect(try secondRepository.fetchWorkspaceEntityRecency() == secondWorkspaceRecency)

        try firstRepository.deleteWorkspaceEntityRecency()

        #expect(try firstRepository.fetchWorkspaceEntityRecency().isEmpty)
        #expect(try secondRepository.fetchWorkspaceEntityRecency() == secondWorkspaceRecency)
        #expect(try firstRepository.fetchApplicationEntityRecency() == applicationRecency)
    }

    @Test("malformed rows skip individually while valid application and workspace rows survive")
    func malformedRowsSkipIndividually() throws {
        let workspaceID = UUID()
        let paneID = UUID()
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceLocalMigrations.migrate(databaseQueue)
        let repository = WorkspaceLocalRepository(
            workspaceId: workspaceID,
            databaseWriter: databaseQueue
        )
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO local_entity_recency(
                        entity_kind, entity_key, interaction_kind, last_interacted_at
                    ) VALUES
                        ('repository', 'aaaaaaaaaaaaaaaa', 'opened', 200),
                        ('future', 'bbbbbbbbbbbbbbbb', 'opened', 190),
                        ('worktree', 'not-a-stable-key', 'opened', 180),
                        ('repository', 'cccccccccccccccc', 'focused', 170),
                        ('repository', 'dddddddddddddddd', 'opened', ?)
                    """,
                arguments: [Double.infinity]
            )
            try database.execute(
                sql: """
                    INSERT INTO local_workspace_entity_recency(
                        workspace_id, entity_kind, entity_key, interaction_kind, last_interacted_at
                    ) VALUES
                        (?, 'pane', ?, 'focused', 200),
                        (?, 'future', ?, 'focused', 190),
                        (?, 'pane', 'not-a-uuid', 'focused', 180),
                        (?, 'pane', ?, 'opened', 170)
                    """,
                arguments: [
                    workspaceID.uuidString,
                    paneID.uuidString,
                    workspaceID.uuidString,
                    UUID().uuidString,
                    workspaceID.uuidString,
                    workspaceID.uuidString,
                    UUID().uuidString,
                ]
            )
        }

        let applicationRows = try repository.fetchApplicationEntityRecency()
        let workspaceRows = try repository.fetchWorkspaceEntityRecency()

        #expect(applicationRows.map(\.entity) == [.repository(repositoryStableKey: "aaaaaaaaaaaaaaaa")])
        #expect(workspaceRows.map(\.entity) == [.pane(paneID: paneID)])
    }

    @Test("application persistence retains every identity inside the activity horizon")
    func applicationPersistenceRetainsActivityHorizon() throws {
        let workspaceID = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceID)
        let atom = ApplicationEntityRecencyAtom(
            now: { Date(timeIntervalSince1970: 16) }
        )
        for index in 0..<16 {
            atom.record(
                try ApplicationEntityRecency(
                    entity: .repository(repositoryStableKey: String(format: "%016x", index)),
                    interaction: .opened,
                    lastInteractedAt: Date(timeIntervalSince1970: Double(index))
                )
            )
            atom.record(
                try ApplicationEntityRecency(
                    entity: .worktree(worktreeStableKey: String(format: "%016x", index + 100)),
                    interaction: .opened,
                    lastInteractedAt: Date(timeIntervalSince1970: Double(index))
                )
            )
        }

        try fixture.repository.replaceApplicationEntityRecency(atom.recentEntities)

        let countsByKind = try fixture.databaseQueue.read { database in
            try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(
                    database,
                    sql: """
                        SELECT entity_kind, COUNT(*) AS row_count
                        FROM local_entity_recency
                        GROUP BY entity_kind
                        """
                ).map { row in
                    (row["entity_kind"] as String, row["row_count"] as Int)
                }
            )
        }
        #expect(countsByKind == ["repository": 16, "worktree": 16])
    }

    @Test("application snapshot replacement is transactional across repository and worktree facts")
    func applicationSnapshotReplacementIsTransactional() throws {
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: UUID())
        let originalRecency = try ApplicationEntityRecency(
            entity: .repository(repositoryStableKey: "aaaaaaaaaaaaaaaa"),
            interaction: .opened,
            lastInteractedAt: Date(timeIntervalSince1970: 100)
        )
        try fixture.repository.replaceApplicationEntityRecency([originalRecency])
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_worktree_recency
                    BEFORE INSERT ON local_entity_recency
                    WHEN NEW.entity_kind = 'worktree'
                    BEGIN
                        SELECT RAISE(ABORT, 'reject worktree recency');
                    END
                    """
            )
        }
        let replacement = try [
            ApplicationEntityRecency(
                entity: .repository(repositoryStableKey: "bbbbbbbbbbbbbbbb"),
                interaction: .opened,
                lastInteractedAt: Date(timeIntervalSince1970: 200)
            ),
            ApplicationEntityRecency(
                entity: .worktree(worktreeStableKey: "cccccccccccccccc"),
                interaction: .opened,
                lastInteractedAt: Date(timeIntervalSince1970: 200)
            ),
        ]

        #expect(throws: (any Error).self) {
            try fixture.repository.replaceApplicationEntityRecency(replacement)
        }

        #expect(try fixture.repository.fetchApplicationEntityRecency() == [originalRecency])
    }

    @Test("database preparation reports local replacement before recency loads")
    func databasePreparationReportsLocalReplacementBeforeRecencyLoads() async throws {
        let workspaceID = UUID()
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-entity-recency-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let datastore = WorkspaceSQLiteDatastoreActor(
            configuration: .init(
                coreDatabaseURL: rootDirectory.appending(path: "core.sqlite"),
                localDatabaseURL: rootDirectory.appending(path: "local.sqlite")
            )
        )
        try Data("not a sqlite database".utf8)
            .write(to: rootDirectory.appending(path: "local.sqlite"))
        let preparation = await datastore.prepareDatabasesForBoot()
        guard case .prepared(let receipt) = preparation,
            case .available(recovery: .some(.init(reason: .corruptDatabase))) = receipt.local
        else {
            Issue.record("Expected corrupt local database replacement during preparation")
            return
        }
        try await datastore.saveWorkspaceEntityRecency([], workspaceId: workspaceID)

        let applicationLoad = await datastore.loadApplicationEntityRecency()
        let workspaceLoad = await datastore.loadWorkspaceEntityRecency(workspaceId: workspaceID)

        guard case .loaded(let applicationRecency) = applicationLoad else {
            Issue.record("Expected application recency to load after local recovery")
            return
        }
        guard case .loaded(let workspaceRecency) = workspaceLoad else {
            Issue.record("Expected workspace recency to load after local recovery")
            return
        }
        #expect(applicationRecency.isEmpty)
        #expect(workspaceRecency.isEmpty)
    }

    @Test("workspace restore consumes prepared replacement without physical recovery events")
    func workspaceRestoreConsumesPreparedReplacement() async throws {
        let workspaceID = UUID()
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-entity-recency-store-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let datastore = WorkspaceSQLiteDatastoreActor(
            configuration: .init(
                coreDatabaseURL: rootDirectory.appending(path: "core.sqlite"),
                localDatabaseURL: rootDirectory.appending(path: "local.sqlite")
            )
        )
        try Data("not a sqlite database".utf8)
            .write(to: rootDirectory.appending(path: "local.sqlite"))
        _ = await datastore.prepareDatabasesForBoot()
        try await datastore.saveWorkspaceEntityRecency([], workspaceId: workspaceID)
        let workspaceAtom = WorkspaceEntityRecencyAtom()
        let store = EntityRecencyStore(
            applicationAtom: ApplicationEntityRecencyAtom(),
            workspaceAtom: workspaceAtom,
            sqliteDatastore: datastore
        )

        await store.restoreWorkspaceAsync(for: workspaceID)

        #expect(workspaceAtom.workspaceID == workspaceID)
        #expect(workspaceAtom.recentEntities.isEmpty)
    }

    @Test("workspace restore defaults when prepared local is unavailable")
    func workspaceRestoreDefaultsWhenPreparedLocalIsUnavailable() async throws {
        let workspaceID = UUID()
        let coreDatabaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrate(coreDatabaseQueue)
        let coreRepository = WorkspaceCoreRepository(databaseWriter: coreDatabaseQueue)
        let datastore = try await preparedWorkspaceSQLiteDatastore(
            coreRepository: coreRepository,
            localUnavailable: .init(
                WorkspaceLocalSQLiteStoreBackendError.quarantineFailed(
                    workspaceID,
                    quarantinedFilename: "local.sqlite.corrupt-test"
                )
            )
        )
        let preparation = await datastore.prepareDatabasesForBoot()
        guard case .prepared(let receipt) = preparation,
            case .unavailable = receipt.local
        else {
            Issue.record("Expected local preparation to be unavailable")
            return
        }
        let workspaceAtom = WorkspaceEntityRecencyAtom()
        let store = EntityRecencyStore(
            applicationAtom: ApplicationEntityRecencyAtom(),
            workspaceAtom: workspaceAtom,
            sqliteDatastore: datastore
        )

        await store.restoreWorkspaceAsync(for: workspaceID)

        #expect(workspaceAtom.workspaceID == workspaceID)
        #expect(workspaceAtom.recentEntities.isEmpty)
    }

    @Test("store hydrates each lane before observation and preserves application state across workspace changes")
    func storeLifecycleSeparatesApplicationAndWorkspaceHydration() async throws {
        let factSource = EntityRecencyStoreFactSource()
        let facts = try factSource.attach()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: firstWorkspaceID)
        let secondRepository = WorkspaceLocalRepository(
            workspaceId: secondWorkspaceID,
            databaseWriter: fixture.databaseQueue
        )
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        _ = await datastore.prepareDatabasesForBoot()
        let applicationAtom = ApplicationEntityRecencyAtom(
            now: { Date(timeIntervalSince1970: 300) }
        )
        let workspaceAtom = WorkspaceEntityRecencyAtom()
        let clock = TestPushClock()
        let store = EntityRecencyStore(
            applicationAtom: applicationAtom,
            workspaceAtom: workspaceAtom,
            sqliteDatastore: datastore,
            persistDebounceDuration: .milliseconds(10),
            clock: clock,
            factSink: factSource.sink
        )
        let initialApplicationRecency = try ApplicationEntityRecency(
            entity: .repository(repositoryStableKey: "aaaaaaaaaaaaaaaa"),
            interaction: .opened,
            lastInteractedAt: Date(timeIntervalSince1970: 100)
        )
        let firstPaneRecency = try WorkspaceEntityRecency(
            workspaceID: firstWorkspaceID,
            entity: .pane(paneID: UUID()),
            interaction: .focused,
            lastInteractedAt: Date(timeIntervalSince1970: 100)
        )
        let secondPaneRecency = try WorkspaceEntityRecency(
            workspaceID: secondWorkspaceID,
            entity: .pane(paneID: UUID()),
            interaction: .focused,
            lastInteractedAt: Date(timeIntervalSince1970: 200)
        )
        let firstAdditionalPaneRecency = try WorkspaceEntityRecency(
            workspaceID: firstWorkspaceID,
            entity: .pane(paneID: UUID()),
            interaction: .focused,
            lastInteractedAt: Date(timeIntervalSince1970: 400)
        )
        try fixture.repository.replaceApplicationEntityRecency([initialApplicationRecency])
        try fixture.repository.replaceWorkspaceEntityRecency([firstPaneRecency])
        try secondRepository.replaceWorkspaceEntityRecency([secondPaneRecency])

        store.startObserving()
        #expect(!store.isApplicationObservationActive)
        #expect(!store.isWorkspaceObservationActive)

        await store.restoreApplicationAsync()
        await store.restoreWorkspaceAsync(for: firstWorkspaceID)

        #expect(store.isApplicationObservationActive)
        #expect(store.isWorkspaceObservationActive)
        #expect(applicationAtom.recentEntities == [initialApplicationRecency])
        #expect(workspaceAtom.recentEntities == [firstPaneRecency])

        applicationAtom.record(
            try ApplicationEntityRecency(
                entity: .worktree(worktreeStableKey: "bbbbbbbbbbbbbbbb"),
                interaction: .opened,
                lastInteractedAt: Date(timeIntervalSince1970: 300)
            )
        )
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(10))
        _ = try await facts.expectNextSaveCompleted(in: .application)
        #expect(try fixture.repository.fetchApplicationEntityRecency().count == 2)

        workspaceAtom.record(firstAdditionalPaneRecency)
        await clock.waitForPendingSleepCount()
        await store.restoreWorkspaceAsync(for: secondWorkspaceID)
        _ = try await facts.expectNextSaveCompleted(in: .workspace(firstWorkspaceID))

        #expect(applicationAtom.recentEntities.count == 2)
        #expect(workspaceAtom.workspaceID == secondWorkspaceID)
        #expect(workspaceAtom.recentEntities == [secondPaneRecency])
        #expect(
            try fixture.repository.fetchWorkspaceEntityRecency()
                == [firstAdditionalPaneRecency, firstPaneRecency]
        )

        try fixture.repository.replaceApplicationEntityRecency([])
        await store.restoreApplicationAsync()

        #expect(applicationAtom.recentEntities.count == 2)
        try await facts.finish()
    }

    @Test("flush all preserves the application error when both lanes fail")
    func flushAllPreservesApplicationErrorPrecedence() async throws {
        let workspaceID = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceID)
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        _ = await datastore.prepareDatabasesForBoot()
        let applicationAtom = ApplicationEntityRecencyAtom(
            now: { Date(timeIntervalSince1970: 100) }
        )
        let workspaceAtom = WorkspaceEntityRecencyAtom()
        let store = EntityRecencyStore(
            applicationAtom: applicationAtom,
            workspaceAtom: workspaceAtom,
            sqliteDatastore: datastore
        )
        await store.restoreApplicationAsync()
        await store.restoreWorkspaceAsync(for: workspaceID)
        applicationAtom.record(
            try ApplicationEntityRecency(
                entity: .repository(repositoryStableKey: "aaaaaaaaaaaaaaaa"),
                interaction: .opened,
                lastInteractedAt: Date(timeIntervalSince1970: 100)
            )
        )
        workspaceAtom.record(
            try WorkspaceEntityRecency(
                workspaceID: workspaceID,
                entity: .pane(paneID: UUID()),
                interaction: .focused,
                lastInteractedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try await fixture.databaseQueue.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_application_recency_flush
                    BEFORE INSERT ON local_entity_recency
                    BEGIN
                        SELECT RAISE(ABORT, 'reject application recency flush');
                    END
                    """
            )
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_workspace_recency_flush
                    BEFORE INSERT ON local_workspace_entity_recency
                    BEGIN
                        SELECT RAISE(ABORT, 'reject workspace recency flush');
                    END
                    """
            )
        }

        do {
            try await store.flushAllAsync()
            Issue.record("Expected both recency lanes to fail")
        } catch {
            #expect(String(reflecting: error).contains("reject application recency flush"))
        }
    }

    @Test("application lane failure defaults only application state")
    func applicationLaneFailureDoesNotDefaultWorkspaceState() async throws {
        let workspaceID = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceID)
        let paneRecency = try WorkspaceEntityRecency(
            workspaceID: workspaceID,
            entity: .pane(paneID: UUID()),
            interaction: .focused,
            lastInteractedAt: Date(timeIntervalSince1970: 100)
        )
        try fixture.repository.replaceWorkspaceEntityRecency([paneRecency])
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        _ = await datastore.prepareDatabasesForBoot()
        try await fixture.databaseQueue.write { database in
            try database.execute(sql: "DROP TABLE local_entity_recency")
        }
        let applicationAtom = ApplicationEntityRecencyAtom(
            now: { Date(timeIntervalSince1970: 100) }
        )
        let workspaceAtom = WorkspaceEntityRecencyAtom()
        let store = EntityRecencyStore(
            applicationAtom: applicationAtom,
            workspaceAtom: workspaceAtom,
            sqliteDatastore: datastore
        )

        await store.restoreApplicationAsync()
        await store.restoreWorkspaceAsync(for: workspaceID)

        #expect(applicationAtom.recentEntities.isEmpty)
        #expect(workspaceAtom.recentEntities == [paneRecency])
    }

    @Test("workspace lane failure defaults only workspace state")
    func workspaceLaneFailureDoesNotDefaultApplicationState() async throws {
        let workspaceID = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceID)
        let applicationRecency = try ApplicationEntityRecency(
            entity: .repository(repositoryStableKey: "aaaaaaaaaaaaaaaa"),
            interaction: .opened,
            lastInteractedAt: Date(timeIntervalSince1970: 100)
        )
        try fixture.repository.replaceApplicationEntityRecency([applicationRecency])
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        _ = await datastore.prepareDatabasesForBoot()
        try await fixture.databaseQueue.write { database in
            try database.execute(sql: "DROP TABLE local_workspace_entity_recency")
        }
        let applicationAtom = ApplicationEntityRecencyAtom(
            now: { Date(timeIntervalSince1970: 100) }
        )
        let workspaceAtom = WorkspaceEntityRecencyAtom()
        let store = EntityRecencyStore(
            applicationAtom: applicationAtom,
            workspaceAtom: workspaceAtom,
            sqliteDatastore: datastore
        )

        await store.restoreApplicationAsync()
        await store.restoreWorkspaceAsync(for: workspaceID)

        #expect(applicationAtom.recentEntities == [applicationRecency])
        #expect(workspaceAtom.workspaceID == workspaceID)
        #expect(workspaceAtom.recentEntities.isEmpty)
    }
}
