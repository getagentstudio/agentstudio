import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

/// R11 and migration 019: browser tabs survive restarts, and an upgrade
/// turns each saved one-row browser into a browser with one webview.
@MainActor
@Suite("Workspace browser webview persistence", .serialized)
struct WorkspaceBrowserWebviewPersistenceTests {
    private static func url(_ string: String) -> URL { URL(string: string)! }

    private func appendTerminalTab(to store: WorkspaceStore) -> Pane {
        let pane = makePane(id: UUIDv7.generate(), launchDirectory: FileManager.default.temporaryDirectory)
        store.paneAtom.addPane(pane)
        store.appendTab(Tab(paneId: pane.id))
        return pane
    }

    /// Adds a browser to `parent`'s drawer the way the app does: pane graph
    /// membership plus the drawer view in the parent's tab.
    private func addDrawerBrowser(_ state: WebviewState, to parent: Pane, in store: WorkspaceStore) throws -> Pane {
        let browser = try #require(
            store.paneAtom.addDrawerPane(
                to: parent.id, content: .webview(state), metadata: PaneMetadata(title: "Browser"),
                expandsDrawer: false)
        )
        let tabId = try #require(store.tabLayoutAtom.tabContaining(paneId: parent.id)?.id)
        let drawerId = try #require(store.paneAtom.pane(parent.id)?.drawer?.drawerId)
        store.tabArrangementAtom.addNewDrawerPaneView(
            drawerId: drawerId, parentPaneId: parent.id, drawerPaneId: browser.id, inTab: tabId,
            selectsInsertedChild: false)
        return browser
    }

    private func webviewState(of paneId: UUID, in store: WorkspaceStore) -> WebviewState? {
        guard case .webview(let state) = store.paneAtom.pane(paneId)?.content else { return nil }
        return state
    }

    @Test("an upgraded database keeps a drawer browser as one tab and drops a main-layout browser")
    func legacyBrowserRowsUpgradeToBrowserWebviews() async throws {
        // Arrange: the app writes a terminal with a drawer browser, and a
        // browser alone in its own tab, as an old build would have saved.
        let databases = try DrawerPresentationDatabases()
        defer { databases.remove() }
        let store = try await databases.bootStore()
        let terminal = appendTerminalTab(to: store)
        let drawerBrowser = try addDrawerBrowser(
            WebviewState(url: Self.url("https://example.com/drawer"), title: "Drawer page", showNavigation: false),
            to: terminal, in: store)
        let mainBrowser = Pane(
            content: .webview(WebviewState(url: Self.url("https://example.com/main"), title: "Main page")),
            metadata: PaneMetadata(title: "Main browser"))
        store.paneAtom.addPane(mainBrowser)
        store.appendTab(Tab(paneId: mainBrowser.id))
        #expect(await store.flushAsync() == .persisted)
        try LegacyBrowserDatabaseFixture.rewriteBrowserTablesToLegacySchema(at: databases.coreDatabaseURL)

        // Act: the next boot runs migration 019, then loads.
        let upgraded = try await databases.bootStore()

        // Assert: the drawer browser is a browser with one webview reusing its
        // pane id; the main-layout browser and its tab are gone at load.
        let state = try #require(webviewState(of: drawerBrowser.id, in: upgraded))
        #expect(
            state.tabs == [
                WebviewTabSnapshot(
                    id: drawerBrowser.id, url: Self.url("https://example.com/drawer"), title: "Drawer page")
            ])
        #expect(state.activeTabId == drawerBrowser.id)
        #expect(!state.showNavigation)
        #expect(upgraded.paneAtom.pane(mainBrowser.id) == nil)
        #expect(upgraded.tabLayoutAtom.tabContaining(paneId: mainBrowser.id) == nil)
        #expect(upgraded.paneAtom.pane(terminal.id)?.drawer?.paneIds == [drawerBrowser.id])
        let leftovers = try Self.readCore(databases.coreDatabaseURL) { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE name = 'pane_content_webview_old' OR (type = 'trigger' AND tbl_name LIKE 'pane_content_%webview%')
                    """)
        }
        #expect(leftovers.isEmpty, "legacy table or triggers left behind: \(leftovers)")
    }

    @Test("tabs, their order and the active tab survive two changed saves and a reload")
    func browserTabsRoundTripThroughChangedSaves() async throws {
        // Arrange: a drawer browser with three tabs, the second active.
        let databases = try DrawerPresentationDatabases()
        defer { databases.remove() }
        let store = try await databases.bootStore()
        let terminal = appendTerminalTab(to: store)
        let tabA = WebviewTabSnapshot(id: UUIDv7.generate(), url: Self.url("https://a.test/"), title: "A")
        let tabB = WebviewTabSnapshot(id: UUIDv7.generate(), url: Self.url("https://b.test/"), title: "B")
        let tabC = WebviewTabSnapshot(id: UUIDv7.generate(), url: Self.url("https://c.test/"), title: "C")
        let threeTabs = try #require(
            WebviewState(tabs: [tabA, tabB, tabC], activeTabId: tabB.id, showNavigation: true))
        let browser = try addDrawerBrowser(threeTabs, to: terminal, in: store)
        #expect(await store.flushAsync() == .persisted)
        let reloaded = try await databases.bootStore()
        #expect(webviewState(of: browser.id, in: reloaded) == threeTabs)

        // Act: save 1 closes the active tab (C becomes active); save 2 makes A active.
        let closed = try #require(WebviewState(tabs: [tabA, tabC], activeTabId: tabC.id, showNavigation: true))
        reloaded.paneAtom.syncPaneWebviewState(browser.id, state: closed)
        #expect(await reloaded.flushAsync() == .persisted)
        let reselected = try #require(WebviewState(tabs: [tabA, tabC], activeTabId: tabA.id, showNavigation: true))
        reloaded.paneAtom.syncPaneWebviewState(browser.id, state: reselected)
        #expect(await reloaded.flushAsync() == .persisted)
        let final = try await databases.bootStore()

        // Assert
        #expect(webviewState(of: browser.id, in: final) == reselected)
        let positions = try Self.readCore(databases.coreDatabaseURL) { database in
            try Row.fetchAll(
                database,
                sql: "SELECT id, position FROM pane_content_webview WHERE browser_pane_id = ? ORDER BY position",
                arguments: [browser.id.uuidString]
            ).map { "\($0["id"] as String):\($0["position"] as Int)" }
        }
        #expect(positions == ["\(tabA.id.uuidString):0", "\(tabC.id.uuidString):1"])
    }

    @Test("removing a pane, an owning pane and the last pane leaves no browser rows")
    func paneRemovalClearsBrowserRows() async throws {
        // Arrange: three terminals, each with a drawer browser.
        let databases = try DrawerPresentationDatabases()
        defer { databases.remove() }
        let store = try await databases.bootStore()
        var families: [(terminal: Pane, browser: Pane)] = []
        for index in 0..<3 {
            let terminal = appendTerminalTab(to: store)
            let browser = try addDrawerBrowser(
                WebviewState(url: Self.url("https://example.com/\(index)")), to: terminal, in: store)
            families.append((terminal, browser))
        }
        let flush1 = await store.flushAsync()
        #expect(flush1 == .persisted, "flush: \(flush1)")
        for family in families { #expect(try browserRowCount(family.browser.id, databases) == 2) }

        // Act + Assert 1: removing the drawer browser itself, as closing a drawer child does.
        store.paneAtom.removeDrawerPane(families[0].browser.id, from: families[0].terminal.id)
        store.tabArrangementAtom.removePaneReferences([families[0].browser.id])
        let flush2 = await store.flushAsync()
        #expect(flush2 == .persisted, "flush: \(flush2)")
        #expect(try browserRowCount(families[0].browser.id, databases) == 0)
        #expect(try browserRowCount(families[1].browser.id, databases) == 2)

        // Act + Assert 2: removing the pane that owns a drawer browser.
        #expect(store.mutationCoordinator.removePane(families[1].terminal.id))
        let flush3 = await store.flushAsync()
        #expect(flush3 == .persisted, "flush: \(flush3)")
        #expect(try browserRowCount(families[1].browser.id, databases) == 0)
        #expect(try browserRowCount(families[2].browser.id, databases) == 2)

        // Act + Assert 3: removing every remaining pane saves an empty pane set.
        #expect(store.mutationCoordinator.removePane(families[2].terminal.id))
        let flush4 = await store.flushAsync()
        #expect(flush4 == .persisted, "flush: \(flush4)")
        #expect(try browserRowCount(families[2].browser.id, databases) == 0)
        #expect(try totalBrowserRows(databases) == 0)
    }

    @Test("deleting a workspace clears its browser rows and keeps another workspace's")
    func workspaceDeletionClearsOnlyItsBrowserRows() async throws {
        // Arrange: a saved workspace with a drawer browser, and a copy of that
        // browser in a second workspace.
        let databases = try DrawerPresentationDatabases()
        defer { databases.remove() }
        let store = try await databases.bootStore()
        let terminal = appendTerminalTab(to: store)
        let browser = try addDrawerBrowser(
            WebviewState(url: Self.url("https://example.com/kept")), to: terminal, in: store)
        #expect(await store.flushAsync() == .persisted)
        let workspaceId = store.identityAtom.workspaceId
        let otherWorkspaceId = UUIDv7.generate()
        let otherTerminalId = UUIDv7.generate()
        let otherBrowserId = UUIDv7.generate()
        try Self.writeCore(databases.coreDatabaseURL) { database in
            try Self.copyRow(database, table: "workspace", key: "id", from: workspaceId, to: otherWorkspaceId)
            try Self.copyRow(
                database, table: "pane", key: "id", from: terminal.id, to: otherTerminalId,
                overrides: ["workspace_id": otherWorkspaceId.uuidString])
            try Self.copyRow(
                database, table: "pane", key: "id", from: browser.id, to: otherBrowserId,
                overrides: ["workspace_id": otherWorkspaceId.uuidString, "parent_pane_id": otherTerminalId.uuidString])
            try database.execute(
                sql: """
                    INSERT INTO pane_content_browser(pane_id, active_webview_id, show_navigation)
                    VALUES (?, ?, 1)
                    """,
                arguments: [otherBrowserId.uuidString, otherBrowserId.uuidString])
            try database.execute(
                sql: """
                    INSERT INTO pane_content_webview(id, browser_pane_id, position, url, title)
                    VALUES (?, ?, 0, 'https://example.com/other', 'Other')
                    """,
                arguments: [otherBrowserId.uuidString, otherBrowserId.uuidString])
        }

        // Act
        let queue = try DatabaseQueue(path: databases.coreDatabaseURL.path)
        _ = try WorkspaceCoreRepository(databaseWriter: queue).deleteWorkspace(workspaceId, updatedAt: Date())

        // Assert
        #expect(try browserRowCount(browser.id, databases) == 0)
        #expect(try browserRowCount(otherBrowserId, databases) == 2)
    }

    private func browserRowCount(_ paneId: UUID, _ databases: DrawerPresentationDatabases) throws -> Int {
        try Self.readCore(databases.coreDatabaseURL) { database in
            let browsers =
                try Int.fetchOne(
                    database, sql: "SELECT count(*) FROM pane_content_browser WHERE pane_id = ?",
                    arguments: [paneId.uuidString]) ?? 0
            let webviews =
                try Int.fetchOne(
                    database, sql: "SELECT count(*) FROM pane_content_webview WHERE browser_pane_id = ?",
                    arguments: [paneId.uuidString]) ?? 0
            return browsers + webviews
        }
    }

    private func totalBrowserRows(_ databases: DrawerPresentationDatabases) throws -> Int {
        try Self.readCore(databases.coreDatabaseURL) { database in
            (try Int.fetchOne(database, sql: "SELECT count(*) FROM pane_content_browser") ?? 0)
                + (try Int.fetchOne(database, sql: "SELECT count(*) FROM pane_content_webview") ?? 0)
        }
    }

    private nonisolated static func readCore<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        try DatabaseQueue(path: url.path).read(body)
    }

    private nonisolated static func writeCore(_ url: URL, _ body: (Database) throws -> Void) throws {
        try DatabaseQueue(path: url.path).write(body)
    }

    /// Duplicates one row under a new key, every other column copied as stored.
    private nonisolated static func copyRow(
        _ database: Database, table: String, key: String, from source: UUID, to target: UUID,
        overrides: [String: String] = [:]
    ) throws {
        let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        let selected = columns.map { column -> String in
            if column == key { return "?" }
            if overrides[column] != nil { return "?" }
            return column
        }
        var arguments: [String] = []
        for column in columns where column == key || overrides[column] != nil {
            arguments.append(column == key ? target.uuidString : overrides[column]!)
        }
        arguments.append(source.uuidString)
        try database.execute(
            sql: """
                INSERT INTO \(table)(\(columns.joined(separator: ", ")))
                SELECT \(selected.joined(separator: ", ")) FROM \(table) WHERE \(key) = ?
                """,
            arguments: StatementArguments(arguments))
    }

}
