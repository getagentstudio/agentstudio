import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Pane activity persistence")
struct PaneActivityPersistenceTests {
    @Test("boot-required schema opens fresh and existing local databases", arguments: [false, true])
    func bootMigration(existing: Bool) throws {
        let database = try SQLiteDatabaseFactory.makeInMemoryQueue()
        if existing {
            try WorkspaceLocalMigrations.bootRequiredMigrator.migrate(
                database, upTo: "015_create_local_drawer_presentation")
        }
        try WorkspaceLocalMigrations.migrateBootRequired(database)
        let repository = WorkspaceLocalRepository(workspaceId: UUIDv7.generate(), databaseWriter: database)
        #expect(try repository.fetchPaneActivity().isEmpty)
    }

    @Test("a published batch replaces time and source and deletes retired panes")
    func roundTripAndRetirement() throws {
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: UUIDv7.generate())
        let paneID = UUIDv7.generate()
        let retiredID = UUIDv7.generate()
        let instant = ContinuousClock.now
        let first = PaneActivityTime(
            orderingInstant: instant, wallTime: Date(timeIntervalSince1970: 100), source: .hook)
        let latest = PaneActivityTime(
            orderingInstant: instant, wallTime: Date(timeIntervalSince1970: 200), source: .terminal)
        try fixture.repository.commitPaneActivity(.init(mutations: [.set(paneID, first), .set(retiredID, first)]))
        try fixture.repository.commitPaneActivity(.init(mutations: [.set(paneID, latest), .remove(retiredID)]))
        #expect(
            try fixture.repository.fetchPaneActivity() == [
                .init(paneId: paneID, wallTime: latest.wallTime, source: .terminal)
            ])
    }

    @Test("unknown sources are skipped rather than interpreted as terminal activity")
    func unknownSourceSkipped() throws {
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: UUIDv7.generate())
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: "INSERT INTO local_pane_activity VALUES (?, ?, ?)",
                arguments: [UUIDv7.generate().uuidString, 100, "unknown"])
        }
        #expect(try fixture.repository.fetchPaneActivity().isEmpty)
    }

    @Test("pruning keeps only retained identities including an empty retain set")
    func pruneRetainSet() throws {
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: UUIDv7.generate())
        let retainedID = UUIDv7.generate()
        let removedID = UUIDv7.generate()
        let time = PaneActivityTime(
            orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .hook)
        try fixture.repository.commitPaneActivity(.init(mutations: [.set(retainedID, time), .set(removedID, time)]))
        try fixture.repository.prunePaneActivity(retaining: [retainedID])
        #expect(try fixture.repository.fetchPaneActivity().map(\.paneId) == [retainedID])
        try fixture.repository.prunePaneActivity(retaining: [])
        #expect(try fixture.repository.fetchPaneActivity().isEmpty)
    }
}
