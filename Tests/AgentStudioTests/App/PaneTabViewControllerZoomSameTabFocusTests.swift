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
