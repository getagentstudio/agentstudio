import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerTargetedFocusCommandTests {
    @Test("a targeted drawer-focus case preserves its caller's core atoms")
    func targetedFocusCasePreservesCallerAtomScope() async throws {
        try await withAsyncTestAtomRegistry { registry in
            let callerPaneId = UUIDv7.generate()
            registry.core.workspaceFocusOwner.focusMainPane(callerPaneId)
            registry.core.managementLayer.activate()

            try await executeFocusDrawerPaneReattachesChildRevealedByArrangementSwitch()

            #expect(registry.core.workspaceFocusOwner.owner == .mainPane(paneId: callerPaneId))
            #expect(registry.core.managementLayer.isActive)
        }
    }

    @Test("targeted focusPane is available for an existing main pane")
    func canExecuteFocusPane_targetedMainPane() {
        withTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }

            let firstPane = harness.store.createPane()
            let secondPane = harness.store.createPane()
            let firstTab = Tab(paneId: firstPane.id)
            let secondTab = Tab(paneId: secondPane.id)
            harness.store.appendTab(firstTab)
            harness.store.appendTab(secondTab)
            harness.store.setActiveTab(firstTab.id)

            #expect(
                harness.controller.canExecute(
                    .focusPane,
                    target: secondPane.id,
                    targetType: .floatingTerminal
                )
            )
        }
    }

    @Test("headless focusPane applies only after selecting the exact pane in an inactive tab")
    func headlessFocusPaneAwaitsExactInactiveTabSelection() async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }

            let firstPane = harness.store.createPane()
            let destinationActivePane = harness.store.createPane()
            let targetPane = harness.store.createPane()
            let firstTab = Tab(paneId: firstPane.id)
            let secondTab = Tab(paneId: destinationActivePane.id)
            harness.store.appendTab(firstTab)
            harness.store.appendTab(secondTab)
            harness.store.insertPane(
                targetPane.id,
                inTab: secondTab.id,
                at: destinationActivePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            harness.store.setActivePane(destinationActivePane.id, inTab: secondTab.id)
            harness.store.setActiveTab(firstTab.id)

            #expect(harness.store.tab(secondTab.id)?.activePaneId == destinationActivePane.id)

            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let targetHost = try attachPaneHost(paneId: targetPane.id, in: harness, to: window)

            let outcome = try await harness.executeHeadlessPaneCommand(.focusPane, paneId: targetPane.id)

            #expect(outcome == .applied)
            #expect(harness.store.activeTabId == secondTab.id)
            #expect(harness.store.tab(secondTab.id)?.activePaneId == targetPane.id)
            #expect(window.firstResponder === targetHost)
        }
    }

    @Test("targeted focusPane selects the exact non-current pane")
    func executeFocusPaneSelectsExactNonCurrentPane() async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }

            let firstPane = harness.store.createPane()
            let destinationActivePane = harness.store.createPane()
            let targetPane = harness.store.createPane()
            let firstTab = Tab(paneId: firstPane.id)
            let secondTab = Tab(paneId: destinationActivePane.id)
            harness.store.appendTab(firstTab)
            harness.store.appendTab(secondTab)
            harness.store.insertPane(
                targetPane.id,
                inTab: secondTab.id,
                at: destinationActivePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            harness.store.setActivePane(destinationActivePane.id, inTab: secondTab.id)
            harness.store.setActiveTab(firstTab.id)
            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let targetHost = try attachPaneHost(paneId: targetPane.id, in: harness, to: window)

            await harness.executeCommand(.focusPane, target: targetPane.id, targetType: .pane)

            #expect(harness.store.activeTabId == secondTab.id)
            #expect(harness.store.tab(secondTab.id)?.activePaneId == targetPane.id)
            #expect(window.firstResponder === targetHost)
        }
    }

    @Test("targeted focusPane rejects a stale pane without changing selection")
    func executeFocusPaneRejectsStalePaneWithoutFallback() async {
        await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }

            let pane = harness.store.createPane()
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let stalePaneId = UUIDv7.generate()
            let tabCountBeforeFocus = harness.store.tabs.count
            let paneCountBeforeFocus = harness.store.paneAtom.graphAtom.paneIDs.count

            #expect(!harness.controller.canExecute(.focusPane, target: stalePaneId, targetType: .pane))
            await harness.executeCommand(.focusPane, target: stalePaneId, targetType: .pane)

            #expect(harness.store.activeTabId == tab.id)
            #expect(harness.store.tab(tab.id)?.activePaneId == pane.id)
            #expect(harness.store.tabs.count == tabCountBeforeFocus)
            #expect(harness.store.paneAtom.graphAtom.paneIDs.count == paneCountBeforeFocus)
        }
    }

    @Test("targeted focus chooses the first custom arrangement where the pane is visible")
    func executeFocusPaneChoosesFirstVisibleCustomArrangement() async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let visiblePane = harness.store.createPane()
            let targetPane = harness.store.createPane()
            let tab = makeTab(paneIds: [visiblePane.id, targetPane.id], activePaneId: visiblePane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let visibleCustomID = try #require(harness.store.createArrangement(name: "Visible", inTab: tab.id))
            let hiddenCurrentID = try #require(harness.store.createArrangement(name: "Hidden", inTab: tab.id))
            harness.store.switchArrangement(to: hiddenCurrentID, inTab: tab.id)
            #expect(harness.store.minimizePane(targetPane.id, inTab: tab.id))
            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let targetHost = try attachPaneHost(paneId: targetPane.id, in: harness, to: window)

            await harness.executeCommand(.focusPane, target: targetPane.id, targetType: .pane)

            #expect(harness.store.tab(tab.id)?.activeArrangementId == visibleCustomID)
            #expect(harness.store.tab(tab.id)?.activePaneId == targetPane.id)
            #expect(window.firstResponder === targetHost)
        }
    }

    @Test("targeted drawer focus falls back to Default then expands and focuses the child")
    func executeFocusDrawerPaneFallsBackToDefaultAndExpandsChild() async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let defaultArrangementID = try #require(harness.store.tab(tab.id)?.activeArrangementId)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
            let firstCustomID = try #require(harness.store.createArrangement(name: "First", inTab: tab.id))
            #expect(harness.store.minimizeDrawerPane(drawerPane.id, in: parentPane.id))
            let currentCustomID = try #require(harness.store.createArrangement(name: "Current", inTab: tab.id))
            #expect(firstCustomID != currentCustomID)
            harness.store.switchArrangement(to: defaultArrangementID, inTab: tab.id)
            #expect(harness.store.minimizeDrawerPane(drawerPane.id, in: parentPane.id))
            harness.store.switchArrangement(to: currentCustomID, inTab: tab.id)
            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            try attachPaneHost(paneId: parentPane.id, in: harness, to: window)
            let childHost = try attachPaneHost(paneId: drawerPane.id, in: harness, to: window)

            await harness.executeCommand(.focusPane, target: drawerPane.id, targetType: .pane)

            #expect(harness.store.tab(tab.id)?.activeArrangementId == defaultArrangementID)
            #expect(harness.store.paneAtom.pane(parentPane.id)?.drawer?.isExpanded == true)
            #expect(
                harness.store.drawerView(forParent: parentPane.id)?.minimizedPaneIds.contains(drawerPane.id) == false)
            #expect(
                atom(\.workspaceFocusOwner).owner == .drawerPane(parentPaneId: parentPane.id, paneId: drawerPane.id))
            #expect(window.firstResponder === childHost)
        }
    }

    @Test("targeted drawer focus reattaches a child revealed by an arrangement switch")
    func executeFocusDrawerPaneReattachesChildRevealedByArrangementSwitch() async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
            let visibleCustomID = try #require(harness.store.createArrangement(name: "Visible", inTab: tab.id))
            let minimizedCurrentID = try #require(harness.store.createArrangement(name: "Current", inTab: tab.id))
            #expect(visibleCustomID != minimizedCurrentID)

            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            try attachPaneHost(paneId: parentPane.id, in: harness, to: window)
            let surfaceID = UUIDv7.generate()
            let terminalView = TerminalPaneMountView(
                restoredSurfaceId: surfaceID,
                paneId: drawerPane.id
            )
            try attachPaneHost(
                paneId: drawerPane.id,
                in: harness,
                to: window,
                mountedContent: terminalView
            )
            let didMinimize = await harness.executor.submitGesture { execute in
                await execute(
                    .minimizeDrawerPane(parentPaneId: parentPane.id, drawerPaneId: drawerPane.id)
                )
            }.value
            #expect(didMinimize)
            #expect(harness.surfaceManager.detachedSurfaceRequests.map(\.surfaceId) == [surfaceID])
            let attachRequestCountBeforeFocus = harness.surfaceManager.attachedSurfaceRequests.count

            await harness.executeCommand(.focusPane, target: drawerPane.id, targetType: .pane)

            #expect(harness.store.tab(tab.id)?.activeArrangementId == visibleCustomID)
            #expect(
                harness.store.drawerView(forParent: parentPane.id)?.minimizedPaneIds.contains(drawerPane.id) == false)
            #expect(
                atom(\.workspaceFocusOwner).owner == .drawerPane(parentPaneId: parentPane.id, paneId: drawerPane.id))
            #expect(window.firstResponder === terminalView)
            #expect(
                Array(harness.surfaceManager.attachedSurfaceRequests.dropFirst(attachRequestCountBeforeFocus))
                    .contains { $0.surfaceId == surfaceID && $0.paneId == drawerPane.id }
            )
        }
    }

    @Test("spatial focus keeps focus when the only neighbor is minimized")
    func spatialFocusKeepsMinimizedNeighborHidden() async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let firstPane = harness.store.createPane()
            let secondPane = harness.store.createPane()
            let tab = makeTab(paneIds: [firstPane.id, secondPane.id], activePaneId: firstPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let customID = try #require(harness.store.createArrangement(name: "Spatial", inTab: tab.id))
            #expect(harness.store.minimizePane(secondPane.id, inTab: tab.id))

            await harness.executeCommand(.focusPaneRight)

            #expect(harness.store.tab(tab.id)?.activeArrangementId == customID)
            #expect(harness.store.tab(tab.id)?.activeMinimizedPaneIds.contains(secondPane.id) == true)
            #expect(harness.store.tab(tab.id)?.activePaneId == firstPane.id)
        }
    }

    @Test("spatial focus skips a minimized pane in either direction", arguments: [false, true])
    func spatialFocusSkipsMinimizedPane(movingLeft: Bool) async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let leftPane = harness.store.createPane()
            let minimizedPane = harness.store.createPane()
            let rightPane = harness.store.createPane()
            let origin = movingLeft ? rightPane : leftPane
            let destination = movingLeft ? leftPane : rightPane
            let tab = makeTab(
                paneIds: [leftPane.id, minimizedPane.id, rightPane.id], activePaneId: origin.id
            )
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let customID = try #require(harness.store.createArrangement(name: "Spatial", inTab: tab.id))
            #expect(harness.store.minimizePane(minimizedPane.id, inTab: tab.id))
            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let originHost = try attachPaneHost(paneId: origin.id, in: harness, to: window)
            let destinationHost = try attachPaneHost(paneId: destination.id, in: harness, to: window)
            #expect(window.makeFirstResponder(originHost))

            await harness.executeCommand(movingLeft ? .focusPaneLeft : .focusPaneRight)

            #expect(harness.store.tab(tab.id)?.activeArrangementId == customID)
            #expect(harness.store.tab(tab.id)?.activeMinimizedPaneIds == [minimizedPane.id])
            #expect(harness.store.tab(tab.id)?.activePaneId == destination.id)
            #expect(window.firstResponder === destinationHost)

            // The edge is a no-op, including after another command in the same direction.
            await harness.executeCommand(movingLeft ? .focusPaneLeft : .focusPaneRight)
            #expect(harness.store.tab(tab.id)?.activePaneId == destination.id)
            #expect(window.firstResponder === destinationHost)
            #expect(harness.store.tab(tab.id)?.activeMinimizedPaneIds == [minimizedPane.id])
        }
    }

    @Test("spatial focus skips a backgrounded pane retained in the arrangement")
    func spatialFocusSkipsBackgroundedPane() async throws {
        try await withAsyncTestAtomRegistry { _ in
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let firstPane = harness.store.createPane()
            let backgroundedPane = harness.store.createPane()
            let lastPane = harness.store.createPane()
            let tab = makeTab(paneIds: [firstPane.id, backgroundedPane.id, lastPane.id], activePaneId: firstPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.paneAtom.setResidency(.backgrounded, for: backgroundedPane.id)
            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let destinationHost = try attachPaneHost(paneId: lastPane.id, in: harness, to: window)

            await harness.executeCommand(.focusPaneRight)

            #expect(harness.store.tab(tab.id)?.activeArrangementId == tab.activeArrangementId)
            #expect(harness.store.tab(tab.id)?.activePaneId == lastPane.id)
            #expect(harness.store.paneAtom.pane(backgroundedPane.id)?.residency == .backgrounded)
            #expect(window.firstResponder === destinationHost)
        }
    }
}
