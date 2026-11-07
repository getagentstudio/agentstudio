import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

/// R4: a browser saved in the main layout is removed at launch, with
/// anything it owns, as closing that pane does; a tab it was alone in closes.
/// Unrelated panes and drawer browsers are untouched.
@Suite
struct WorkspaceMainLayoutBrowserRemovalTests {
    private static func makeBrowserPane(id: UUID = UUIDv7.generate()) -> Pane {
        Pane(
            id: id,
            content: .webview(WebviewState(url: URL(string: "https://example.com")!)),
            metadata: PaneMetadata(title: "Browser")
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
}
