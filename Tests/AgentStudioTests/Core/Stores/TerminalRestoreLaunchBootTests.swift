import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("031 and the previous app run's boot")
struct TerminalRestoreLaunchBootTests {
    @Test("031 is available with only boot-required migrations, before optional schemas")
    func launchBootMigrationIsBootRequired() async throws {
        let observed = try await valueFromDedicatedThread {
            let database = try DatabaseQueue()
            try WorkspaceLocalMigrations.migrateBootRequired(database)
            return try database.read { connection in
                (
                    launchBoot: try connection.tableExists("terminal_restore_launch_boot"),
                    sessions: try connection.tableExists("sessions_pane_binding"),
                    ids: try WorkspaceLocalMigrations.bootRequiredMigrator.appliedIdentifiers(connection)
                )
            }
        }
        #expect(observed.launchBoot)
        #expect(!observed.sessions)
        #expect(observed.ids.contains("031_create_terminal_restore_launch_boot"))
    }

    @Test("first launch is same-boot; read then replace retains the previous app run")
    func previousAppRunDeterminesBootRelation() async throws {
        let database = try DatabaseQueue()
        try WorkspaceLocalMigrations.migrateBootRequired(database)
        let repository = WorkspaceLocalRepository(workspaceId: UUIDv7.generate(), databaseWriter: database)
        let first = try await repository.replaceTerminalRestoreLaunchBoot(
            currentBootId: "boot-A", recordedAt: Date(timeIntervalSince1970: 1))
        let reboot = try await repository.replaceTerminalRestoreLaunchBoot(
            currentBootId: "boot-B", recordedAt: Date(timeIntervalSince1970: 2))
        let same = try await repository.replaceTerminalRestoreLaunchBoot(
            currentBootId: "boot-B", recordedAt: Date(timeIntervalSince1970: 3))
        #expect(first.previousBootId == nil)
        #expect(first.isSameBoot)
        #expect(reboot.previousBootId == "boot-A")
        #expect(!reboot.isSameBoot)
        #expect(same.previousBootId == "boot-B")
        #expect(same.isSameBoot)
        let row = try await database.read { connection in
            (
                count: try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM terminal_restore_launch_boot"),
                boot: try String.fetchOne(connection, sql: "SELECT boot_id FROM terminal_restore_launch_boot"),
                recorded: try String.fetchOne(connection, sql: "SELECT recorded_at FROM terminal_restore_launch_boot")
            )
        }
        #expect(row.count == 1)
        #expect(row.boot == "boot-B")
        #expect(row.recorded == "1970-01-01T00:00:03Z")
    }
}

extension TerminalRestoreLaunchBootTests {
    @Test("an upgraded application-local database gets 031 in the boot-only migration pass")
    func upgradeInstallsLaunchBootBeforeOptionalMigrationPass() async throws {
        let observed = try await valueFromDedicatedThread {
            let database = try DatabaseQueue()
            try WorkspaceLocalMigrations.migrate(database)
            // Construct the pre-R3 schema, retaining the real preexisting migration records and data.
            try database.write { connection in
                try connection.execute(sql: "DROP TABLE terminal_restore_launch_boot")
                try connection.execute(sql: "DROP TABLE terminal_restore_outbox_identity")
                try connection.execute(sql: "DROP TABLE terminal_pane_foreground_evidence")
                try connection.execute(
                    sql:
                        "DELETE FROM grdb_migrations WHERE identifier IN ('030_create_terminal_pane_foreground_evidence', '031_create_terminal_restore_launch_boot', '032_create_terminal_restore_outbox_identity')"
                )
                try connection.execute(
                    sql: "INSERT INTO local_workspace_cursor(workspace_id, updated_at) VALUES (?, 1)",
                    arguments: [UUIDv7.generate().uuidString])
            }
            try WorkspaceLocalMigrations.migrateBootRequired(database)
            return try database.read { connection in
                (
                    boot: try connection.tableExists("terminal_restore_launch_boot"),
                    foreground: try connection.tableExists("terminal_pane_foreground_evidence"),
                    identity: try connection.tableExists("terminal_restore_outbox_identity"),
                    cursorCount: try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM local_workspace_cursor")
                )
            }
        }
        #expect(observed.boot)
        #expect(!observed.foreground)
        #expect(!observed.identity)
        #expect(observed.cursorCount == 1)
    }
}
