import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioEditorChooser

@MainActor
@Suite(.serialized)
struct UIStateStoreTests {
    @Test
    func flushAndRestoreRoundTripsMainWindowSidebarState() async throws {
        let workspaceId = UUIDv7.generate()
        let fixture = try makeEditorChooserWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let datastore = try await editorChooserWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        let atom = WorkspaceSidebarState()
        let store = UIStateStore(atom: atom, sqliteDatastore: datastore)
        atom.setFilterText("agent")
        atom.setFilterVisible(true)
        atom.setSidebarCollapsed(true)
        atom.setSidebarSurface(.panes)
        atom.setRepoGroupingMode(.tab)
        atom.setPaneGroupingMode(.activity)
        atom.setRepoSubgroupMode(.activity)
        atom.setPaneSubgroupMode(.ungrouped)
        atom.setShowsPinnedRepos(false)
        atom.setShowsDrawerPanes(false)
        atom.setSidebarHasFocus(true)

        try await store.flushAsync(for: workspaceId)
        let restoredAtom = WorkspaceSidebarState()
        await UIStateStore(atom: restoredAtom, sqliteDatastore: datastore).restoreAsync(for: workspaceId)

        #expect(restoredAtom.filterText == "agent")
        #expect(restoredAtom.isFilterVisible)
        #expect(restoredAtom.sidebarCollapsed)
        #expect(restoredAtom.sidebarSurface == .panes)
        #expect(restoredAtom.repoGroupingMode == .tab)
        #expect(restoredAtom.paneGroupingMode == .activity)
        #expect(restoredAtom.repoSubgroupMode == .activity)
        #expect(restoredAtom.paneSubgroupMode == .ungrouped)
        #expect(!restoredAtom.showsPinnedRepos)
        #expect(restoredAtom.showsPinnedPanes)
        #expect(!restoredAtom.showsDrawerPanes)
        #expect(restoredAtom.sidebarHasFocus == false)
    }

    @Test
    func missingSQLiteRowResetsExistingStateToTypedDefaults() async throws {
        let workspaceId = UUID()
        let fixture = try makeEditorChooserWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = WorkspaceSidebarState()
        atom.setFilterText("stale")
        atom.setFilterVisible(true)
        atom.setSidebarCollapsed(true)
        atom.setSidebarSurface(.panes)
        atom.setRepoGroupingMode(.activity)
        atom.setSidebarHasFocus(true)

        await UIStateStore(
            atom: atom,
            sqliteDatastore: try await editorChooserWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        ).restoreAsync(for: workspaceId)

        #expect(atom.filterText.isEmpty)
        #expect(atom.isFilterVisible == false)
        #expect(atom.sidebarCollapsed == false)
        #expect(atom.sidebarSurface == .repos)
        #expect(atom.repoGroupingMode == .repo)
        #expect(atom.sidebarHasFocus == false)
    }

    @Test
    func unavailableSQLiteResetsDefaultsAndReportsRecovery() async throws {
        let workspaceId = UUID()
        let atom = WorkspaceSidebarState()
        atom.setFilterText("stale")
        atom.setSidebarSurface(.panes)
        atom.setRepoGroupingMode(.activity)
        var reportedRecoveries: [PersistenceRecoveryEvent] = []

        await UIStateStore(
            atom: atom,
            sqliteDatastore: try await editorChooserWorkspaceSQLiteDatastore(
                from: failingEditorChooserWorkspaceLocalSQLiteBackend()
            ),
            recoveryReporter: { reportedRecoveries.append($0) }
        ).restoreAsync(for: workspaceId)

        #expect(atom.filterText.isEmpty)
        #expect(atom.sidebarSurface == .repos)
        #expect(atom.repoGroupingMode == .repo)
        #expect(
            reportedRecoveries.contains { recovery in
                recovery.store == .uiState
                    && recovery.workspaceId == workspaceId
                    && recovery.recovery == .resetToDefaults
            })
    }

    @Test
    func observedSidebarMutationAutosavesSQLite() async throws {
        let factSource = UIStateStoreFactSource()
        let facts = try factSource.attach()
        let workspaceId = UUID()
        let fixture = try makeEditorChooserWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let atom = WorkspaceSidebarState()
        let clock = TestPushClock()
        let store = UIStateStore(
            atom: atom,
            sqliteDatastore: try await editorChooserWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock,
            factSink: factSource.sink
        )
        await store.restoreAsync(for: workspaceId)
        store.startObserving()

        atom.setFilterText("terminal")
        atom.setSidebarSurface(.panes)
        atom.setRepoGroupingMode(.tab)
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(10))

        _ = try await facts.expectNextSaveCompleted(workspaceId: workspaceId)
        let persistedState = try fixture.repository.fetchSidebarState()
        #expect(persistedState.filterText == "terminal")
        #expect(persistedState.sidebarSurface == .panes)
        #expect(persistedState.repoGroupingMode == .tab)
        try await facts.finish()
    }

    @Test
    func unrelatedEditorStateDoesNotTriggerUIStateStoreAutosave() async throws {
        let workspaceId = UUID()
        let fixture = try makeEditorChooserWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let preferenceAtom = EditorPreferenceAtom()
        let runtimeAtom = EditorChooserRuntimeAtom()
        let clock = TestPushClock()
        let store = UIStateStore(
            atom: WorkspaceSidebarState(),
            sqliteDatastore: try await editorChooserWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock
        )
        await store.restoreAsync(for: workspaceId)
        store.startObserving()

        preferenceAtom.setBookmarkedEditor("cursor")
        runtimeAtom.setOpenEditorPane(UUID())
        runtimeAtom.setAvailableTargets(ExternalEditorTarget.curatedOrder)
        for _ in 0..<20 { await Task.yield() }

        #expect(clock.pendingSleepCount == 0)
        #expect(try fixture.repository.hasSidebarState() == false)
    }

    @Test
    func restoreCancelsPendingSaveFromPreviousWorkspaceContext() async throws {
        let workspaceAId = UUID()
        let workspaceBId = UUID()
        let fixture = try makeEditorChooserWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceAId)
        let atom = WorkspaceSidebarState()
        let clock = TestPushClock()
        let store = UIStateStore(
            atom: atom,
            sqliteDatastore: try await editorChooserWorkspaceSQLiteDatastore(from: fixture.sqliteBackend),
            persistDebounceDuration: .milliseconds(10),
            clock: clock
        )
        await store.restoreAsync(for: workspaceAId)
        store.startObserving()
        atom.setFilterText("stale-workspace-draft")
        await clock.waitForPendingSleepCount()

        await store.restoreAsync(for: workspaceBId)
        clock.advance(by: .milliseconds(10))
        await Task.yield()

        #expect(try fixture.repository.hasSidebarState() == false)
    }

    @Test
    func observationIsExplicitlyArmed() async throws {
        let workspaceId = UUID()
        let fixture = try makeEditorChooserWorkspaceLocalSQLiteStoreFixture(workspaceId: workspaceId)
        let store = UIStateStore(
            atom: WorkspaceSidebarState(),
            sqliteDatastore: try await editorChooserWorkspaceSQLiteDatastore(from: fixture.sqliteBackend)
        )

        #expect(store.isAutosaveObservationActive == false)
        await store.restoreAsync(for: workspaceId)
        #expect(store.isAutosaveObservationActive == false)
        store.startObserving()
        #expect(store.isAutosaveObservationActive)
    }
}
