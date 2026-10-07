import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Pane activity datastore integration", .serialized)
struct PaneActivityDatastoreIntegrationTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("booting one workspace retains other workspaces and prunes only unowned activity")
    func appWideRetentionAndWorkspaceScopedLoad() async throws {
        let workspaceA = UUIDv7.generate()
        let workspaceB = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceA)
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let paneA = makePane(id: UUIDv7.generate())
        let paneB = makePane(id: UUIDv7.generate())
        for (workspaceID, pane) in [(workspaceA, paneA), (workspaceB, paneB)] {
            let tab = Tab(paneId: pane.id)
            try await datastore.saveWorkspaceSnapshotBundle(
                .emptyTopologyFixture(
                    workspace: .init(
                        id: workspaceID, panes: [pane], tabs: [tab], activeTabId: tab.id
                    )))
        }
        let orphanID = UUIDv7.generate()
        let time = PaneActivityTime(
            orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .hook)
        try await datastore.commitPaneActivity(
            .init(mutations: [.set(paneA.id, time), .set(paneB.id, time), .set(orphanID, time)]))
        #expect(await datastore.loadPaneActivity(workspaceId: workspaceA).map(\.paneId) == [paneA.id])
        #expect(Set(try fixture.localRepository.fetchPaneActivity().map(\.paneId)) == [paneA.id, paneB.id])
        #expect(await datastore.loadPaneActivity(workspaceId: workspaceB).map(\.paneId) == [paneB.id])
    }

    @Test("close, restart, and Undo preserve the durable activity record")
    func availableUndoSurvivesRestart() async throws {
        let databases = try DrawerPresentationDatabases()
        defer { databases.remove() }
        let store = try await databases.bootStore()
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        #expect(await store.flushAsync() == .persisted)
        let datastore = databases.makeDatastore(legacySource: nil)
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Expected prepared databases")
            return
        }
        let time = PaneActivityTime(
            orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .terminal)
        try await datastore.commitPaneActivity(.init(mutations: [.set(pane.id, time)]))
        let undoTime = WorkspaceUndoJournalTime(
            utc: Date(timeIntervalSince1970: 100), bootID: "pane-activity-undo", uptimeNanoseconds: 100_000_000_000)
        try await store.closeForUndo(
            tabID: tab.id, paneID: nil, closeID: UUIDv7.generate(), time: undoTime, willPublish: { _, _ in },
            didPublish: { _, _ in })
        let restored = try await databases.bootStore()
        let restartedDatastore = databases.makeDatastore(legacySource: nil)
        guard case .prepared = await restartedDatastore.prepareDatabasesForBoot() else {
            Issue.record("Expected restarted databases")
            return
        }
        let records = await restartedDatastore.loadPaneActivity(workspaceId: restored.identityAtom.workspaceId)
        #expect(records == [.init(paneId: pane.id, wallTime: time.wallTime, source: .terminal)])
        let receipt = try await restored.undoClose(time: undoTime, willPublish: { _, _ in }, didPublish: { _, _ in })
        #expect(receipt != nil)
        #expect(restored.paneAtom.pane(pane.id) != nil)
        #expect(await restartedDatastore.loadPaneActivity(workspaceId: restored.identityAtom.workspaceId) == records)
    }

    @Test("a failed membership read deletes nothing")
    func membershipFailureSkipsPrune() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let paneID = UUIDv7.generate()
        let time = PaneActivityTime(
            orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .hook)
        try await datastore.commitPaneActivity(.init(mutations: [.set(paneID, time)]))
        try fixture.coreRepository.databaseWriter.write { database in
            try database.execute(sql: "DROP TABLE workspace_undo_close_member")
        }
        #expect(await datastore.loadPaneActivity(workspaceId: workspaceID).isEmpty)
        #expect(try fixture.localRepository.fetchPaneActivity().map(\.paneId) == [paneID])
    }

    @Test("an unavailable local database loads empty and commits report failure")
    func localFailureFallsBackToEmpty() async throws {
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: UUIDv7.generate())
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        try fixture.localQueue.close()
        #expect(await datastore.loadPaneActivity(workspaceId: UUIDv7.generate()).isEmpty)
        await #expect(throws: (any Error).self) {
            try await datastore.commitPaneActivity(.init(mutations: [.remove(UUIDv7.generate())]))
        }
    }
}
