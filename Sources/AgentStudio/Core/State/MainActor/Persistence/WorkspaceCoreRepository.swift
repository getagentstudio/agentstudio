import Foundation
import GRDB

package struct WorkspaceCoreRepository: Sendable {
    struct WorkspaceRecord: Equatable, Sendable {
        let id: UUID
        var name: String
        let createdAt: Date
        let updatedAt: Date
    }

    struct AuthoritativeSnapshot: Equatable, Sendable {
        var workspace: WorkspaceRecord
        var topology: RepositoryTopologyRecord
        var paneGraph: PaneGraphRecord
        var tabShells: [TabShellRecord]
        var tabGraph: TabGraphRecord
    }

    enum AuthoritativeSnapshotRead: Equatable, Sendable {
        case noWorkspaces
        case missingActiveSelection
        case loaded(AuthoritativeSnapshot)
    }

    private struct WorkspaceSnapshotReplacement {
        var workspace: WorkspaceRecord
        var paneGraph: PaneGraphRecord
        var tabShells: [TabShellRecord]
        var tabGraph: TabGraphRecord
        var updatesActiveSelection: Bool
        var undoChange: WorkspaceUndoJournalChange?
    }

    let databaseWriter: any DatabaseWriter

    package init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    package func migrate() throws {
        try WorkspaceCoreMigrations.migrate(databaseWriter)
    }

    func upsertWorkspace(_ record: WorkspaceRecord) throws {
        try databaseWriter.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workspace(id, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    record.id.uuidString,
                    record.name,
                    record.createdAt.timeIntervalSince1970,
                    record.updatedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    func fetchWorkspace(id: UUID) throws -> WorkspaceRecord? {
        try databaseWriter.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, name, created_at, updated_at
                        FROM workspace
                        WHERE id = ?
                        """,
                    arguments: [id.uuidString]
                )
            else {
                return nil
            }
            return try decodeWorkspaceRecord(row)
        }
    }

    func fetchWorkspaces() throws -> [WorkspaceRecord] {
        try databaseWriter.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, name, created_at, updated_at
                    FROM workspace
                    ORDER BY updated_at DESC, id ASC
                    """
            )
            return try rows.map(decodeWorkspaceRecord)
        }
    }

    func renameWorkspace(_ workspaceId: UUID, name: String, updatedAt: Date) throws {
        try databaseWriter.write { database in
            try requireWorkspaceExists(database, id: workspaceId)
            try database.execute(
                sql: """
                    UPDATE workspace
                    SET name = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    name,
                    updatedAt.timeIntervalSince1970,
                    workspaceId.uuidString,
                ]
            )
        }
    }

    func selectActiveWorkspace(_ workspaceId: UUID, updatedAt: Date) throws {
        try databaseWriter.write { database in
            try requireWorkspaceExists(database, id: workspaceId)
            try updateActiveWorkspaceSelection(
                database,
                workspaceId: workspaceId.uuidString,
                updatedAt: updatedAt
            )
        }
    }

    func fetchActiveWorkspaceId() throws -> UUID? {
        try databaseWriter.read { database in
            try fetchActiveWorkspaceIdFromDatabase(database)
        }
    }

    func fetchAuthoritativeSnapshot() throws -> AuthoritativeSnapshotRead {
        try databaseWriter.read { database in
            guard try workspaceCount(database) > 0 else {
                return .noWorkspaces
            }
            guard let activeWorkspaceId = try fetchActiveWorkspaceIdFromDatabase(database) else {
                return .missingActiveSelection
            }
            guard
                let workspaceRow = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, name, created_at, updated_at
                        FROM workspace
                        WHERE id = ?
                        """,
                    arguments: [activeWorkspaceId.uuidString]
                )
            else {
                throw WorkspaceCoreRepositoryError.activeWorkspaceSelectionDangling(activeWorkspaceId)
            }
            return .loaded(
                .init(
                    workspace: try decodeWorkspaceRecord(workspaceRow),
                    topology: try readRepositoryTopology(database),
                    paneGraph: try readPaneGraph(database, workspaceId: activeWorkspaceId),
                    tabShells: try readTabShells(database, workspaceId: activeWorkspaceId),
                    tabGraph: try readTabGraph(database, workspaceId: activeWorkspaceId)
                )
            )
        }
    }

    @discardableResult
    func replaceWorkspaceSnapshot(
        workspace: WorkspaceRecord,
        paneGraph: PaneGraphRecord,
        tabShells: [TabShellRecord],
        tabGraph: TabGraphRecord,
        updatesActiveSelection: Bool = true,
        undoChange: WorkspaceUndoJournalChange? = nil
    ) throws -> WorkspaceUndoJournalReceipt? {
        try replaceWorkspaceSnapshot(
            .init(
                workspace: workspace,
                paneGraph: paneGraph,
                tabShells: tabShells,
                tabGraph: tabGraph,
                updatesActiveSelection: updatesActiveSelection,
                undoChange: undoChange
            )
        )
    }

    private func replaceWorkspaceSnapshot(_ replacement: WorkspaceSnapshotReplacement) throws
        -> WorkspaceUndoJournalReceipt?
    {
        try databaseWriter.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workspace(id, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    replacement.workspace.id.uuidString,
                    replacement.workspace.name,
                    replacement.workspace.createdAt.timeIntervalSince1970,
                    replacement.workspace.updatedAt.timeIntervalSince1970,
                ]
            )
            if replacement.updatesActiveSelection {
                try updateActiveWorkspaceSelection(
                    database,
                    workspaceId: replacement.workspace.id.uuidString,
                    updatedAt: replacement.workspace.updatedAt
                )
            }
            try validatePaneGraph(database, workspaceId: replacement.workspace.id, graph: replacement.paneGraph)
            if case .restore(let closeID, let time) = replacement.undoChange {
                // Validate and consume the undo owner before admitting its proposed live rows.
                // The encompassing transaction rolls this back if any subsequent write fails.
                try restoreUndoClose(
                    closeID: closeID,
                    workspaceID: replacement.workspace.id,
                    time: time,
                    paneGraph: replacement.paneGraph,
                    database: database
                )
            }
            try replacePaneGraphRows(database, workspaceId: replacement.workspace.id, graph: replacement.paneGraph)
            if case .create(let sessionID) = replacement.undoChange {
                // Only the newly minted terminal gets this write. Import, Undo and ordinary snapshots preserve NULL.
                try database.execute(
                    sql: """
                        UPDATE workspace_terminal_session_ownership SET zmx_protocol_version = ?
                        WHERE session_id = ? AND cleanup_state = 'owned'
                        """, arguments: [ZmxProtocol.version, sessionID.rawValue])
                guard try Int.fetchOne(database, sql: "SELECT changes()") == 1 else {
                    throw ZmxSessionControlFailure.invalidIdentity
                }
            }
            try validateTabShells(database, workspaceId: replacement.workspace.id, shells: replacement.tabShells)
            try replaceTabShellRows(database, workspaceId: replacement.workspace.id, shells: replacement.tabShells)
            try validateTabGraph(database, workspaceId: replacement.workspace.id, graph: replacement.tabGraph)
            try replaceTabGraphRows(database, workspaceId: replacement.workspace.id, graph: replacement.tabGraph)
            switch replacement.undoChange {
            case .some(.record(let undoClose)):
                guard undoClose.workspaceID == replacement.workspace.id else {
                    throw WorkspaceUndoCloseWriteFailure.workspaceMismatch
                }
                return try writeUndoClose(undoClose, in: database)
            case .some(.restore), .some(.create):
                try pruneFinishedUndoRows(workspaceID: replacement.workspace.id, database: database)
                return try readUndoJournalReceipt(
                    workspaceID: replacement.workspace.id, retiredCloses: [], database: database)
            case .some(.discard(let time)):
                try validateUndoJournalTime(time)
                try markUnownedTerminalSessionsForCleanup(
                    database, finishedUndoWorkspaceID: nil, requestedAt: time.utc)
                return try readUndoJournalReceipt(
                    workspaceID: replacement.workspace.id, retiredCloses: [], database: database)
            case nil:
                return nil
            }
        }
    }

    func clearActiveWorkspaceSelection(updatedAt: Date) throws {
        try databaseWriter.write { database in
            guard try workspaceCount(database) == 0 else {
                throw WorkspaceCoreRepositoryError.cannotClearActiveWorkspaceWhileWorkspacesExist
            }
            try updateActiveWorkspaceSelection(database, workspaceId: nil, updatedAt: updatedAt)
        }
    }

    @discardableResult
    func deleteWorkspace(_ workspaceId: UUID, updatedAt: Date) throws -> UUID? {
        try databaseWriter.write { database in
            try requireWorkspaceExists(database, id: workspaceId)
            guard updatedAt.timeIntervalSince1970.isFinite else { throw WorkspaceUndoJournalFailure.invalidClock }
            let affectedSessions = try terminalSessionsOwnedByWorkspace(workspaceId, database: database)
            try database.execute(
                sql: "UPDATE workspace_undo_close SET state = 'evicted' WHERE workspace_id = ? AND state = 'available'",
                arguments: [workspaceId.uuidString])
            let workspacePaneIds = try String.fetchAll(
                database, sql: "SELECT id FROM pane WHERE workspace_id = ?", arguments: [workspaceId.uuidString]
            ).compactMap(UUID.init(uuidString:))
            try deleteBrowserContent(database, paneIds: Set(workspacePaneIds))
            let activeWorkspaceIdStringAfterDelete = try prepareActiveWorkspaceSelectionForDelete(
                database,
                deletingWorkspaceId: workspaceId,
                updatedAt: updatedAt
            )
            try database.execute(
                sql: """
                        DELETE FROM workspace
                        WHERE id = ?
                    """,
                arguments: [workspaceId.uuidString]
            )
            for sessionID in affectedSessions {
                try markUnownedTerminalSessionsForCleanup(
                    database, finishedUndoWorkspaceID: nil, sessionID: sessionID, requestedAt: updatedAt)
            }
            try pruneFinishedUndoRows(workspaceID: workspaceId, database: database)
            guard let activeWorkspaceIdStringAfterDelete else { return nil }
            return UUID(uuidString: activeWorkspaceIdStringAfterDelete)
        }
    }

}

