import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("WorkspaceSQLiteStoreBridgePersistenceTests", .serialized)
struct WorkspaceSQLiteStoreBridgePersistenceTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("SQLite flush after coordinator close removes parent drawer membership with two children")
    func sqliteFlushAfterCoordinatorClosePaneWithTwoDrawerChildrenPrunesDrawerMembership() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceId)
        let identityAtom = WorkspaceIdentityAtom(workspaceId: UUIDv7.generate())
        identityAtom.replaceIdentity(
            workspaceId: workspaceId,
            workspaceName: "Drawer Close SQLite Workspace",
            createdAt: Date(timeIntervalSince1970: 1_700_000_086)
        )
        let store = WorkspaceStore(
            identityAtom: identityAtom,
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        )
        let anchorPane = store.createPane(title: "Anchor")
        let parentPane = store.createPane(title: "Parent")
        let tab = Tab(paneId: anchorPane.id, name: "Drawer Close")
        store.appendTab(tab)
        #expect(
            store.insertPane(
                parentPane.id,
                inTab: tab.id,
                at: anchorPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        let firstDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)

        #expect(store.mutationCoordinator.removePane(parentPane.id))
        let outcome = await store.flushAsync()

        guard outcome.succeeded else {
            Issue.record("Expected close-pane SQLite flush to succeed")
            return
        }
        let paneGraph = try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceId)
        #expect(paneGraph.panes.map(\.id) == [anchorPane.id])
        #expect(!paneGraph.panes.map(\.id).contains(parentPane.id))
        #expect(!paneGraph.panes.map(\.id).contains(firstDrawerPane.id))
        #expect(!paneGraph.panes.map(\.id).contains(secondDrawerPane.id))
        let tabGraph = try fixture.coreRepository.fetchTabGraph(workspaceId: workspaceId)
        let savedTab = try #require(tabGraph.tabs.single)
        #expect(savedTab.allPaneIds == [anchorPane.id])
        #expect(savedTab.arrangements.allSatisfy { $0.drawerViews[drawerId] == nil })
    }

    @Test("SQLite flush after detaching a drawer pane persists it as a layout pane")
    func sqliteFlushAfterDetachDrawerPanePersistsDetachedPaneAsLayout() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceId)
        let identityAtom = WorkspaceIdentityAtom(workspaceId: UUIDv7.generate())
        identityAtom.replaceIdentity(
            workspaceId: workspaceId,
            workspaceName: "Drawer Detach SQLite Workspace",
            createdAt: Date(timeIntervalSince1970: 1_700_000_087)
        )
        let store = WorkspaceStore(
            identityAtom: identityAtom,
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        )
        let parentPane = store.createPane(title: "Parent")
        let tab = Tab(paneId: parentPane.id, name: "Drawer Detach")
        store.appendTab(tab)
        let detachedPane = try #require(store.addDrawerPane(to: parentPane.id))
        let remainingDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let surfaceManager = makeAppTerminalFixtureSurfaceManager()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )

        try await coordinator.execute(.detachDrawerPane(parentPaneId: parentPane.id, drawerPaneId: detachedPane.id))
        let outcome = await store.flushAsync()

        guard outcome.succeeded else {
            Issue.record("Expected detach-drawer-pane SQLite flush to succeed")
            return
        }
        let paneGraph = try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceId)
        let detachedRecord = try #require(paneGraph.panes.first { $0.id == detachedPane.id })
        #expect(detachedRecord.placement == .layout)
        let parentRecord = try #require(paneGraph.panes.first { $0.id == parentPane.id })
        #expect(parentRecord.drawer?.childPaneIds == [remainingDrawerPane.id])
        let tabGraph = try fixture.coreRepository.fetchTabGraph(workspaceId: workspaceId)
        let savedTab = try #require(tabGraph.tabs.single)
        #expect(Set(savedTab.allPaneIds) == Set([parentPane.id, remainingDrawerPane.id, detachedPane.id]))
        #expect(savedTab.arrangements.contains { $0.layout.contains(detachedPane.id) })
        #expect(
            savedTab.arrangements.compactMap { $0.drawerViews[drawerId]?.layout.paneIds }
                .allSatisfy { !$0.contains(detachedPane.id) }
        )
    }

    @Test("Fresh-store reactivation preserves every backgrounded drawer arrangement exactly")
    func freshStoreReactivationPreservesEveryBackgroundedDrawerArrangementExactly() async throws {
        let workspaceId = UUID()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceId)
        let identityAtom = WorkspaceIdentityAtom(workspaceId: UUIDv7.generate())
        identityAtom.replaceIdentity(
            workspaceId: workspaceId,
            workspaceName: "Drawer Background SQLite Workspace",
            createdAt: Date(timeIntervalSince1970: 1_700_000_088)
        )
        let store = WorkspaceStore(
            identityAtom: identityAtom,
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        )
        let anchorPane = store.createPane(title: "Anchor")
        let parentPane = store.createPane(title: "Parent")
        let tab = Tab(paneId: anchorPane.id, name: "Drawer Background")
        store.appendTab(tab)
        #expect(
            store.insertPane(
                parentPane.id,
                inTab: tab.id,
                at: anchorPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        let firstDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(store.pane(parentPane.id)?.drawer?.drawerId)
        store.resizeDrawerVisiblePanePair(
            parentPaneId: parentPane.id,
            leftPaneId: firstDrawerPane.id,
            rightPaneId: secondDrawerPane.id,
            ratio: 0.31
        )
        store.setActiveDrawerPane(secondDrawerPane.id, in: parentPane.id)
        _ = try #require(
            store.createArrangement(name: "Custom drawer", inTab: tab.id)
        )
        store.moveDrawerPane(
            secondDrawerPane.id,
            in: parentPane.id,
            target: .rowSlot(row: .top, insertionIndex: 0),
            sizingMode: .halveTarget
        )
        store.resizeDrawerVisiblePanePair(
            parentPaneId: parentPane.id,
            leftPaneId: secondDrawerPane.id,
            rightPaneId: firstDrawerPane.id,
            ratio: 0.67
        )
        #expect(store.minimizeDrawerPane(secondDrawerPane.id, in: parentPane.id))
        store.setActiveDrawerPane(firstDrawerPane.id, in: parentPane.id)
        let expectedTab = try #require(store.tab(tab.id))
        #expect(
            expectedTab.activeArrangement.drawerViews[drawerId]?.layout.paneIds
                == [secondDrawerPane.id, firstDrawerPane.id]
        )
        #expect(
            expectedTab.activeArrangement.drawerViews[drawerId]?.minimizedPaneIds
                == [secondDrawerPane.id]
        )
        #expect(
            expectedTab.activeArrangement.drawerViews[drawerId]?.activeChildId
                == firstDrawerPane.id
        )

        #expect(store.mutationCoordinator.backgroundPane(parentPane.id))
        #expect((await store.flushAsync()).succeeded)

        let restoredStore = WorkspaceStore(
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        )
        _ = await restoredStore.loadCanonicalComposition()
        #expect(restoredStore.tab(tab.id) == expectedTab)
        #expect(restoredStore.pane(parentPane.id)?.residency == .backgrounded)
        #expect(restoredStore.pane(firstDrawerPane.id)?.residency == .backgrounded)
        #expect(restoredStore.pane(secondDrawerPane.id)?.residency == .backgrounded)

        #expect(
            restoredStore.mutationCoordinator.reactivatePane(
                parentPane.id,
                inTab: tab.id,
                at: anchorPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        let reactivatedTab = try #require(restoredStore.tab(tab.id))
        #expect(reactivatedTab == expectedTab)
        #expect(reactivatedTab.allPaneIds.count == Set(reactivatedTab.allPaneIds).count)
        #expect(restoredStore.pane(parentPane.id)?.residency == .active)
        #expect(restoredStore.pane(firstDrawerPane.id)?.residency == .active)
        #expect(restoredStore.pane(secondDrawerPane.id)?.residency == .active)

        let outcome = await restoredStore.flushAsync()

        guard outcome.succeeded else {
            Issue.record("Expected background/reactivate SQLite flush to succeed")
            return
        }
        let tabGraph = try fixture.coreRepository.fetchTabGraph(workspaceId: workspaceId)
        let savedTab = try #require(tabGraph.tabs.single)
        expectSavedTabGraphMatches(savedTab, expectedTab: expectedTab, drawerID: drawerId)
    }
}

private func expectSavedTabGraphMatches(
    _ savedTab: WorkspaceCoreRepository.TabGraphStateRecord,
    expectedTab: Tab,
    drawerID: UUID
) {
    #expect(savedTab.tabId == expectedTab.id)
    #expect(savedTab.allPaneIds == expectedTab.allPaneIds)
    #expect(savedTab.arrangements.map(\.id) == expectedTab.arrangements.map(\.id))
    #expect(savedTab.arrangements.map(\.layout) == expectedTab.arrangements.map(\.layout))
    #expect(
        savedTab.arrangements.map { $0.drawerViews[drawerID]?.layout }
            == expectedTab.arrangements.map { $0.drawerViews[drawerID]?.layout }
    )
    #expect(
        savedTab.arrangements.map { $0.drawerViews[drawerID]?.minimizedPaneIds }
            == expectedTab.arrangements.map { $0.drawerViews[drawerID]?.minimizedPaneIds }
    )
}
