import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions repository")
struct SessionsRepositoryTests {
    @Test("first hooks bind on installed or arbitrary provider versions", arguments: ["2.1.289", "0.160.0", "9.9.9"])
    func anyReportedVersionIsRecorded(version: String) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let firstOutcome = try await repository.applyHook(
            makeHookAdmission(
                paneId: pane, eventName: .toolActivity,
                signal: .toolActivity(toolName: "Read"), providerVersion: version))
        let first = try #require(committedHookCommit(from: firstOutcome))
        #expect(first.disposition == .bound)
        #expect(first.evidence.statusEffect == .applied)
        let stored = try await fixture.sqliteAccess.read {
            try String.fetchOne($0, sql: "SELECT provider_version FROM sessions_source")
        }
        #expect(stored == version)
    }

    @Test("same-turn same-tool hook invocations both persist with distinct fresh record ids")
    func distinctInvocationsPersist() async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let first = makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read"))
        let second = makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read"))
        let committedOutcome = try await repository.applyHook(first)
        let laterOutcome = try await repository.applyHook(second)
        let committed = try #require(committedHookCommit(from: committedOutcome))
        let later = try #require(committedHookCommit(from: laterOutcome))
        #expect(later.disposition == .applied)
        #expect(committed.binding.bindingGenerationId == later.binding.bindingGenerationId)
        let ids = try await fixture.sqliteAccess.read {
            try String.fetchAll($0, sql: "SELECT occurrence_id FROM sessions_evidence ORDER BY admission_sequence")
        }
        #expect(ids == [first.recordId.uuidString, second.recordId.uuidString])
        #expect(committed.revision < later.revision)
    }

    @Test("source and operation rows remain one identity per binding and one revision per hook")
    func retainedIdentityRowsAreNotAdmissionLedgers() async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let resultOutcome = try await repository.applyHook(makeHookAdmission(paneId: pane))
        let result = try #require(committedHookCommit(from: resultOutcome))
        #expect(result.binding.sourceGenerationId == result.binding.bindingGenerationId)
        let counts = try await fixture.sqliteAccess.read { database in
            [
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_operation"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_source"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_evidence"),
            ]
        }
        #expect(counts == [1, 1, 1])
    }
}
