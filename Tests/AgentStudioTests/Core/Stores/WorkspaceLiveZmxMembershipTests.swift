import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Persisted restore zmx membership")
struct WorkspaceLiveZmxMembershipTests {
    @Test("membership is scoped to the persisted workspace and zmx provider")
    func persistedMembershipIsWorkspaceAndProviderScoped() async throws {
        let fixture = try LiveZmxMembershipFixture()
        let expectedSession = ZmxSessionID.generateUUIDv7()
        let expectedPane = try fixture.addTerminal(provider: .zmx, sessionId: expectedSession)
        _ = try fixture.addTerminal(provider: .ghostty, sessionId: .generateUUIDv7())
        let otherWorkspace = UUIDv7.generate()
        try fixture.repository.upsertWorkspace(
            .init(id: otherWorkspace, name: "Other", createdAt: fixture.date, updatedAt: fixture.date))
        _ = try fixture.addTerminal(provider: .zmx, sessionId: .generateUUIDv7(), workspaceId: otherWorkspace)

        let membership = try await fixture.repository.liveZmxSessionsByPane(workspaceId: fixture.workspaceId)
        #expect(membership == [expectedPane: expectedSession])
    }

    @Test("an invalid stored identifier fails the whole membership read instead of silently skipping a pane")
    func malformedStoredIdentityFailsMembershipRead() async throws {
        let fixture = try LiveZmxMembershipFixture()
        let paneId = try fixture.addTerminal(provider: .zmx, sessionId: .generateUUIDv7())
        // SQLite's trim does not remove tabs, whereas the identity parser does.
        // This reaches the parser through the real schema without disabling a constraint.
        try await fixture.database.write { database in
            try database.execute(
                sql: "INSERT INTO workspace_terminal_session_ownership(session_id) VALUES (?)", arguments: ["\t"])
            try database.execute(
                sql: "UPDATE pane_content_terminal SET zmx_session_id = ? WHERE pane_id = ?",
                arguments: ["\t", paneId.uuidString])
        }

        await #expect(throws: WorkspaceUndoJournalFailure.invalidStoredIdentifier) {
            try await fixture.repository.liveZmxSessionsByPane(workspaceId: fixture.workspaceId)
        }
    }
}

private struct LiveZmxMembershipFixture: Sendable {
    let database: DatabaseQueue
    let repository: WorkspaceCoreRepository
    let workspaceId = UUIDv7.generate()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "restore-membership")
        repository = WorkspaceCoreRepository(databaseWriter: database)
        try repository.migrate()
        try repository.upsertWorkspace(
            .init(id: workspaceId, name: "Restore", createdAt: date, updatedAt: date))
    }

    func addTerminal(provider: SessionProvider, sessionId: ZmxSessionID, workspaceId: UUID? = nil) throws -> UUID {
        let workspaceId = workspaceId ?? self.workspaceId
        let paneId = UUIDv7.generate()
        var graph = try repository.fetchPaneGraph(workspaceId: workspaceId)
        graph.panes.append(
            .init(
                id: paneId, content: .terminal(provider: provider, lifetime: .persistent, zmxSessionID: sessionId),
                metadata: .init(executionBackend: .local, createdAt: date, title: "Membership"), residency: .active,
                placement: .layout, drawer: nil, updatedAt: date))
        try repository.replacePaneGraph(workspaceId: workspaceId, graph: graph)
        return paneId
    }
}
