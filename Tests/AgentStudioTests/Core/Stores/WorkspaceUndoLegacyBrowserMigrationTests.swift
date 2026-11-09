import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore

/// R32: an undo close saved before migration 020 holding a browser expires when
/// the database upgrades, launch recovery succeeds, closes holding no browser
/// stay available, and the expired closes' sessions are cleaned up.
@MainActor
@Suite("Workspace undo journal across migration 020", .serialized)
struct WorkspaceUndoLegacyBrowserMigrationTests {
    init() { installTestCoreAtomsIfNeeded() }

    /// The text the migration matches. A title holding it is stored escaped.
    private static let browserMarker = #""type":"webview""#

    private struct ClosedFixture {
        let browserTabClose: UUID
        let browserPaneClose: UUID
        let plainClose: UUID
        let lookalikeClose: UUID
        let browserTabTerminalSession: ZmxSessionID
        let plainSession: ZmxSessionID
        let lookalikeSession: ZmxSessionID
        let closedBrowserPaneId: UUID
        let closedTerminalPaneId: UUID
    }

    @Test("020 expires available undo closes holding a browser and launch recovery succeeds")
    func migrationExpiresLegacyBrowserUndoCloses() async throws {
        // Arrange: four closes through the app's real close path, then the
        // database put back in the shape builds before 020 wrote.
        let databases = try DrawerPresentationDatabases()
        defer { databases.remove() }
        let store = try await databases.bootStore()
        let closed = try await Self.closeFourTabsAndPanes(in: store)
        let lookalikePayload = try #require(try Self.payload(of: closed.lookalikeClose, at: databases.coreDatabaseURL))
        try #require(
            !lookalikePayload.contains(Self.browserMarker) && lookalikePayload.contains("webview"),
            "the lookalike title must be stored, escaped")
        let markers = try LegacyBrowserDatabaseFixture.rewriteUndoBrowserStatesToLegacyShape(
            at: databases.coreDatabaseURL)
        try #require(markers == 2, "two closes hold one browser each")
        // The local tables the closed panes' leftovers live in are the
        // optional schema the app prepares at launch.
        try #require(await Self.prepareOptionalLocalSchema(databases) == true)
        try Self.seedLeftovers(for: closed, at: databases.localDatabaseURL)
        try LegacyBrowserDatabaseFixture.rewriteBrowserTablesToLegacySchema(at: databases.coreDatabaseURL)

        // Act: the next launch runs 020, then recovers the journal.
        let relaunched = try await databases.bootStore()
        let recovery = try await relaunched.recoverUndoJournal(time: try await WorkspaceUndoJournalClock.current())
        let optionalSchemaReady = await Self.prepareOptionalLocalSchema(databases)

