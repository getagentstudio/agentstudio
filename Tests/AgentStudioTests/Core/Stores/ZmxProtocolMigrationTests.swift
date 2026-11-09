import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("zmx protocol ownership migration")
struct ZmxProtocolMigrationTests {
    @Test("migration preserves untracked sessions and new ownership records the current protocol")
    func existingAndNewSessions() throws {
        let database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "zmx-protocol-migration")
        try WorkspaceCoreMigrations.migrator.migrate(database, upTo: "018_repository_location_absence")
        try database.write {
            try $0.execute(sql: "INSERT INTO workspace_terminal_session_ownership(session_id) VALUES ('legacy')")
        }

        try WorkspaceCoreMigrations.migrate(database)
        try database.write {
            try $0.execute(sql: "INSERT INTO workspace_terminal_session_ownership(session_id) VALUES ('current')")
        }

        let repository = WorkspaceCoreRepository(databaseWriter: database)
        let legacy = try #require(ZmxSessionID(restoring: "legacy"))
        let current = try #require(ZmxSessionID(restoring: "current"))
        // A newly registered ownership row alone is not proof of the daemon's protocol.
        #expect(try repository.terminalSessionProtocolVersion(current) == nil)
        try repository.recordTerminalSessionProtocolVersion(current, version: ZmxProtocol.version)
        #expect(try repository.terminalSessionProtocolVersion(legacy) == nil)
        #expect(try repository.terminalSessionProtocolVersion(current) == ZmxProtocol.version)
        try repository.recordTerminalSessionProtocolVersion(legacy, version: ZmxProtocol.version)
        #expect(try repository.terminalSessionProtocolVersion(legacy) == ZmxProtocol.version)
    }
}
