import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct SidebarCacheStoreTests {
    @Test
    func flushAndRestoreRoundTripsMainWindowCollapsedGroups() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let datastore = try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        let atom = SidebarCacheState()
        let collapsedGroup = SidebarGroupKey("repo:agent-studio")
        atom.setGroupExpanded(collapsedGroup, isExpanded: false)

        try await SidebarCacheStore(atom: atom, sqliteDatastore: datastore).flushAsync(for: workspaceId)
        let restoredAtom = SidebarCacheState()
        await SidebarCacheStore(atom: restoredAtom, sqliteDatastore: datastore).restoreAsync(for: workspaceId)

        #expect(restoredAtom.collapsedGroups == [collapsedGroup])
    }

    @Test
    func missingSQLiteRowsResetExistingStateToTypedDefaults() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = SidebarCacheState()
        atom.setGroupExpanded(SidebarGroupKey("repo:stale"), isExpanded: false)

        await SidebarCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        ).restoreAsync(for: workspaceId)

        #expect(atom.collapsedGroups.isEmpty)
    }

    @Test
    func unavailableSQLiteResetsDefaultsAndReportsRecovery() async throws {
        let workspaceId = UUID()
        let atom = SidebarCacheState()
        atom.setGroupExpanded(SidebarGroupKey("repo:stale"), isExpanded: false)
        var reportedRecoveries: [PersistenceRecoveryEvent] = []

        await SidebarCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: failingWorkspaceLocalSQLiteBackend()),
            recoveryReporter: { reportedRecoveries.append($0) }
        ).restoreAsync(for: workspaceId)

        #expect(atom.collapsedGroups.isEmpty)
        #expect(
            reportedRecoveries.contains { recovery in
                recovery.store == .sidebarCache
                    && recovery.workspaceId == workspaceId
                    && recovery.recovery == .resetToDefaults
            })
    }

    @Test
    func observedCollapseChangeAutosavesSQLite() async throws {
        let factSource = SidebarCacheStoreFactSource()
        let facts = try factSource.attach()
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = SidebarCacheState()
        let clock = TestPushClock()
        let collapsedGroup = SidebarGroupKey("repo:agent-studio")
        let store = SidebarCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock,
            factSink: factSource.sink
        )
        await store.restoreAsync(for: workspaceId)
        store.startObserving()

        atom.setGroupExpanded(collapsedGroup, isExpanded: false)
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(10))

        _ = try await facts.expectNextSaveCompleted(workspaceId: workspaceId)
        #expect(try fixture.repository.fetchCollapsedGroups() == [collapsedGroup])
        try await facts.finish()
    }

    @Test
    func directWriteOwnerMutationAutosavesThroughComposedState() async throws {
        let factSource = SidebarCacheStoreFactSource()
        let facts = try factSource.attach()
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let collapsedGroupAtom = SidebarCollapsedGroupAtom()
        let atom = SidebarCacheState(collapsedGroupAtom: collapsedGroupAtom)
        let clock = TestPushClock()
        let collapsedGroup = SidebarGroupKey("repo:agent-studio")
        let store = SidebarCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock,
            factSink: factSource.sink
        )
        await store.restoreAsync(for: workspaceId)
        store.startObserving()

        collapsedGroupAtom.setGroupExpanded(collapsedGroup, isExpanded: false)
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(10))

        _ = try await facts.expectNextSaveCompleted(workspaceId: workspaceId)
        #expect(try fixture.repository.fetchCollapsedGroups() == [collapsedGroup])
        try await facts.finish()
    }

    @Test
    func restoreCancelsPendingSaveFromPreviousWorkspaceContext() async throws {
        let workspaceAId = UUID()
        let workspaceBId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceAId)
        let atom = SidebarCacheState()
        let clock = TestPushClock()
        let store = SidebarCacheStore(
            atom: atom,
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock
        )
        await store.restoreAsync(for: workspaceAId)
        store.startObserving()
        atom.setGroupExpanded(SidebarGroupKey("repo:stale-workspace"), isExpanded: false)
        await clock.waitForPendingSleepCount()

        await store.restoreAsync(for: workspaceBId)
        clock.advance(by: .milliseconds(10))
        await Task.yield()

        #expect(try fixture.repository.hasCollapsedGroupsState() == false)
    }

    @Test
    func observationIsExplicitlyArmed() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let store = SidebarCacheStore(
            atom: SidebarCacheState(),
            sqliteDatastore: try await preparedWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        )

        #expect(store.isAutosaveObservationActive == false)
        await store.restoreAsync(for: workspaceId)
        #expect(store.isAutosaveObservationActive == false)
        store.startObserving()
        #expect(store.isAutosaveObservationActive)
    }
}
