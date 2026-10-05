import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
extension PaneTabViewControllerZoomCommandTests {
    @Test("same-tab explicit Zoom focuses its source without changing durable arrangement")
    func explicitSameTabZoomFocusesSourceWithoutChangingDurableArrangement() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let zoomSourcePane = harness.store.createPane()
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                zoomSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)
        let durableArrangement = try #require(harness.store.tab(tab.id)?.activeArrangement)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let durableContent = FocusablePaneTabCommandMountedContentView()
        let zoomSourceContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: durablePane.id, in: harness, to: window, mountedContent: durableContent)
        _ = try attachPaneHost(
            paneId: zoomSourcePane.id, in: harness, to: window, mountedContent: zoomSourceContent)
        #expect(window.makeFirstResponder(durableContent))

        await harness.executeCommand(.zoomPane, target: zoomSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)

        #expect(window.firstResponder === zoomSourceContent)
        #expect(harness.store.tab(tab.id)?.activeArrangement == durableArrangement)
    }

    @Test("same-tab Zoom retarget refocuses the new source")
    func sameTabZoomRetargetRefocusesNewSource() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let firstSourcePane = harness.store.createPane()
        let secondSourcePane = harness.store.createPane()
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                firstSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        #expect(
            harness.store.insertPane(
                secondSourcePane.id, inTab: tab.id, at: firstSourcePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let durableContent = FocusablePaneTabCommandMountedContentView()
        let firstSourceContent = FocusablePaneTabCommandMountedContentView()
        let secondSourceContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: durablePane.id, in: harness, to: window, mountedContent: durableContent)
        _ = try attachPaneHost(
            paneId: firstSourcePane.id, in: harness, to: window, mountedContent: firstSourceContent)
        _ = try attachPaneHost(
            paneId: secondSourcePane.id, in: harness, to: window, mountedContent: secondSourceContent)
        #expect(window.makeFirstResponder(durableContent))

        await harness.executeCommand(.zoomPane, target: firstSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)
        #expect(window.firstResponder === firstSourceContent)

        await harness.executeCommand(.zoomPane, target: secondSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)
        #expect(window.firstResponder === secondSourceContent)
        #expect(harness.store.tab(tab.id)?.activePaneId == durablePane.id)
    }

    @Test("cross-tab Zoom resume refocuses the retained source")
    func crossTabZoomResumeRefocusesRetainedSource() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let inactivePane = harness.store.createPane()
        let sourcePane = harness.store.createPane()
        let inactiveTab = Tab(paneId: inactivePane.id)
        let sourceTab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(inactiveTab)
        harness.store.appendTab(sourceTab)
        harness.store.setActiveTab(sourceTab.id)
        harness.store.setActivePane(sourcePane.id, inTab: sourceTab.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let inactiveContent = FocusablePaneTabCommandMountedContentView()
        let sourceContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: inactivePane.id, in: harness, to: window, mountedContent: inactiveContent)
        _ = try attachPaneHost(
            paneId: sourcePane.id, in: harness, to: window, mountedContent: sourceContent)
        #expect(window.makeFirstResponder(sourceContent))

        await harness.executeCommand(.zoomPane, target: sourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)
        harness.store.setActiveTab(inactiveTab.id)
        #expect(window.makeFirstResponder(inactiveContent))

        await harness.executeCommand(.zoomPane, target: sourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)

        #expect(harness.store.activeTabId == sourceTab.id)
        #expect(window.firstResponder === sourceContent)
    }

    @Test("Zoom refocus ignores an unrelated durable drawer")
    func explicitSameTabZoomIgnoresUnrelatedDurableDrawer() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let zoomSourcePane = harness.store.createPane()
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                zoomSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)
        let drawerPane = try #require(harness.store.addDrawerPane(to: durablePane.id))
        let drawerId = try #require(harness.store.pane(durablePane.id)?.drawer?.drawerId)
        harness.store.tabArrangementAtom.addDrawerPaneView(
            drawerId: drawerId, parentPaneId: durablePane.id,
            drawerPaneId: drawerPane.id, inTab: tab.id)
        harness.store.setActiveDrawerPane(drawerPane.id, in: durablePane.id)
        atom(\.workspaceFocusOwner).focusDrawerPane(
            parentPaneId: durablePane.id, paneId: drawerPane.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let drawerContent = FocusablePaneTabCommandMountedContentView()
        let zoomSourceContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: drawerPane.id, in: harness, to: window, mountedContent: drawerContent)
        _ = try attachPaneHost(
            paneId: zoomSourcePane.id, in: harness, to: window, mountedContent: zoomSourceContent)
        #expect(window.makeFirstResponder(drawerContent))

        await harness.executeCommand(.zoomPane, target: zoomSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)

        #expect(window.firstResponder === zoomSourceContent)
    }

    @Test("Zoom refocus keeps the source drawer child in focus")
    func explicitSameTabZoomKeepsSourceDrawerFocus() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let zoomSourcePane = harness.store.createPane()
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                zoomSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)
        let sourceDrawerPane = try #require(harness.store.addDrawerPane(to: zoomSourcePane.id))
        let sourceDrawerId = try #require(harness.store.pane(zoomSourcePane.id)?.drawer?.drawerId)
        harness.store.tabArrangementAtom.addDrawerPaneView(
            drawerId: sourceDrawerId, parentPaneId: zoomSourcePane.id,
            drawerPaneId: sourceDrawerPane.id, inTab: tab.id)
        harness.store.setActiveDrawerPane(sourceDrawerPane.id, in: zoomSourcePane.id)
        atom(\.workspaceFocusOwner).focusMainPane(durablePane.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let durableContent = FocusablePaneTabCommandMountedContentView()
        let sourceDrawerContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: durablePane.id, in: harness, to: window, mountedContent: durableContent)
        _ = try attachPaneHost(
            paneId: sourceDrawerPane.id, in: harness, to: window, mountedContent: sourceDrawerContent)
        #expect(window.makeFirstResponder(durableContent))

        await harness.executeCommand(.zoomPane, target: zoomSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)

        #expect(window.firstResponder === sourceDrawerContent)
    }

    @Test("Zoom source drawer with a minimized child clears focus to window content")
    func minimizedSourceDrawerClearsFocusToWindowContent() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let zoomSourcePane = harness.store.createPane()
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                zoomSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)
        let drawerPane = try #require(harness.store.addDrawerPane(to: zoomSourcePane.id))
        let drawerId = try #require(harness.store.pane(zoomSourcePane.id)?.drawer?.drawerId)
        harness.store.tabArrangementAtom.addDrawerPaneView(
            drawerId: drawerId, parentPaneId: zoomSourcePane.id,
            drawerPaneId: drawerPane.id, inTab: tab.id)
        #expect(harness.store.minimizeDrawerPane(drawerPane.id, in: zoomSourcePane.id))
        atom(\.workspaceFocusOwner).focusEmptyDrawer(parentPaneId: zoomSourcePane.id)
        let durableArrangement = try #require(harness.store.tab(tab.id)?.activeArrangement)
        let minimizedBefore = harness.store.drawerView(forParent: zoomSourcePane.id)?.minimizedPaneIds

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let durableContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: durablePane.id, in: harness, to: window, mountedContent: durableContent)
        _ = try attachPaneHost(paneId: zoomSourcePane.id, in: harness, to: window)
        #expect(window.makeFirstResponder(durableContent))

        await harness.executeCommand(.zoomPane, target: zoomSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)

        #expect(window.firstResponder === window.contentView)
        #expect(harness.store.tab(tab.id)?.activePaneId == durablePane.id)
        #expect(harness.store.tab(tab.id)?.activeArrangement == durableArrangement)
        #expect(harness.store.drawerView(forParent: zoomSourcePane.id)?.minimizedPaneIds == minimizedBefore)
    }

    @Test("empty Zoom source drawer clears focus to window content")
    func emptySourceDrawerClearsFocusToWindowContent() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let zoomSourcePane = harness.store.createPane()
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                zoomSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)
        let drawerPane = try #require(harness.store.addDrawerPane(to: zoomSourcePane.id))
        let drawerId = try #require(harness.store.pane(zoomSourcePane.id)?.drawer?.drawerId)
        harness.store.tabArrangementAtom.addDrawerPaneView(
            drawerId: drawerId, parentPaneId: zoomSourcePane.id,
            drawerPaneId: drawerPane.id, inTab: tab.id)
        harness.store.removeDrawerPane(drawerPane.id, from: zoomSourcePane.id)
        atom(\.workspaceFocusOwner).focusEmptyDrawer(parentPaneId: zoomSourcePane.id)
        let durableArrangement = try #require(harness.store.tab(tab.id)?.activeArrangement)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let durableContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: durablePane.id, in: harness, to: window, mountedContent: durableContent)
        _ = try attachPaneHost(paneId: zoomSourcePane.id, in: harness, to: window)
        #expect(window.makeFirstResponder(durableContent))

        await harness.executeCommand(.zoomPane, target: zoomSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)

        #expect(window.firstResponder === window.contentView)
        #expect(harness.store.tab(tab.id)?.activePaneId == durablePane.id)
        #expect(harness.store.tab(tab.id)?.activeArrangement == durableArrangement)
    }

    @Test("canceling same-tab Zoom refocuses the durable active pane")
    func cancelSameTabZoomRefocusesDurableActivePane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let zoomSourcePane = harness.store.createPane()
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                zoomSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let durableContent = FocusablePaneTabCommandMountedContentView()
        let zoomSourceContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: durablePane.id, in: harness, to: window, mountedContent: durableContent)
        _ = try attachPaneHost(
            paneId: zoomSourcePane.id, in: harness, to: window, mountedContent: zoomSourceContent)
        #expect(window.makeFirstResponder(durableContent))

        await harness.executeCommand(.zoomPane, target: zoomSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)
        #expect(window.firstResponder === zoomSourceContent)

        await harness.executeCommand(.zoomPane, target: zoomSourcePane.id, targetType: .pane)
        await refocusAfterZoomLayout(harness, window: window)

        #expect(window.firstResponder === durableContent)
        #expect(harness.store.tab(tab.id)?.activePaneId == durablePane.id)
    }
}

