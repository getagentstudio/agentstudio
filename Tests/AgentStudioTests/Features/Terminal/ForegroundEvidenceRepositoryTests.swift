import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal

@Suite("Foreground evidence repository")
struct ForegroundEvidenceRepositoryTests {
    @Test("a previous binding's report does not veto the different latest binding after relaunch")
    func previousBindingsReportDoesNotVetoLatestBinding() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        _ = try await fixture.report(.reportsUnreadable(.historyLost), sequence: 1)
        let nextGeneration = UUIDv7.generate()
        try await fixture.bind(generation: nextGeneration)
        // No live bindingChanged callback crossed the app's shutdown. The
        // transaction's current binding is still authoritative at next launch.
        #expect(try await fixture.repository.eligiblePanes().map(\.bindingGenerationId) == [nextGeneration])
        #expect(try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value == nil)
        #expect(
            try await fixture.repository.admit(fixture.look(sequence: 2, generation: nextGeneration)) == .admitted)
        #expect(try await fixture.repository.load(paneId: fixture.paneId)?.bindingGenerationId == nextGeneration)
    }

    @Test("absence of a latest binding does not prove that a different binding became latest")
    func missingLatestBindingDoesNotClearReportedEvidence() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        _ = try await fixture.report(.reportedEnd, sequence: 1)
        try await fixture.database.write { try $0.execute(sql: "DELETE FROM fixture_latest_binding") }
        try await fixture.repository.clearReportedEvidenceForChangedBinding(paneId: fixture.paneId)
        #expect(try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value == .reportedEnd)
    }

    @Test("a new launch supersedes an older look while its sequence restarts")
    func newLaunchSupersedesPreviousLaunchLook() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        #expect(try await fixture.repository.admit(fixture.look(sequence: 100)) == .admitted)
        let nextLaunch = UUIDv7.generate()
        let nextRepository = SQLitePaneForegroundEvidenceRepository(
            access: TestForegroundEvidenceSQLiteAccess(databaseQueue: fixture.database), observerLaunchId: nextLaunch)
        let current = try fixture.look(sequence: 1, program: .codex, launchId: nextLaunch)
        #expect(try await nextRepository.admit(current) == .admitted)
        #expect(try await nextRepository.load(paneId: fixture.paneId) == current)
    }

    @Test("invalid stored process identity is dropped instead of becoming evidence")
    func corruptedIdentityIsNoEvidence() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        #expect(try await fixture.repository.admit(fixture.look(sequence: 1)) == .admitted)
        try await fixture.database.write { database in
            try database.execute(
                sql: "UPDATE terminal_pane_foreground_evidence SET leader_start_microseconds = 1000000")
        }
        #expect(try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value == nil)
    }

    @Test("reported evidence survives a later positive look for the same binding")
    func reportedEvidenceIsFinalForCurrentRun() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        #expect(try await fixture.report(.reportedEnd, sequence: 1) == .admitted)
        #expect(try await fixture.repository.admit(fixture.look(sequence: 2)) == .reportedEvidence)
        #expect(try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value == .reportedEnd)
        #expect(try await fixture.repository.eligiblePanes().isEmpty)
    }

    @Test("ending and reopening the same binding never clears a reported veto")
    func sameBindingReopenKeepsReportedEvidence() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        #expect(try await fixture.report(.reportedEnd, sequence: 1) == .admitted)
        try await fixture.bind(generation: fixture.generation, isLive: false)
        try await fixture.bind(generation: fixture.generation, isLive: true)
        try await fixture.repository.clearReportedEvidenceForChangedBinding(paneId: fixture.paneId)
        #expect(try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value == .reportedEnd)
        #expect(try await fixture.repository.eligiblePanes().isEmpty)
    }

    @Test("a different latest binding clears reported evidence and becomes eligible for looks")
    func differentBindingClearsReportedEvidence() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        #expect(try await fixture.report(.reportsUnreadable(.historyLost), sequence: 1) == .admitted)
        let nextGeneration = UUIDv7.generate()
        try await fixture.bind(generation: nextGeneration)
        try await fixture.repository.clearReportedEvidenceForChangedBinding(paneId: fixture.paneId)
        #expect(try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value == nil)
        #expect(try await fixture.repository.eligiblePanes().map(\.bindingGenerationId) == [nextGeneration])
        #expect(
            try await fixture.repository.admit(fixture.look(sequence: 2, generation: nextGeneration)) == .admitted)
    }

    @Test("the strongest reported kind wins in either write order")
    func strongestReportedKindWinsEveryPair() async throws {
        // PD 28 item 7's priority, weakest first; independent of repository implementation.
        let other = ReportedSession(provider: .codex, conversationId: UUIDv7.generate().uuidString)
        let reports: [ForegroundEvidence] = [
            .reportedEnd, .reportedOtherSessionEnd(other), .reportedOtherStart(other), .reportsUnreadable(.rowRefused),
        ]
        for first in reports.indices {
            for second in reports.indices {
                let fixture = try ForegroundEvidenceRepositoryFixture()
                _ = try await fixture.report(reports[first], sequence: 1)
                _ = try await fixture.report(reports[second], sequence: 2)
                #expect(
                    try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value
                        == reports[max(first, second)],
                    "Priority must hold for input indices \(first), \(second)")
            }
        }
    }

    @Test("retired panes reject both look and synchronous reported writes")
    func retiredPaneCannotBeResurrectedByEvidence() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        #expect(try await fixture.repository.admit(fixture.look(sequence: 1)) == .admitted)
        try await fixture.repository.retire(paneId: fixture.paneId)
        #expect(try await fixture.repository.admit(fixture.look(sequence: 2)) == .retiredPane)
        #expect(try await fixture.report(.reportedEnd, sequence: 3) == .retiredPane)
        let rowCount = try await fixture.database.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM terminal_pane_foreground_evidence")
        }
        #expect(rowCount == 0)
    }

    @Test(
        "reported rows with any look-only column are dropped",
        arguments: [
            "zmx_session_id", "program", "identity_version", "boot_id", "daemon_pid", "daemon_start_seconds",
            "daemon_start_microseconds", "leader_pid", "leader_start_seconds", "leader_start_microseconds",
            "process_group_id", "session_created_at",
        ])
    func reportedRowRejectsLookColumns(column: String) async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        _ = try await fixture.report(.reportedEnd, sequence: 1)
        try await fixture.database.write { database in
            try database.execute(
                sql: "UPDATE terminal_pane_foreground_evidence SET \(column) = ?", arguments: ["alien"])
        }
        #expect(try await fixture.repository.loadEvidence(paneId: fixture.paneId)?.value == nil)
    }

    @Test(
        "a look with a reported-only column is dropped",
        arguments: [
            "reported_provider", "reported_conversation_id", "unreadable_reason",
        ])
    func lookRowRejectsReportedColumns(column: String) async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        _ = try await fixture.repository.admit(fixture.look(sequence: 1))
        try await fixture.database.write { database in
            try database.execute(
                sql: "UPDATE terminal_pane_foreground_evidence SET \(column) = ?", arguments: ["alien"])
        }
        #expect(try await fixture.repository.load(paneId: fixture.paneId) == nil)
    }

    @Test("snapshot sequence and generation are checked inside the write")
    func staleLookNeverOverwritesCurrentEvidence() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        let newer = try fixture.look(sequence: 2, program: .shell)
        #expect(try await fixture.repository.admit(newer) == .admitted)
        #expect(try await fixture.repository.admit(fixture.look(sequence: 1)) == .olderLook)
        #expect(try await fixture.repository.load(paneId: fixture.paneId) == newer)
        try await fixture.bind(generation: UUIDv7.generate())
        #expect(try await fixture.repository.admit(fixture.look(sequence: 3)) == .bindingChanged)
    }

    @Test("only live latest bindings without a report receive looks")
    func endedOrUnboundPanesAreIneligible() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        #expect(try await fixture.repository.eligiblePanes().count == 1)
        try await fixture.bind(generation: fixture.generation, isLive: false)
        #expect(try await fixture.repository.eligiblePanes().isEmpty)
        try await fixture.database.write { try $0.execute(sql: "DELETE FROM fixture_latest_binding") }
        #expect(try await fixture.repository.eligiblePanes().isEmpty)
    }

    @Test("030 stores typed evidence columns without blobs, checks or triggers")
    func foregroundEvidenceMigrationMatchesKindAwareContract() async throws {
        let fixture = try ForegroundEvidenceRepositoryFixture()
        let schema = try await fixture.database.read { database in
            let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(terminal_pane_foreground_evidence)")
            let types = columns.map { $0["type"] as String }
            let names = Set(columns.map { $0["name"] as String })
            let sql = try String.fetchOne(
                database, sql: "SELECT sql FROM sqlite_master WHERE name = 'terminal_pane_foreground_evidence'")
            let triggers = try Int.fetchOne(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'terminal_pane_foreground_evidence'"
            )
            return (names, types, sql, triggers)
        }
        #expect(
            schema.0
                == Set([
                    "pane_id", "evidence_kind", "binding_generation_id", "observer_launch_id", "sequence",
                    "observed_at",
                    "zmx_session_id", "program", "reported_provider", "reported_conversation_id", "unreadable_reason",
                    "identity_version", "boot_id", "daemon_pid", "daemon_start_seconds", "daemon_start_microseconds",
                    "leader_pid", "leader_start_seconds", "leader_start_microseconds", "process_group_id",
                    "session_created_at",
                ]))
        #expect(schema.1.allSatisfy { ["TEXT", "INTEGER"].contains($0) })
        #expect(!(schema.2 ?? "").contains("CHECK"))
        #expect(schema.3 == 0)
    }
}
