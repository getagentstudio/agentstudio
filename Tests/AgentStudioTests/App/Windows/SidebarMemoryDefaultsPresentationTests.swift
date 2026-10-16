import AgentStudioInfrastructure
import AppKit
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Sidebar memory defaults at presentation", .serialized)
struct SidebarMemoryDefaultsPresentationTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("absent sidebar record uses defaults and native visibility agrees", arguments: [true, false])
    func absentRecordUsesNativeAndSemanticDefaults(withRepositories: Bool) async throws {
        try await restoreDefaultsIntoWindow(withRepositories: withRepositories, unreadableRecord: false)
    }

    @Test("unreadable sidebar record recovers to defaults and native visibility agrees", arguments: [true, false])
    func unreadableRecordUsesNativeAndSemanticDefaults(withRepositories: Bool) async throws {
        try await restoreDefaultsIntoWindow(withRepositories: withRepositories, unreadableRecord: true)
    }

    private func restoreDefaultsIntoWindow(withRepositories: Bool, unreadableRecord: Bool) async throws {
        try await withUnloadedMainSplitViewControllerHarness(
            withRepos: withRepositories,
            startsObserving: false,
            configureUIState: { state in
                state.setFilterText("stale filter")
                state.setFilterVisible(true)
                state.setSidebarSurface(.panes)
                state.setSidebarCollapsed(true)
                state.setRepoGroupingMode(.activity)
                state.setPaneGroupingMode(.tab)
                state.setShowsPinnedRepos(false)
                state.setShowsPinnedPanes(false)
                state.setShowsDrawerPanes(false)
            },
            body: { harness in
                let localURL = harness.tempDir.appending(path: "local.sqlite")
                let datastore = WorkspaceSQLiteDatastoreFactory(
                    coreDatabaseURL: harness.tempDir.appending(path: "core.sqlite"),
                    localDatabaseURL: localURL
                ).makeDatastore()
                guard case .prepared = await datastore.prepareDatabasesForBoot() else {
                    Issue.record("The defaults fixture's real SQLite databases must prepare")
                    return
                }
                let workspaceID = harness.store.identityAtom.workspaceId
                if unreadableRecord {
                    try await datastore.saveUIState(
                        .init(
                            filterText: "stored filter",
                            isFilterVisible: true,
                            sidebarCollapsed: true,
                            sidebarSurface: .panes
                        ),
                        workspaceContextId: workspaceID
                    )
                    // Preserve a real row and database; reject only its typed UI
                    // payload, exercising loadUIState's unavailable disposition.
                    let database = try SQLiteDatabaseFactory.makeFileBackedPool(at: localURL)
                    try await database.write { database in
                        try database.execute(
                            sql: """
                                UPDATE local_window_state SET sidebar_surface = 'unsupported-surface'
                                WHERE window_role = 'main'
                                """
                        )
                    }
                    guard case .unavailable = await datastore.loadUIState(workspaceContextId: workspaceID) else {
                        Issue.record("The unreadable fixture must reach the datastore's UI-load failure path")
                        return
                    }
                } else {
                    #expect(await datastore.loadUIState(workspaceContextId: workspaceID) == .loaded(nil))
                }

                let sidebarState = harness.atoms.core.workspaceSidebarState
                var recoveries: [PersistenceRecoveryEvent] = []
                let uiStore = UIStateStore(
                    atom: sidebarState,
                    sqliteDatastore: datastore,
                    recoveryReporter: { recoveries.append($0) }
                )
                await uiStore.restoreAsync(for: workspaceID)

                #expect(sidebarState.filterText.isEmpty)
                #expect(!sidebarState.isFilterVisible)
                #expect(sidebarState.sidebarSurface == .repos)
                #expect(!sidebarState.sidebarCollapsed)
                #expect(sidebarState.repoGroupingMode == .repo)
                #expect(sidebarState.paneGroupingMode == .repo)
                #expect(sidebarState.showsPinnedRepos)
                #expect(sidebarState.showsPinnedPanes)
                #expect(sidebarState.showsDrawerPanes)
                #expect(!uiStore.isAutosaveObservationActive)
                #expect(recoveries.count == (unreadableRecord ? 1 : 0))
                if unreadableRecord {
                    let recovery = try #require(recoveries.first)
                    #expect(recovery.store == .uiState)
                    #expect(recovery.workspaceId == workspaceID)
                    #expect(recovery.recovery == .resetToDefaults)
                }

                harness.window.isReleasedWhenClosed = false
                defer {
                    harness.window.contentViewController = nil
                    harness.window.close()
                }
                harness.window.contentViewController = harness.controller
                harness.controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
                harness.controller.splitView.frame = harness.controller.view.bounds
                harness.window.layoutIfNeeded()
                harness.controller.view.layoutSubtreeIfNeeded()
                harness.controller.splitView.adjustSubviews()

                #expect(harness.controller.isSidebarCollapsed == !withRepositories)
                #expect(sidebarState.sidebarCollapsed == harness.controller.isSidebarCollapsed)
                #expect(sidebarState.sidebarSurface == .repos)
                #expect(sidebarState.filterText.isEmpty)
            }
        )
    }
}