        // Assert: the browser closes expired without a payload; the others
        // stay available and are what recovery offers.
        let states = try Self.undoStates(at: databases.coreDatabaseURL)
        #expect(states[closed.browserTabClose] == .init(state: "expired", hasPayload: false))
        #expect(states[closed.browserPaneClose] == .init(state: "expired", hasPayload: false))
        #expect(states[closed.plainClose] == .init(state: "available", hasPayload: true))
        #expect(states[closed.lookalikeClose] == .init(state: "available", hasPayload: true))
        #expect(Set(recovery.availableCloses.map(\.closeID)) == [closed.plainClose, closed.lookalikeClose])
        // The expired tab close's terminal session is released for cleanup;
        // sessions still held by available closes are not.
        #expect(recovery.pendingSessionIDs.contains(closed.browserTabTerminalSession))
        #expect(!recovery.pendingSessionIDs.contains(closed.plainSession))
        #expect(!recovery.pendingSessionIDs.contains(closed.lookalikeSession))
        // The closed panes' leftover local rows stayed, and neither recovery
        // nor the optional local schema preparation tripped on them.
        #expect(optionalSchemaReady)
        #expect(try Self.leftoverRowCount(for: closed, at: databases.localDatabaseURL) == 2)
    }

    @Test("with no available undo close left after 020, launch still releases the expired close's session")
    func migrationExpiryReleasesSessionWithNoAvailableCloseLeft() async throws {
        // Arrange: the only undo close holds a browser.
        let databases = try DrawerPresentationDatabases()
        defer { databases.remove() }
        let store = try await databases.bootStore()
        let keeper = makePane(id: UUIDv7.generate(), launchDirectory: FileManager.default.temporaryDirectory)
        store.paneAtom.addPane(keeper)
        store.appendTab(Tab(paneId: keeper.id))
        let (tab, terminal, _) = try Self.appendTerminalWithBrowser(to: store)
        #expect(await store.flushAsync() == .persisted)
        store.setActiveTab(tab.id)
        let closeID = UUIDv7.generate()
        _ = try await store.closeForUndo(
            tabID: tab.id, paneID: terminal.id, closeID: closeID, time: try await WorkspaceUndoJournalClock.current(),
            willPublish: { _, _ in }, didPublish: { _, _ in })
        try #require(
            try LegacyBrowserDatabaseFixture.rewriteUndoBrowserStatesToLegacyShape(at: databases.coreDatabaseURL) == 1)
        try LegacyBrowserDatabaseFixture.rewriteBrowserTablesToLegacySchema(at: databases.coreDatabaseURL)

        // Act
        let relaunched = try await databases.bootStore()
        let recovery = try await relaunched.recoverUndoJournal(time: try await WorkspaceUndoJournalClock.current())

        // Assert: nothing is left to undo, the close expired, and its
        // terminal's session is released for cleanup all the same.
        #expect(recovery.availableCloses.isEmpty)
        #expect(
            try Self.undoStates(at: databases.coreDatabaseURL)[closeID] == .init(state: "expired", hasPayload: false))
        #expect(recovery.pendingSessionIDs.contains(try Self.session(of: terminal)))
        #expect(!recovery.pendingSessionIDs.contains(try Self.session(of: keeper)))
    }

    // MARK: - Arrange

    /// Closes, in order: a tab whose terminal holds a drawer browser, a drawer
    /// browser alone, a plain terminal tab, and a terminal tab whose title is
    /// the migration's marker text.
    private static func closeFourTabsAndPanes(in store: WorkspaceStore) async throws -> ClosedFixture {
        let keeper = makePane(id: UUIDv7.generate(), launchDirectory: FileManager.default.temporaryDirectory)
        store.paneAtom.addPane(keeper)
        store.appendTab(Tab(paneId: keeper.id))
        let (browserTab, browserTabTerminal, _) = try appendTerminalWithBrowser(to: store)
        let (paneCloseTab, _, browserForPaneClose) = try appendTerminalWithBrowser(to: store)
        let (plainTab, plainTerminal) = appendTerminal(titled: "Plain", to: store)
        let (lookalikeTab, lookalikeTerminal) = appendTerminal(titled: browserMarker, to: store)
        #expect(await store.flushAsync() == .persisted)

        func close(tab: Tab, pane: UUID) async throws -> UUID {
            let closeID = UUIDv7.generate()
            // Only a foreground close offers Undo, so the closing tab is active.
            store.setActiveTab(tab.id)
            _ = try await store.closeForUndo(
                tabID: tab.id, paneID: pane, closeID: closeID, time: try await WorkspaceUndoJournalClock.current(),
                willPublish: { _, _ in }, didPublish: { _, _ in })
            return closeID
        }
        return ClosedFixture(
            browserTabClose: try await close(tab: browserTab, pane: browserTabTerminal.id),
            browserPaneClose: try await close(tab: paneCloseTab, pane: browserForPaneClose.id),
            plainClose: try await close(tab: plainTab, pane: plainTerminal.id),
            lookalikeClose: try await close(tab: lookalikeTab, pane: lookalikeTerminal.id),
            browserTabTerminalSession: try session(of: browserTabTerminal),
            plainSession: try session(of: plainTerminal),
            lookalikeSession: try session(of: lookalikeTerminal),
            closedBrowserPaneId: browserForPaneClose.id,
            closedTerminalPaneId: browserTabTerminal.id)
    }

    private static func prepareOptionalLocalSchema(_ databases: DrawerPresentationDatabases) async -> Bool {
        let datastore = databases.makeDatastore(legacySource: nil)
        guard case .prepared = await datastore.prepareDatabasesForBoot() else { return false }
        guard case .ready = await datastore.prepareOptionalApplicationLocalSchema() else { return false }
        return true
    }

    private static func appendTerminal(titled title: String, to store: WorkspaceStore) -> (Tab, Pane) {
        let terminal = makePane(
            id: UUIDv7.generate(), launchDirectory: FileManager.default.temporaryDirectory, title: title)
        store.paneAtom.addPane(terminal)
        let tab = Tab(paneId: terminal.id)
        store.appendTab(tab)
        return (tab, terminal)
    }

    private static func appendTerminalWithBrowser(to store: WorkspaceStore) throws -> (Tab, Pane, Pane) {
        let (tab, terminal) = appendTerminal(titled: "Terminal", to: store)
        let browser = try #require(
            store.paneAtom.addDrawerPane(
                to: terminal.id, content: .webview(WebviewState(url: URL(string: "https://example.com/legacy")!)),
                metadata: PaneMetadata(title: "Browser"), expandsDrawer: false))
        let drawerId = try #require(store.paneAtom.pane(terminal.id)?.drawer?.drawerId)
        store.tabArrangementAtom.addNewDrawerPaneView(
            drawerId: drawerId, parentPaneId: terminal.id, drawerPaneId: browser.id, inTab: tab.id,
            selectsInsertedChild: false)
        return (tab, terminal, browser)
    }

    private static func session(of pane: Pane) throws -> ZmxSessionID {
        guard case .terminal(let state) = pane.content else { throw LegacyMigrationFixtureFailure.notATerminal }
        return state.zmxSessionID
    }

    /// Local rows a closed pane can leave behind: its agent title and its
    /// terminal's foreground evidence. Nothing retires them for these closes.
    private nonisolated static func seedLeftovers(for closed: ClosedFixture, at url: URL) throws {
        try DatabaseQueue(path: url.path).write { database in
            try database.execute(
                sql: "INSERT INTO pane_state(id, kind, pane_id, title) VALUES (?, 'agentTitle', ?, 'Old browser')",
                arguments: [UUIDv7.generate().uuidString, closed.closedBrowserPaneId.uuidString])
            try database.execute(
                sql: """
                    INSERT INTO terminal_pane_foreground_evidence(
                        pane_id, evidence_kind, observer_launch_id, sequence, observed_at)
                    VALUES (?, 'unreadable', ?, 1, '2026-11-01T00:00:00Z')
                    """,
                arguments: [closed.closedTerminalPaneId.uuidString, UUIDv7.generate().uuidString])
        }
    }

    // MARK: - Reading the databases

    private struct UndoState: Equatable {
        let state: String
        let hasPayload: Bool
    }

    private nonisolated static func undoStates(at url: URL) throws -> [UUID: UndoState] {
        try DatabaseQueue(path: url.path).read { database in
            var states: [UUID: UndoState] = [:]
            for row in try Row.fetchAll(
                database,
                sql: "SELECT close_id, state, snapshot_payload IS NOT NULL AS has_payload FROM workspace_undo_close")
            {
                guard let closeID = UUID(uuidString: row["close_id"]) else { continue }
                states[closeID] = UndoState(state: row["state"], hasPayload: row["has_payload"])
            }
            return states
        }
    }

    private nonisolated static func payload(of closeID: UUID, at url: URL) throws -> String? {
        try DatabaseQueue(path: url.path).read { database in
            try Data.fetchOne(
                database, sql: "SELECT snapshot_payload FROM workspace_undo_close WHERE close_id = ?",
                arguments: [closeID.uuidString]
            ).flatMap { String(bytes: $0, encoding: .utf8) }
        }
    }

    private nonisolated static func leftoverRowCount(for closed: ClosedFixture, at url: URL) throws -> Int {
        try DatabaseQueue(path: url.path).read { database in
            let titles =
                try Int.fetchOne(
                    database, sql: "SELECT count(*) FROM pane_state WHERE pane_id = ?",
                    arguments: [closed.closedBrowserPaneId.uuidString]) ?? 0
            let evidence =
                try Int.fetchOne(
                    database, sql: "SELECT count(*) FROM terminal_pane_foreground_evidence WHERE pane_id = ?",
                    arguments: [closed.closedTerminalPaneId.uuidString]) ?? 0
            return titles + evidence
        }
    }
}

private enum LegacyMigrationFixtureFailure: Error {
    case notATerminal
}
