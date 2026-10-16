import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Workspace core pane topology facet migration")
struct WorkspaceCorePaneTopologyFacetMigrationTests {
    @Test("migration 015 facet removal preserves the complete graph through current migrations")
    func migration015PreservesCompletePaneAndLayoutGraph() async throws {
        // Arrange
        let fixture = try makeMigration015PreservationFixture()
        let predecessorSnapshot = try fixture.snapshot()

        // Act
        try WorkspaceCoreMigrations.migrate(fixture.databaseQueue)

        // Assert
        let migratedSnapshot = try fixture.snapshot()
        #expect(migratedSnapshot == predecessorSnapshot)

        let schemaProof = try await fixture.databaseQueue.read { database in
            let paneColumns = try Row.fetchAll(database, sql: "PRAGMA table_info(pane)")
                .map { row in row["name"] as String }
            let quickCheck = try String.fetchOne(database, sql: "PRAGMA quick_check")
            let foreignKeyViolationCount = try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").count
            let paneFacetTriggers = try fetchPaneFacetTriggerNames(database)
            return (paneColumns, quickCheck, foreignKeyViolationCount, paneFacetTriggers)
        }
        #expect(schemaProof.0.contains("facet_repo_id"))
        #expect(schemaProof.0.contains("facet_worktree_id"))
        #expect(schemaProof.1 == "ok")
        #expect(schemaProof.2 == 0)
        #expect(schemaProof.3.isEmpty)
    }

