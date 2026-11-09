import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Workspace core browser migration")
struct WorkspaceCoreBrowserMigrationTests {
    @Test("upgrading core schema 018 records browser migration 020")
    func upgradingSchema018RecordsBrowserMigration020() throws {
        // Arrange
        let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        try WorkspaceCoreMigrations.migrator.migrate(databaseQueue, upTo: "018_repository_location_absence")

        // Act
        try WorkspaceCoreMigrations.migrate(databaseQueue)

        // Assert
        let completedMigrations = try databaseQueue.read { database in
            try WorkspaceCoreMigrations.migrator.completedMigrations(database)
        }
        #expect(completedMigrations.contains("020_browser_webviews"))
        #expect(!completedMigrations.contains("019_browser_webviews"))
    }
}
