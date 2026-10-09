import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@Suite
struct DrawerPanelCommandMappingTests {
    @Test
    func test_drawerPanelTranslatesVisiblePairResizeToDrawerOwnedCommand() {
        let parentPaneId = UUID()
        let tabId = UUID()
        let leftPaneId = UUID()
        let rightPaneId = UUID()

        let command = DrawerPanel.drawerCommand(
            for: .resizeVisiblePanePair(
                tabId: tabId,
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId,
                ratio: 0.4
            ),
            parentPaneId: parentPaneId
        )

        #expect(
            command
                == .resizeDrawerVisiblePanePair(
                    parentPaneId: parentPaneId,
                    leftPaneId: leftPaneId,
                    rightPaneId: rightPaneId,
                    ratio: 0.4
                )
        )
    }
}

@MainActor
@Suite(.serialized)
final class DrawerCommandIntegrationTests {

    private var store: WorkspaceStore!
    private var viewRegistry: ViewRegistry!
    private var coordinator: WorkspaceSurfaceCoordinator!
    private var runtime: SessionRuntime!
    private var surfaceManager: MockWorkspaceSurfaceCoordinatorSurfaceManager!
    private var executor: WorkspaceActionExecutor!
    private var tempDir: URL!

    init() throws {
        installTestCoreAtomsIfNeeded()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "drawer-cmd-tests-\(UUID().uuidString)")
        store = try makeWorkspaceJournalTestStore()
        viewRegistry = ViewRegistry()
        runtime = SessionRuntime(store: store)
        surfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        coordinator = WorkspaceSurfaceCoordinator(
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
        executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
        executor = nil
        surfaceManager = nil
        coordinator = nil
        runtime = nil
        viewRegistry = nil
        store = nil
    }

    // MARK: - Helpers

    private func withDrawerCommandHarness(_ operation: @MainActor () async throws -> Void) async throws {
        do {
            try await operation()
        } catch {
            await executor.stopAcceptingCommandsAndDrain()
            await coordinator.shutdown()
            throw error
        }
        await executor.stopAcceptingCommandsAndDrain()
        await coordinator.shutdown()
    }

    /// Creates a parent pane in a tab and returns the pane ID.
    @discardableResult
    private func createParentPaneInTab() -> (paneId: UUID, tabId: UUID) {
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        return (pane.id, tab.id)
    }

    private func drawerView(for parentPaneId: UUID) -> DrawerView? {
        store.drawerView(forParent: parentPaneId)
    }

    // MARK: - test_addDrawerPane_keepsDrawerStateWhenGeometryDeferred

    @Test

    func test_addDrawerPane_keepsDrawerStateWhenGeometryDeferred() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()
            let paneCountBefore = store.panes.count

            // Act
            await executor.execute(.addDrawerPane(parentPaneId: parentPaneId))