enum WorkspaceCoreRepositoryError: Error, Equatable {
    case workspaceNotFound(UUID)
    case repoNotFound(UUID)
    case duplicateRepoId(UUID)
    case duplicateWorktreeId(UUID)
    case duplicateRepositoryTag(String)
    case duplicateWatchedPathStableKey(String)
    case duplicateRepoStableKey(String)
    case duplicateWorktreeStableKey(String)
    case invalidRepositoryTag(String)
    case invalidTabColorHex(String)
    case duplicatePaneId(UUID)
    case duplicateDrawerId(UUID)
    case duplicateTabId(UUID)
    case tabShellSetRequiresGraphReplacement(existingTabIds: Set<UUID>, incomingTabIds: Set<UUID>)
    case duplicateTabPaneId(tabId: UUID, paneId: UUID)
    case duplicateArrangementId(UUID)
    case paneBelongsToDifferentWorkspace(paneId: UUID, expectedWorkspaceId: UUID, actualWorkspaceId: UUID)
    case drawerBelongsToDifferentWorkspace(drawerId: UUID, expectedWorkspaceId: UUID, actualWorkspaceId: UUID)
    case tabBelongsToDifferentWorkspace(tabId: UUID, expectedWorkspaceId: UUID, actualWorkspaceId: UUID)
    case arrangementBelongsToDifferentWorkspace(
        arrangementId: UUID,
        expectedWorkspaceId: UUID,
        actualWorkspaceId: UUID
    )
    case paneNotFoundInWorkspace(UUID, UUID)
    case worktreeNotFound(UUID)
    case worktreeReparentingChangedLocation(UUID)
    case tabNotFoundInWorkspace(UUID, UUID)
    case drawerNotFoundInWorkspace(UUID, UUID)
    case drawerParentPaneMissing(drawerId: UUID, parentPaneId: UUID)
    case drawerParentMismatch(drawerId: UUID, expectedParentPaneId: UUID, actualParentPaneId: UUID)
    case drawerChildPaneMissing(drawerId: UUID, childPaneId: UUID)
    case drawerChildParentMismatch(childPaneId: UUID, expectedParentPaneId: UUID, actualParentPaneId: UUID)
    case drawerChildMissingParent(childPaneId: UUID, parentPaneId: UUID)
    case drawerChildMembershipMissing(childPaneId: UUID, parentPaneId: UUID)
    case drawerChildListedMultipleTimes(childPaneId: UUID)
    case drawerChildCannotOwnDrawer(childPaneId: UUID, drawerId: UUID)
    case paneSourceFacetRepoMismatch(paneId: UUID, sourceRepoId: UUID, facetRepoId: UUID)
    case paneSourceFacetWorktreeMismatch(paneId: UUID, sourceWorktreeId: UUID, facetWorktreeId: UUID)
    case panePayloadContentTypeUnsupported(paneId: UUID, contentType: PaneContentType)
    case paneContentTypeIsImmutable(paneId: UUID, oldContentType: PaneContentType, newContentType: PaneContentType)
    case tabHasInvalidDefaultArrangementCount(tabId: UUID, count: Int)
    case tabHasNoPanes(UUID)
    case tabGraphMissingTabState(UUID)
    case tabPaneMissingFromArrangements(tabId: UUID, paneId: UUID)
    case arrangementLayoutPaneListedMultipleTimes(arrangementId: UUID, paneId: UUID)
    case layoutDividerListedMultipleTimes(arrangementId: UUID, dividerId: UUID)
    case arrangementPaneMissingFromTab(tabId: UUID, arrangementId: UUID, paneId: UUID)
    case arrangementMinimizedPaneMissingFromLayout(arrangementId: UUID, paneId: UUID)
    case defaultArrangementLayoutIsEmpty(tabId: UUID, arrangementId: UUID)
    case arrangementLayoutPaneUsesDrawerChild(arrangementId: UUID, paneId: UUID, parentPaneId: UUID)
    case drawerViewPaneNotInDrawer(drawerId: UUID, paneId: UUID)
    case drawerViewPaneListedMultipleTimes(arrangementId: UUID, paneId: UUID)
    case drawerViewDividerListedMultipleTimes(arrangementId: UUID, drawerId: UUID, dividerId: UUID)
    case drawerViewLayoutIsEmpty(arrangementId: UUID, drawerId: UUID)
    case drawerViewParentPaneMissingFromLayout(arrangementId: UUID, drawerId: UUID, parentPaneId: UUID)
    case malformedTabId(String)
    case malformedArrangementId(String)
    case malformedLayout(String)
    case unavailableRepoNotInTopology(UUID)
    case worktreeRepoMismatch(worktreeId: UUID, expectedRepoId: UUID, actualRepoId: UUID)
    case activeWorkspaceSelectionDangling(UUID)
    case cannotClearActiveWorkspaceWhileWorkspacesExist
    case malformedWorkspaceId(String)
    case malformedRepoId(String)
    case malformedWorktreeId(String)
    case malformedWatchedPathId(String)
    case malformedPaneId(String)
    case malformedDrawerId(String)
    case malformedPaneContent(String)
}