@MainActor
extension PaneTabViewControllerHeadlessZoomCommandTests {
    @Test("headless same-tab Viewer focuses its Zoom source without changing durable state")
    func headlessSameTabViewerFocusesSourceWithoutChangingDurableState() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let durablePane = harness.store.createPane()
        let zoomSourcePane = harness.store.createPane(
            launchDirectory: harness.tempDir.appending(path: "unwatched-same-tab-viewer")
        )
        let tab = Tab(paneId: durablePane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                zoomSourcePane.id, inTab: tab.id, at: durablePane.id,
                direction: .horizontal, position: .after, sizingMode: .halveTarget))
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(durablePane.id, inTab: tab.id)
        let durableArrangement = try #require(harness.store.tab(tab.id)?.activeArrangement)

        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let durableContent = FocusablePaneTabCommandMountedContentView()
        let zoomSourceContent = FocusablePaneTabCommandMountedContentView()
        _ = try attachPaneHost(
            paneId: durablePane.id, in: harness, to: window, mountedContent: durableContent)
        _ = try attachPaneHost(
            paneId: zoomSourcePane.id, in: harness, to: window, mountedContent: zoomSourceContent)
        #expect(window.makeFirstResponder(durableContent))

        let outcome = try await harness.executeHeadlessPaneCommand(.showViewer, paneId: zoomSourcePane.id)

        #expect(outcome == .applied)
        await refocusAfterZoomLayout(harness, window: window)
        #expect(window.firstResponder === zoomSourceContent)
        #expect(harness.store.activeTabId == tab.id)
        #expect(harness.store.tab(tab.id)?.activePaneId == durablePane.id)
        #expect(harness.store.tab(tab.id)?.activeArrangement == durableArrangement)
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?.sourcePaneId
                == zoomSourcePane.id
        )
        #expect(
            harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?.viewerPresentation
                == .unavailableVisible
        )
    }
}

@MainActor
private func refocusAfterZoomLayout(
    _ harness: PaneTabViewControllerCommandHarness,
    window: NSWindow
) async {
    window.contentView?.layoutSubtreeIfNeeded()
    harness.controller.requestPaneRefocus(.explicit)
    _ = await harness.executor.submitGesture { _ in true }.value
}