    @MainActor
    @Test("migration 015 restores saves and reloads through the application store")
    func migration015RestoresSavesAndReloadsThroughApplicationStore() async throws {
        // Arrange
        let fixture = try makeMigration015PreservationFixture()
        try WorkspaceCoreMigrations.migrate(fixture.databaseQueue)
        let localDatabaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(
            label: "AgentStudio.sqlite.migration-015.local"
        )
        try WorkspaceLocalMigrations.migrate(localDatabaseQueue)
        let restoredStore = try await makeMigration015WorkspaceStore(
            coreDatabaseQueue: fixture.databaseQueue,
            localDatabaseQueue: localDatabaseQueue
        )

        // Act
        let initialLoadResult = await restoredStore.loadCanonicalComposition()

        // Assert
        guard case .loaded = initialLoadResult else {
            Issue.record("Expected migrated application composition to load, got \(initialLoadResult)")
            return
        }
        try assertMigration015ApplicationState(restoredStore, fixture: fixture)
        let restoredApplicationSnapshot = migration015ApplicationSnapshot(restoredStore)

        // Act
        #expect((await restoredStore.flushAsync()).succeeded)
        let reloadedStore = try await makeMigration015WorkspaceStore(
            coreDatabaseQueue: fixture.databaseQueue,
            localDatabaseQueue: localDatabaseQueue
        )
        let reloadResult = await reloadedStore.loadCanonicalComposition()

        // Assert
        guard case .loaded = reloadResult else {
            Issue.record("Expected saved application composition to reload, got \(reloadResult)")
            return
        }
        try assertMigration015ApplicationState(reloadedStore, fixture: fixture)
        #expect(
            migration015ApplicationSnapshot(reloadedStore)
                == restoredApplicationSnapshot
        )
    }

    @MainActor
    @Test("migration 015 discards malformed legacy facet text before current association columns")
    func migration015DiscardsMalformedLegacyFacetTextWithoutGraphLoss() async throws {
        // Arrange
        let fixture = try makeMigration015MalformedFacetFixture()
        let predecessorSnapshot = try fixture.snapshot()
        let malformedFacetText: (repository: String?, worktree: String?) =
            try await fixture.databaseQueue.read { database in
                let row = try Row.fetchOne(
                    database,
                    sql: "SELECT facet_repo_id, facet_worktree_id FROM pane WHERE id = ?",
                    arguments: [fixture.terminalPaneID.uuidString]
                )
                return (row?["facet_repo_id"], row?["facet_worktree_id"])
            }
        #expect(malformedFacetText.repository == "malformed-repository-uuid")
        #expect(malformedFacetText.worktree == "malformed-worktree-uuid")

        // Act
        try WorkspaceCoreMigrations.migrate(fixture.databaseQueue)

        // Assert
        #expect(try fixture.snapshot() == predecessorSnapshot)
        let schemaProof = try await fixture.databaseQueue.read { database in
            let paneColumns = try Row.fetchAll(database, sql: "PRAGMA table_info(pane)")
                .map { row in row["name"] as String }
            let quickCheck = try String.fetchOne(database, sql: "PRAGMA quick_check")
            let foreignKeyViolationCount = try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").count
            let paneFacetTriggers = try fetchPaneFacetTriggerNames(database)
            return (paneColumns, quickCheck, foreignKeyViolationCount, paneFacetTriggers)
        }
        #expect(schemaProof.0.contains("facet_repo_id"))
        #expect(schemaProof.0.contains("facet_worktree_id"))
        #expect(schemaProof.1 == "ok")
        #expect(schemaProof.2 == 0)
        #expect(schemaProof.3.isEmpty)

        let localDatabaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(
            label: "AgentStudio.sqlite.migration-015.malformed-facets.local"
        )
        try WorkspaceLocalMigrations.migrate(localDatabaseQueue)
        let restoredStore = try await makeMigration015WorkspaceStore(
            coreDatabaseQueue: fixture.databaseQueue,
            localDatabaseQueue: localDatabaseQueue
        )
        let initialLoadResult = await restoredStore.loadCanonicalComposition()
        guard case .loaded = initialLoadResult else {
            Issue.record("Expected malformed-facet migration composition to load, got \(initialLoadResult)")
            return
        }
        try assertMigration015ApplicationState(restoredStore, fixture: fixture)
        let restoredApplicationSnapshot = migration015ApplicationSnapshot(restoredStore)

        // Act
        #expect((await restoredStore.flushAsync()).succeeded)
        let reloadedStore = try await makeMigration015WorkspaceStore(
            coreDatabaseQueue: fixture.databaseQueue,
            localDatabaseQueue: localDatabaseQueue
        )
        let reloadResult = await reloadedStore.loadCanonicalComposition()

        // Assert
        guard case .loaded = reloadResult else {
            Issue.record("Expected malformed-facet migration composition to reload, got \(reloadResult)")
            return
        }
        try assertMigration015ApplicationState(reloadedStore, fixture: fixture)
        #expect(migration015ApplicationSnapshot(reloadedStore) == restoredApplicationSnapshot)
    }

    @Test("migration 015 failure rolls back to an operational predecessor schema")
    func migration015FailureRollsBackToOperationalPredecessorSchema() throws {
        // Arrange
        let fixture = try makeMigration015PreservationFixture()
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: "CREATE INDEX migration_015_blocking_index ON pane(facet_repo_id)"
            )
        }

        // Act
        #expect(throws: DatabaseError.self) {
            try WorkspaceCoreMigrations.migrate(fixture.databaseQueue)
        }

        // Assert
        let rollbackProof = try fixture.databaseQueue.read { database in
            let paneColumns = try Row.fetchAll(database, sql: "PRAGMA table_info(pane)")
                .map { row in row["name"] as String }
            let triggerNames = try fetchPaneFacetTriggerNames(database)
            let completedMigrations = try WorkspaceCoreMigrations.migrator.completedMigrations(database)
            return (paneColumns, triggerNames, completedMigrations)
        }
        #expect(rollbackProof.0.contains("facet_repo_id"))
        #expect(rollbackProof.0.contains("facet_worktree_id"))
        #expect(rollbackProof.1 == paneFacetTriggerNames)
        #expect(!rollbackProof.2.contains("015_drop_pane_topology_facets"))

        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: "UPDATE pane SET note = ? WHERE id = ?",
                arguments: ["rollback remains writable", fixture.terminalPaneID.uuidString]
            )
        }
        let persistedNote = try fixture.databaseQueue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT note FROM pane WHERE id = ?",
                arguments: [fixture.terminalPaneID.uuidString]
            )
        }
        #expect(persistedNote == "rollback remains writable")
    }
}
