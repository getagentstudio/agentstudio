import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension PaneTabViewControllerDrawerCommandTests {
    @Test("targeted detachDrawerPane resolves through command handling and promotes the drawer pane")
    func targetedDetachDrawerPane_promotesSelectedDrawerPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let left = harness.store.createPane()
            let parent = harness.store.createPane()
            let tab = Tab(paneId: left.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                parent.id, inTab: tab.id, at: left.id, direction: .horizontal, position: .after,
                sizingMode: .halveTarget)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(parent.id, inTab: tab.id)

            let drawerPane = try #require(harness.store.addDrawerPane(to: parent.id))
            atom(\.workspaceFocusOwner).focusDrawerPane(parentPaneId: parent.id, paneId: drawerPane.id)

            await harness.executeCommand(.detachDrawerPane, target: drawerPane.id, targetType: .pane)

            #expect(harness.store.pane(drawerPane.id)?.parentPaneId == nil)
            #expect(harness.store.tab(tab.id)?.paneIds.contains(drawerPane.id) == true)
            #expect(harness.store.pane(parent.id)?.drawer?.paneIds.contains(drawerPane.id) == false)

        }
    }

    @Test(
        "detaching the selected drawer child skips minimized siblings and persists the workspace",
        arguments: [false, true]
    )
    func targetedDetachDrawerPane_skipsMinimizedSiblings_andPersists(allSiblingsMinimized: Bool) async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(parent.id, inTab: tab.id)
            let first = try #require(harness.store.addDrawerPane(to: parent.id))
            let selected = try #require(harness.store.addDrawerPane(to: parent.id))
            let last = try #require(harness.store.addDrawerPane(to: parent.id))
            harness.store.setActiveDrawerPane(selected.id, in: parent.id)
            #expect(harness.store.minimizeDrawerPane(first.id, in: parent.id))
            if allSiblingsMinimized {
                #expect(harness.store.minimizeDrawerPane(last.id, in: parent.id))
            }
            #expect(harness.store.drawerView(forParent: parent.id)?.activeChildId == selected.id)
            #expect(await harness.store.flushAsync() == .persisted)

            await harness.executeCommand(.detachDrawerPane, target: selected.id, targetType: .pane)

            #expect(harness.store.pane(selected.id)?.parentPaneId == nil)
            #expect(harness.store.tab(tab.id)?.activePaneIds.contains(selected.id) == true)
            #expect(harness.store.pane(parent.id)?.drawer?.paneIds == [first.id, last.id])
            let remainingView = try #require(harness.store.drawerView(forParent: parent.id))
            #expect(remainingView.activeChildId == (allSiblingsMinimized ? nil : last.id))
            #expect(remainingView.minimizedPaneIds == (allSiblingsMinimized ? [first.id, last.id] : [first.id]))
            #expect(await harness.store.flushAsync() == .persisted)
        }
    }

    @Test("direct detachDrawerPane promotes the focused drawer pane")
    func directDetachDrawerPane_promotesFocusedDrawerPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let left = harness.store.createPane()
            let parent = harness.store.createPane()
            let tab = Tab(paneId: left.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                parent.id, inTab: tab.id, at: left.id, direction: .horizontal, position: .after,
                sizingMode: .halveTarget)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(parent.id, inTab: tab.id)

            let drawerPane = try #require(harness.store.addDrawerPane(to: parent.id))
            atom(\.workspaceFocusOwner).focusDrawerPane(parentPaneId: parent.id, paneId: drawerPane.id)

            await harness.executeCommand(.detachDrawerPane)

            #expect(harness.store.pane(drawerPane.id)?.parentPaneId == nil)
            #expect(harness.store.tab(tab.id)?.paneIds.contains(drawerPane.id) == true)
            #expect(harness.store.pane(parent.id)?.drawer?.paneIds.contains(drawerPane.id) == false)

        }
    }

    @Test("dispatcher targeted detachDrawerPane works even when drawer pane is not the global focus owner")
    func dispatcherTargetedDetachDrawerPane_detachesClickedDrawerPaneWithoutDrawerPaneFocus() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let left = harness.store.createPane()
            let parent = harness.store.createPane()
            let tab = Tab(paneId: left.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                parent.id, inTab: tab.id, at: left.id, direction: .horizontal, position: .after,
                sizingMode: .halveTarget)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(parent.id, inTab: tab.id)
            _ = makePaneTabViewControllerCommandWindow(for: harness.controller)

            let firstDrawerPane = try #require(harness.store.addDrawerPane(to: parent.id))
            _ = try #require(harness.store.addDrawerPane(to: parent.id))
            atom(\.workspaceFocusOwner).focusMainPane(parent.id)

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = harness.controller
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    AppCommandDispatcher.shared.dispatch(
                        .detachDrawerPane,
                        target: firstDrawerPane.id,
                        targetType: .pane
                    )
                }
            )

            #expect(harness.store.pane(firstDrawerPane.id)?.parentPaneId == nil)
            #expect(harness.store.tab(tab.id)?.paneIds.contains(firstDrawerPane.id) == true)
            #expect(harness.store.pane(parent.id)?.drawer?.paneIds.contains(firstDrawerPane.id) == false)

        }
    }

    @Test("management layer create shortcut still works once option-ijkl are passed through")
    func executeManagementLayerCreateTerminal_openEmptyDrawer_createsFirstDrawerPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        await withWorkspaceCommandHarness(harness) {
            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.toggleDrawer(for: parent.id)
            atom(\.managementLayer).activate()

            await harness.executeCommand(.managementLayerCreateTerminal)

            #expect(harness.store.pane(parent.id)?.drawer?.paneIds.count == 1)

        }
    }

    @Test("managementLayerEnterDrawer enters the same drawer keyboard scope as enterDrawer")
    func executeManagementLayerEnterDrawer_focusesActiveDrawerPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parent.id))

            await harness.executeCommand(.managementLayerEnterDrawer)

            #expect(harness.store.drawerView(forParent: parent.id)?.activeChildId == drawerPane.id)

        }
    }

    @Test("management layer entry adopts expanded drawer scope for create terminal")
    func executeManagementCreateTerminal_afterEnteringManagementLayerWithExpandedDrawer_targetsDrawer() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane(
                title: "Parent",
                provider: .zmx
            )
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            guard let existingDrawerPane = harness.store.addDrawerPane(to: parentPane.id) else {
                Issue.record("Expected drawer pane creation")
                return
            }

            await harness.executeCommand(.toggleManagementLayer)

            let paneIdsBefore = Set(harness.store.panes.keys)
            let tabPaneIdsBefore = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsBefore = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            await harness.executeCommand(.managementLayerCreateTerminal)

            let paneIdsAfter = Set(harness.store.panes.keys)
            let createdPaneIds = paneIdsAfter.subtracting(paneIdsBefore)
            #expect(createdPaneIds.count == 1)
            let createdPaneId = try #require(createdPaneIds.first)

            let tabPaneIdsAfter = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsAfter = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            #expect(tabPaneIdsAfter == tabPaneIdsBefore)
            #expect(drawerPaneIdsAfter == drawerPaneIdsBefore.union([createdPaneId]))
            #expect(
                harness.controller.managementNavigationScopeDescriptionForTesting
                    == "drawer:\(parentPane.id.uuidString)"
            )
            #expect(harness.store.pane(existingDrawerPane.id) != nil)

        }
    }

    @Test("managementLayerCreateBrowser targets drawer after drawer pane selection")
    func executeManagementCreateBrowser_selectedDrawerTargetsDrawer() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane(
                title: "Parent",
                provider: .zmx
            )
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            guard let drawerPane = harness.store.addDrawerPane(to: parentPane.id) else {
                Issue.record("Expected drawer pane creation")
                return
            }

            atom(\.managementLayer).activate()

            harness.controller.handlePaneFocusTrigger(
                .drawer(.selectPane(parentPaneId: parentPane.id, drawerPaneId: drawerPane.id))
            )

            let paneIdsBefore = Set(harness.store.panes.keys)
            let tabPaneIdsBefore = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsBefore = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            await harness.executeCommand(.managementLayerCreateBrowser)

            let paneIdsAfter = Set(harness.store.panes.keys)
            let createdPaneIds = paneIdsAfter.subtracting(paneIdsBefore)
            #expect(createdPaneIds.count == 1)
            let createdPaneId = try #require(createdPaneIds.first)
            let createdPane = try #require(harness.store.pane(createdPaneId))

            let tabPaneIdsAfter = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsAfter = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            #expect(tabPaneIdsAfter == tabPaneIdsBefore)
            #expect(drawerPaneIdsAfter == drawerPaneIdsBefore.union([createdPaneId]))
            expectWebviewContent(createdPane, issuePrefix: "drawer selection browser creation")
            #expect(
                harness.controller.managementNavigationScopeDescriptionForTesting
                    == "drawer:\(parentPane.id.uuidString)"
            )

        }
    }

    @Test("managementLayerCreateBrowser in main row adds a split webview pane to the active tab")
    func executeManagementCreateBrowser_mainRowTargetsActiveTab() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane(
                title: "Parent",
                provider: .zmx
            )
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)

            await harness.executeCommand(.toggleManagementLayer)

            let paneIdsBefore = Set(harness.store.panes.keys)
            let tabPaneIdsBefore = Set(harness.store.tab(tab.id)?.paneIds ?? [])

            await harness.executeCommand(.managementLayerCreateBrowser)

            let paneIdsAfter = Set(harness.store.panes.keys)
            let createdPaneIds = paneIdsAfter.subtracting(paneIdsBefore)
            #expect(createdPaneIds.count == 1)
            let createdPaneId = try #require(createdPaneIds.first)
            let createdPane = try #require(harness.store.pane(createdPaneId))
            let tabPaneIdsAfter = Set(harness.store.tab(tab.id)?.paneIds ?? [])

            #expect(tabPaneIdsAfter == tabPaneIdsBefore.union([createdPaneId]))
            #expect(harness.store.pane(parentPane.id)?.drawer?.paneIds.isEmpty ?? true)
            expectWebviewContent(createdPane, issuePrefix: "main-row browser creation")
            #expect(harness.controller.managementNavigationScopeDescriptionForTesting == "mainRow")

        }
    }

    @Test("management layer entry adopts expanded drawer scope for create browser")
    func executeManagementCreateBrowser_afterEnteringManagementLayerWithExpandedDrawer_targetsDrawer() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane(
                title: "Parent",
                provider: .zmx
            )
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            _ = harness.store.addDrawerPane(to: parentPane.id)

            await harness.executeCommand(.toggleManagementLayer)

            let paneIdsBefore = Set(harness.store.panes.keys)
            let tabPaneIdsBefore = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsBefore = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            await harness.executeCommand(.managementLayerCreateBrowser)

            let paneIdsAfter = Set(harness.store.panes.keys)
            let createdPaneIds = paneIdsAfter.subtracting(paneIdsBefore)
            #expect(createdPaneIds.count == 1)
            let createdPaneId = try #require(createdPaneIds.first)
            let createdPane = try #require(harness.store.pane(createdPaneId))

            let tabPaneIdsAfter = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsAfter = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            #expect(tabPaneIdsAfter == tabPaneIdsBefore)
            #expect(drawerPaneIdsAfter == drawerPaneIdsBefore.union([createdPaneId]))
            expectWebviewContent(createdPane, issuePrefix: "entry drawer browser creation")
            #expect(
                harness.controller.managementNavigationScopeDescriptionForTesting
                    == "drawer:\(parentPane.id.uuidString)"
            )

        }
    }

    @Test("collapsed drawer falls back to main row for management terminal creation")
    func executeManagementCreateTerminal_afterDrawerDismiss_targetsMainRow() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane(
                title: "Parent",
                provider: .zmx
            )
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            _ = harness.store.addDrawerPane(to: parentPane.id)

            await harness.executeCommand(.toggleManagementLayer)
            await harness.executeCommand(.toggleDrawer)

            let paneIdsBefore = Set(harness.store.panes.keys)
            let tabPaneIdsBefore = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsBefore = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            await harness.executeCommand(.managementLayerCreateTerminal)

            let paneIdsAfter = Set(harness.store.panes.keys)
            let createdPaneIds = paneIdsAfter.subtracting(paneIdsBefore)
            #expect(createdPaneIds.count == 1)
            let createdPaneId = try #require(createdPaneIds.first)

            let tabPaneIdsAfter = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsAfter = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            #expect(tabPaneIdsAfter == tabPaneIdsBefore.union([createdPaneId]))
            #expect(drawerPaneIdsAfter == drawerPaneIdsBefore)
            #expect(harness.controller.managementNavigationScopeDescriptionForTesting == "mainRow")

        }
    }

    @Test("collapsed drawer falls back to main row for management browser creation")
    func executeManagementCreateBrowser_afterDrawerDismiss_targetsMainRow() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane(
                title: "Parent",
                provider: .zmx
            )
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            _ = harness.store.addDrawerPane(to: parentPane.id)

            await harness.executeCommand(.toggleManagementLayer)
            await harness.executeCommand(.toggleDrawer)

            let paneIdsBefore = Set(harness.store.panes.keys)
            let tabPaneIdsBefore = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsBefore = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            await harness.executeCommand(.managementLayerCreateBrowser)

            let paneIdsAfter = Set(harness.store.panes.keys)
            let createdPaneIds = paneIdsAfter.subtracting(paneIdsBefore)
            #expect(createdPaneIds.count == 1)
            let createdPaneId = try #require(createdPaneIds.first)
            let createdPane = try #require(harness.store.pane(createdPaneId))

            let tabPaneIdsAfter = Set(harness.store.tab(tab.id)?.paneIds ?? [])
            let drawerPaneIdsAfter = Set(harness.store.pane(parentPane.id)?.drawer?.paneIds ?? [])

            #expect(tabPaneIdsAfter == tabPaneIdsBefore.union([createdPaneId]))
            #expect(drawerPaneIdsAfter == drawerPaneIdsBefore)
            expectWebviewContent(createdPane, issuePrefix: "collapsed drawer browser creation")
            #expect(harness.controller.managementNavigationScopeDescriptionForTesting == "mainRow")

        }
    }

    func makeDrawerOrdinalPaneSet(
        in harness: PaneTabViewControllerCommandHarness,
        paneCount: Int
    ) throws -> (parent: Pane, drawerPanes: [Pane]) {
        let parent = harness.store.createPane()
        let tab = Tab(paneId: parent.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(parent.id, inTab: tab.id)
        atom(\.workspaceFocusOwner).focusMainPane(parent.id)

        let firstDrawerPane = try #require(harness.store.addDrawerPane(to: parent.id))
        var drawerPanes = [firstDrawerPane]
        for _ in 1..<paneCount {
            let anchorPaneId = try #require(harness.store.drawerView(forParent: parent.id)?.layout.paneIds.last)
            let drawerPane = try #require(
                harness.store.insertDrawerPane(
                    in: parent.id,
                    at: anchorPaneId,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            drawerPanes.append(drawerPane)
        }
        harness.store.setActiveDrawerPane(firstDrawerPane.id, in: parent.id)
        return (parent, drawerPanes)
    }
}