func decodeWorkspaceRecord(_ row: Row) throws -> WorkspaceCoreRepository.WorkspaceRecord {
    let idString: String = row["id"]
    guard let id = UUID(uuidString: idString) else {
        throw WorkspaceCoreRepositoryError.malformedWorkspaceId(idString)
    }
    let name: String = row["name"]
    let createdAt: Double = row["created_at"]
    let updatedAt: Double = row["updated_at"]
    return .init(
        id: id,
        name: name,
        createdAt: Date(timeIntervalSince1970: createdAt),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

private func fetchActiveWorkspaceIdFromDatabase(_ database: Database) throws -> UUID? {
    guard
        let idString = try fetchActiveWorkspaceIdStringFromDatabase(database)
    else {
        return nil
    }
    guard let id = UUID(uuidString: idString) else {
        throw WorkspaceCoreRepositoryError.malformedWorkspaceId(idString)
    }
    guard try workspaceExists(database, id: idString) else {
        throw WorkspaceCoreRepositoryError.activeWorkspaceSelectionDangling(id)
    }
    return id
}

private func fetchActiveWorkspaceIdStringFromDatabase(_ database: Database) throws -> String? {
    try String.fetchOne(
        database,
        sql: """
            SELECT active_workspace_id
            FROM app_workspace_selection
            WHERE singleton_id = 1
            """
    )
}

private func fetchFallbackWorkspaceIdString(
    _ database: Database,
    excluding excludedWorkspaceId: String? = nil
) throws -> String? {
    if let excludedWorkspaceId {
        return try String.fetchOne(
            database,
            sql: """
                SELECT id
                FROM workspace
                WHERE id != ?
                ORDER BY updated_at DESC, id ASC
                LIMIT 1
                """,
            arguments: [excludedWorkspaceId]
        )
    }
    return try String.fetchOne(
        database,
        sql: """
            SELECT id
            FROM workspace
            ORDER BY updated_at DESC, id ASC
            LIMIT 1
            """
    )
}

private func updateActiveWorkspaceSelection(
    _ database: Database,
    workspaceId: String?,
    updatedAt: Date
) throws {
    try database.execute(
        sql: """
            INSERT INTO app_workspace_selection(singleton_id, active_workspace_id, updated_at)
            VALUES (1, ?, ?)
            ON CONFLICT(singleton_id) DO UPDATE SET
                active_workspace_id = excluded.active_workspace_id,
                updated_at = excluded.updated_at
            """,
        arguments: [
            workspaceId,
            updatedAt.timeIntervalSince1970,
        ]
    )
}

private func prepareActiveWorkspaceSelectionForDelete(
    _ database: Database,
    deletingWorkspaceId workspaceId: UUID,
    updatedAt: Date
) throws -> String? {
    guard let currentActiveWorkspaceIdString = try fetchActiveWorkspaceIdStringFromDatabase(database) else {
        return nil
    }
    guard let currentActiveWorkspaceId = UUID(uuidString: currentActiveWorkspaceIdString) else {
        throw WorkspaceCoreRepositoryError.malformedWorkspaceId(currentActiveWorkspaceIdString)
    }
    guard try workspaceExists(database, id: currentActiveWorkspaceIdString) else {
        throw WorkspaceCoreRepositoryError.activeWorkspaceSelectionDangling(currentActiveWorkspaceId)
    }
    guard currentActiveWorkspaceId == workspaceId else {
        return currentActiveWorkspaceIdString
    }

    let fallbackWorkspaceIdString = try fetchFallbackWorkspaceIdString(
        database,
        excluding: workspaceId.uuidString
    )
    try updateActiveWorkspaceSelection(
        database,
        workspaceId: fallbackWorkspaceIdString,
        updatedAt: updatedAt
    )
    return fallbackWorkspaceIdString
}

func requireWorkspaceExists(_ database: Database, id: UUID) throws {
    guard try workspaceExists(database, id: id.uuidString) else {
        throw WorkspaceCoreRepositoryError.workspaceNotFound(id)
    }
}

func workspaceExists(_ database: Database, id: String) throws -> Bool {
    let matchingCount = try Int.fetchOne(
        database,
        sql: """
            SELECT count(*)
            FROM workspace
            WHERE id = ?
            """,
        arguments: [id]
    )
    return matchingCount == 1
}

private func workspaceCount(_ database: Database) throws -> Int {
    try Int.fetchOne(
        database,
        sql: """
            SELECT count(*)
            FROM workspace
            """
    ) ?? 0
}
