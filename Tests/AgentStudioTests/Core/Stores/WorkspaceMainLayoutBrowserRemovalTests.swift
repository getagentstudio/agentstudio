import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

/// R4: a browser saved in the main layout is removed at launch, with
/// anything it owns, as closing that pane does; a tab it was alone in closes.
/// A backgrounded or orphaned browser no tab holds goes too. Unrelated panes,
/// recoverable ones included, and drawer browsers are untouched.
@Suite
struct WorkspaceMainLayoutBrowserRemovalTests {
    private static func makeBrowserPane(
        id: UUID = UUIDv7.generate(), residency: SessionResidency = .active
    ) -> Pane {
        Pane(
            id: id,
            content: .webview(WebviewState(url: URL(string: "https://example.com")!)),
            metadata: PaneMetadata(title: "Browser"),
            residency: residency
        )
    }

    @Test
    func test_browserAloneInTab_closesTheTab() {
        // Arrange
        let terminal = makePane(id: UUIDv7.generate())
        let browser = Self.makeBrowserPane()
        let terminalTab = makeTab(paneIds: [terminal.id])
        let browserTab = makeTab(paneIds: [browser.id])
        let loaded = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(), panes: [terminal, browser], tabs: [terminalTab, browserTab],
            activeTabId: browserTab.id)

        // Act
        let normalized = WorkspaceMainLayoutBrowserRemoval.removingMainLayoutBrowsers(from: loaded)

        // Assert
        #expect(normalized.tabs.map(\.id) == [terminalTab.id])
        #expect(normalized.panes.map(\.id) == [terminal.id])
        #expect(normalized.activeTabId == terminalTab.id)
    }

    @Test
    func test_browserBesideTerminal_leavesTheTerminalTab() {
        // Arrange
        let terminal = makePane(id: UUIDv7.generate())
        let browser = Self.makeBrowserPane()
        let tab = makeTab(paneIds: [terminal.id, browser.id], activePaneId: browser.id)
        let loaded = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(), panes: [terminal, browser], tabs: [tab], activeTabId: tab.id)

        // Act
        let normalized = WorkspaceMainLayoutBrowserRemoval.removingMainLayoutBrowsers(from: loaded)

        // Assert
        #expect(normalized.panes.map(\.id) == [terminal.id])
        let remainingTab = normalized.tabs.first
        #expect(remainingTab?.id == tab.id)
        #expect(remainingTab?.allPaneIds == [terminal.id])
        #expect(remainingTab?.activePaneIds == [terminal.id])
        #expect(remainingTab?.activePaneId == terminal.id)
    }

    @Test
    func test_browserOwningTerminalDrawer_removesBrowserAndItsDrawerChild() throws {
        // Arrange: the main-layout browser owns a drawer holding a terminal.
        let terminal = makePane(id: UUIDv7.generate())
        var browser = Self.makeBrowserPane()
        var drawerTerminal = makePane(id: UUIDv7.generate())
        drawerTerminal.kind = .drawerChild(parentPaneId: browser.id)
        browser.withDrawer { $0.paneIds = [drawerTerminal.id] }
        let drawerId = try #require(browser.drawer?.drawerId)
        var tab = makeTab(paneIds: [terminal.id, browser.id], activePaneId: terminal.id)
        tab.arrangements[0].drawerViews[drawerId] = DrawerView(
            layout: DrawerGridLayout(topRow: Layout(paneId: drawerTerminal.id)), activeChildId: drawerTerminal.id
        )
        let loaded = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(), panes: [terminal, browser, drawerTerminal], tabs: [tab], activeTabId: tab.id)

        // Act
        let normalized = WorkspaceMainLayoutBrowserRemoval.removingMainLayoutBrowsers(from: loaded)

        // Assert
        #expect(normalized.panes.map(\.id) == [terminal.id])
        #expect(normalized.tabs.first?.allPaneIds == [terminal.id])
        #expect(normalized.tabs.first?.arrangements.allSatisfy { $0.drawerViews[drawerId] == nil } == true)
    }

    @Test
    func test_drawerBrowser_andWorkspaceWithoutMainBrowsers_areUnchanged() {
        // Arrange: a terminal whose drawer holds a browser.
        var terminal = makePane(id: UUIDv7.generate())
        var drawerBrowser = Self.makeBrowserPane()
        drawerBrowser.kind = .drawerChild(parentPaneId: terminal.id)
        terminal.withDrawer { $0.paneIds = [drawerBrowser.id] }
        let tab = makeTab(paneIds: [terminal.id])
        let loaded = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(), panes: [terminal, drawerBrowser], tabs: [tab], activeTabId: tab.id)

        // Act
        let normalized = WorkspaceMainLayoutBrowserRemoval.removingMainLayoutBrowsers(from: loaded)

        // Assert
        #expect(normalized == loaded)
    }

    @Test
    func test_unownedBrowsers_removedWithTheirDrawers_otherRecoverablePanesKept() {
        // Arrange: a backgrounded browser owning a terminal drawer and an
        // orphaned browser, neither in a tab, beside a backgrounded terminal and
        // an orphaned code viewer that are just as unowned.
        let orphaned = SessionResidency.orphaned(reason: .worktreeNotFound(path: "/tmp/removal-orphaned"))
        let terminal = makePane(id: UUIDv7.generate())
        var backgroundedBrowser = Self.makeBrowserPane(residency: .backgrounded)
        var drawerTerminal = makePane(id: UUIDv7.generate(), residency: .backgrounded)
        drawerTerminal.kind = .drawerChild(parentPaneId: backgroundedBrowser.id)
        backgroundedBrowser.withDrawer { $0.paneIds = [drawerTerminal.id] }
        let orphanedBrowser = Self.makeBrowserPane(residency: orphaned)
        let backgroundedTerminal = makePane(id: UUIDv7.generate(), residency: .backgrounded)
        let orphanedCodeViewer = Pane(
            id: UUIDv7.generate(),
            content: .codeViewer(CodeViewerState(filePath: URL(filePath: "/tmp/removal-kept.swift"), scrollToLine: 1)),
            metadata: PaneMetadata(title: "Code"),
            residency: orphaned
        )
        let tab = makeTab(paneIds: [terminal.id])
        let loaded = WorkspaceSQLiteSnapshot(
            id: UUIDv7.generate(),
            panes: [
                terminal, backgroundedBrowser, drawerTerminal, orphanedBrowser, backgroundedTerminal,
                orphanedCodeViewer,
            ],
            tabs: [tab], activeTabId: tab.id)

        // Act
        let normalized = WorkspaceMainLayoutBrowserRemoval.removingMainLayoutBrowsers(from: loaded)

        // Assert
        #expect(normalized.panes.map(\.id) == [terminal.id, backgroundedTerminal.id, orphanedCodeViewer.id])
        #expect(normalized.tabs == loaded.tabs)
        #expect(normalized.activeTabId == tab.id)
    }
}