            // Assert — without trusted bounds, creation defers and canonical drawer state remains.
            let parentPane = store.pane(parentPaneId)
            #expect((parentPane?.drawer) != nil)
            #expect(parentPane!.drawer!.paneIds.count == 1, "Drawer pane should remain in canonical state")
            #expect(
                store.panes.count == paneCountBefore + 1,
                "Drawer pane should remain in store while view creation is deferred")
        }
    }

    // MARK: - test_closeDrawerPane_removesActiveDrawerPane

    @Test

    func test_closeDrawerPane_removesActiveDrawerPane() async throws {
        try await withDrawerCommandHarness {
            // Arrange — add 2 drawer panes
            let (parentPaneId, _) = createParentPaneInTab()

            let dp1 = store.addDrawerPane(to: parentPaneId)!
            let dp2 = store.addDrawerPane(to: parentPaneId)!
            #expect(store.pane(parentPaneId)!.drawer!.paneIds.count == 2)
            #expect(
                drawerView(for: parentPaneId)?.activeChildId == dp2.id,
                "Last added drawer pane should be active initially")

            // Act — close the active drawer pane (dp2)
            await executor.execute(.removeDrawerPane(parentPaneId: parentPaneId, drawerPaneId: dp2.id))

            // Assert
            let drawer = store.pane(parentPaneId)!.drawer
            #expect((drawer) != nil)
            #expect(drawer!.paneIds.count == 1, "Only 1 drawer pane should remain")
            #expect(drawer!.paneIds[0] == dp1.id, "The remaining pane should be dp1")
            #expect(drawerView(for: parentPaneId)?.activeChildId == dp1.id, "dp1 should become the active drawer pane")
        }
    }

    // MARK: - Toggle Drawer

    @Test

    func test_toggleDrawer_expandsCollapsedDrawer() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()
            store.addDrawerPane(to: parentPaneId)
            // Drawer auto-expands on add; collapse it first
            store.toggleDrawer(for: parentPaneId)
            #expect(!(store.pane(parentPaneId)!.drawer!.isExpanded))

            // Act
            await executor.execute(.toggleDrawer(paneId: parentPaneId))

            // Assert
            #expect(store.pane(parentPaneId)!.drawer!.isExpanded)
        }
    }

    @Test

    func test_toggleDrawer_collapsesExpandedDrawer() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()
            store.addDrawerPane(to: parentPaneId)
            #expect(store.pane(parentPaneId)!.drawer!.isExpanded)

            // Act
            await executor.execute(.toggleDrawer(paneId: parentPaneId))

            // Assert
            #expect(!(store.pane(parentPaneId)!.drawer!.isExpanded))
        }
    }

    @Test
    func drawerSelectedPane_updatesTopologyStateForPaneLocationCommands() async throws {
        try await withDrawerCommandHarness {
            let (parentPaneId, tabId) = createParentPaneInTab()
            let drawerPane = store.addDrawerPane(to: parentPaneId)!
            store.setActiveDrawerPane(drawerPane.id, in: parentPaneId)
            store.setActiveTab(tabId)

            let snapshot = WorkspaceCommandResolver.snapshot(
                from: store.tabLayoutAtom.tabs,
                activeTabId: store.tabLayoutAtom.activeTabId,
                isManagementLayerActive: atom(\.managementLayer).isActive,
                knownWorktreeIds: Set(store.repositoryTopologyAtom.repos.flatMap(\.worktrees).map(\.id))
            )

            #expect(snapshot.activeTabId == tabId)
            #expect(drawerView(for: parentPaneId)?.activeChildId == drawerPane.id)
        }
    }

    // MARK: - Set Active Drawer Pane

    @Test

    func test_setActiveDrawerPane_switchesActivePaneId() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()
            let dp1 = store.addDrawerPane(to: parentPaneId)!
            let dp2 = store.addDrawerPane(to: parentPaneId)!
            #expect(drawerView(for: parentPaneId)?.activeChildId == dp2.id)

            // Act
            await executor.execute(.setActiveDrawerPane(parentPaneId: parentPaneId, drawerPaneId: dp1.id))

            // Assert
            #expect(drawerView(for: parentPaneId)?.activeChildId == dp1.id)
        }
    }

    @Test
    func test_moveDrawerPane_reordersLayoutWithinSameParent() async throws {
        try await withDrawerCommandHarness {
            let (parentPaneId, _) = createParentPaneInTab()
            let dp1 = store.addDrawerPane(to: parentPaneId)!
            let dp2 = store.addDrawerPane(to: parentPaneId)!
            let dp3 = store.addDrawerPane(to: parentPaneId)!

            await executor.execute(
                .moveDrawerPane(
                    parentPaneId: parentPaneId,
                    drawerPaneId: dp1.id,
                    target: .rowSlot(row: .top, insertionIndex: 3),
                    sizingMode: .proportional
                )
            )

            let view = drawerView(for: parentPaneId)
            #expect(Set(view?.layout.paneIds ?? []) == Set([dp1.id, dp2.id, dp3.id]))
            #expect(view?.layout.paneIds.last == dp1.id)
            #expect(view?.activeChildId == dp1.id)
        }
    }

    @Test
    func test_moveDrawerPane_downIntoThirdRow_isNoOp() async throws {
        try await withDrawerCommandHarness {
            let (parentPaneId, _) = createParentPaneInTab()
            let topLeft = store.addDrawerPane(to: parentPaneId)!
            _ = store.addDrawerPane(to: parentPaneId)!
            let bottom = store.insertDrawerPane(
                in: parentPaneId,
                at: topLeft.id,
                direction: .vertical,
                position: .after, sizingMode: .halveTarget
            )!

            let before = drawerView(for: parentPaneId)?.layout

            await executor.execute(
                .moveDrawerPane(
                    parentPaneId: parentPaneId,
                    drawerPaneId: bottom.id,
                    target: .createSecondRow(position: .bottom),
                    sizingMode: .proportional
                )
            )

            #expect(drawerView(for: parentPaneId)?.layout == before)
        }
    }

    @Test
    func test_insertDrawerPane_verticalAfter_rendersBottomRow() async throws {
        try await withDrawerCommandHarness {
            let (parentPaneId, _) = createParentPaneInTab()
            let first = try #require(store.addDrawerPane(to: parentPaneId))

            await executor.execute(
                .insertDrawerPane(
                    parentPaneId: parentPaneId,
                    targetDrawerPaneId: first.id,
                    direction: .down,
                    sizingMode: .halveTarget
                )
            )

            let view = try #require(drawerView(for: parentPaneId))
            #expect(view.layout.bottomRow != nil)
        }
    }

    @Test
    func test_moveDrawerPane_verticalDrop_preservesTwoRowLegality() async throws {
        try await withDrawerCommandHarness {
            let (parentPaneId, _) = createParentPaneInTab()
            let first = try #require(store.addDrawerPane(to: parentPaneId))
            let second = try #require(store.addDrawerPane(to: parentPaneId))
            _ = store.insertDrawerPane(
                in: parentPaneId,
                at: first.id,
                direction: .vertical,
                position: .after, sizingMode: .halveTarget
            )

            await executor.execute(
                .moveDrawerPane(
                    parentPaneId: parentPaneId,
                    drawerPaneId: second.id,
                    target: .rowSlot(row: .bottom, insertionIndex: 1),
                    sizingMode: .proportional
                )
            )

            let view = try #require(drawerView(for: parentPaneId))
            #expect(view.layout.bottomRow?.contains(second.id) == true)
        }
    }

    @Test
    func test_detachDrawerPane_promotesPaneToParentRight() async throws {
        try await withDrawerCommandHarness {
            let (parentPaneId, tabId) = createParentPaneInTab()
            let drawerPane = try #require(store.addDrawerPane(to: parentPaneId))

            await executor.execute(.detachDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPane.id))

            let tab = try #require(store.tab(tabId))
            #expect(tab.paneIds == [parentPaneId, drawerPane.id])
            #expect(store.pane(parentPaneId)?.drawer?.paneIds.contains(drawerPane.id) == false)
            #expect(store.pane(drawerPane.id)?.isDrawerChild == false)
        }
    }

    // MARK: - Minimize / Expand Drawer Pane

    @Test

    func test_minimizeDrawerPane_hidesPane() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()
            let dp1 = store.addDrawerPane(to: parentPaneId)!
            store.addDrawerPane(to: parentPaneId)

            // Act
            await executor.execute(.minimizeDrawerPane(parentPaneId: parentPaneId, drawerPaneId: dp1.id))

            // Assert
            let view = drawerView(for: parentPaneId)
            #expect(view?.minimizedPaneIds.contains(dp1.id) == true)
        }
    }

    @Test

    func test_expandDrawerPane_restoresMinimizedPane() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()
            let dp1 = store.addDrawerPane(to: parentPaneId)!
            store.addDrawerPane(to: parentPaneId)
            store.minimizeDrawerPane(dp1.id, in: parentPaneId)
            #expect(drawerView(for: parentPaneId)?.minimizedPaneIds.contains(dp1.id) == true)

            // Act
            await executor.execute(.expandDrawerPane(parentPaneId: parentPaneId, drawerPaneId: dp1.id))

            // Assert
            let view = drawerView(for: parentPaneId)
            #expect(view?.minimizedPaneIds.contains(dp1.id) == false)
        }
    }

    // MARK: - Resize / Equalize Drawer Panes

    @Test

    func test_resizeDrawerPane_updatesLayout() async throws {
        try await withDrawerCommandHarness {
            // Arrange — create 2-pane drawer to get a split
            let (parentPaneId, _) = createParentPaneInTab()
            store.addDrawerPane(to: parentPaneId)
            store.addDrawerPane(to: parentPaneId)

            let view = drawerView(for: parentPaneId)
            guard let dividerId = view?.layout.dividerIds.first else {
                Issue.record("Expected a divider in 2-pane drawer layout")
                return
            }

            // Act
            await executor.execute(.resizeDrawerPane(parentPaneId: parentPaneId, splitId: dividerId, ratio: 0.7))

            // Assert
            let updated = drawerView(for: parentPaneId)
            #expect(abs((updated?.layout.ratioForSplit(dividerId) ?? 0.0) - (0.7)) <= 0.001)
        }
    }

    @Test
    func test_resizeDrawerVisiblePanePair_updatesVisiblePair() async throws {
        try await withDrawerCommandHarness {
            let (parentPaneId, _) = createParentPaneInTab()
            let drawerPane1 = try #require(store.addDrawerPane(to: parentPaneId))
            let drawerPane2 = try #require(store.addDrawerPane(to: parentPaneId))
            let drawerPane3 = try #require(store.addDrawerPane(to: parentPaneId))
            store.minimizeDrawerPane(drawerPane2.id, in: parentPaneId)
            let before = try #require(drawerView(for: parentPaneId)?.layout.topRow)

            await executor.execute(
                .resizeDrawerVisiblePanePair(
                    parentPaneId: parentPaneId,
                    leftPaneId: drawerPane1.id,
                    rightPaneId: drawerPane3.id,
                    ratio: 0.3
                )
            )

            let after = try #require(drawerView(for: parentPaneId)?.layout.topRow)
            #expect(
                abs((after.ratioForPanePair(leftPaneId: drawerPane1.id, rightPaneId: drawerPane3.id) ?? 0) - 0.3)
                    < 0.001)
            #expect(abs((after.paneRatio(drawerPane2.id) ?? 0) - (before.paneRatio(drawerPane2.id) ?? 0)) < 1e-9)
        }
    }

    @Test

    func test_equalizeDrawerPanes_resetsRatios() async throws {
        try await withDrawerCommandHarness {
            // Arrange — create 2-pane drawer and skew the ratio
            let (parentPaneId, _) = createParentPaneInTab()
            store.addDrawerPane(to: parentPaneId)
            store.addDrawerPane(to: parentPaneId)

            let view = drawerView(for: parentPaneId)
            guard let dividerId = view?.layout.dividerIds.first else {
                Issue.record("Expected divider")
                return
            }
            store.resizeDrawerPane(parentPaneId: parentPaneId, splitId: dividerId, ratio: 0.8)

            // Act
            await executor.execute(.equalizeDrawerPanes(parentPaneId: parentPaneId))

            // Assert
            let updated = drawerView(for: parentPaneId)
            #expect(abs((updated?.layout.ratioForSplit(dividerId) ?? 0.0) - (0.5)) <= 0.001)
        }
    }

    // MARK: - Multi-Pane Drawer Lifecycle

    @Test

    func test_addMultipleDrawerPanes_buildsLayoutTree() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()

            // Act — add 3 drawer panes
            let dp1 = store.addDrawerPane(to: parentPaneId)!
            let dp2 = store.addDrawerPane(to: parentPaneId)!
            let dp3 = store.addDrawerPane(to: parentPaneId)!

            // Assert
            let drawer = store.pane(parentPaneId)!.drawer!
            #expect(drawer.paneIds.count == 3)
            #expect(drawer.paneIds.contains(dp1.id))
            #expect(drawer.paneIds.contains(dp2.id))
            #expect(drawer.paneIds.contains(dp3.id))
        }
    }

    @Test

    func test_removeLastDrawerPane_leavesEmptyDrawer() async throws {
        try await withDrawerCommandHarness {
            // Arrange
            let (parentPaneId, _) = createParentPaneInTab()
            let dp = store.addDrawerPane(to: parentPaneId)!

            // Act
            await executor.execute(.removeDrawerPane(parentPaneId: parentPaneId, drawerPaneId: dp.id))

            // Assert
            let drawer = store.pane(parentPaneId)!.drawer!
            #expect(drawer.paneIds.isEmpty)
            #expect((drawerView(for: parentPaneId)?.activeChildId) == nil)
            // Pane should be removed from store
            #expect((store.pane(dp.id)) == nil)
        }
    }

    // MARK: - Close Parent Pane Cascades Drawer Children

    @Test

    func test_closeParentPane_removesDrawerChildren() async throws {
        try await withDrawerCommandHarness {
            // Arrange — parent with 2 drawer children in a 2-pane tab
            let p1 = store.createPane()
            let p2 = store.createPane()
            let tab = Tab(paneId: p1.id)
            store.appendTab(tab)
            store.insertPane(
                p2.id, inTab: tab.id, at: p1.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)

            let dp1 = store.addDrawerPane(to: p1.id)!
            let dp2 = store.addDrawerPane(to: p1.id)!

            #expect((store.pane(dp1.id)) != nil)
            #expect((store.pane(dp2.id)) != nil)

            // Act — close the parent pane
            await executor.execute(.closePane(tabId: tab.id, paneId: p1.id))

            // Assert — drawer children should be cascade-deleted
            #expect((store.pane(p1.id)) == nil)
            #expect((store.pane(dp1.id)) == nil)
            #expect((store.pane(dp2.id)) == nil)
        }
    }

}

@MainActor
private final class MockWorkspaceSurfaceCoordinatorSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {}
}
