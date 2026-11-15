import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@Suite("Persisted restore zmx membership")
struct WorkspaceLiveZmxMembershipTests {
    @Test("closed-app intake reads persisted pane membership, including non-zmx terminals")
    func closedAppPaneMembershipUsesPersistedGraph() async throws {
        let fixture = try LiveZmxMembershipFixture()
        let first = try fixture.addTerminal(provider: .zmx, sessionId: .generateUUIDv7())
        let second = try fixture.addTerminal(provider: .ghostty, sessionId: .generateUUIDv7())
        #expect(try await fixture.repository.persistedPaneIds(workspaceId: fixture.workspaceId) == [first, second])
        var graph = try fixture.repository.fetchPaneGraph(workspaceId: fixture.workspaceId)
        graph.panes.removeAll { $0.id == first }
        try fixture.repository.replacePaneGraph(workspaceId: fixture.workspaceId, graph: graph)
        #expect(try await fixture.repository.persistedPaneIds(workspaceId: fixture.workspaceId) == [second])
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
