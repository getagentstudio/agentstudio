import Foundation
import GRDB

func replacePaneGraphRows(
    _ database: Database,
    workspaceId: UUID,
    graph: WorkspaceCoreRepository.PaneGraphRecord
) throws {
    let paneIds = Set(graph.panes.map(\.id))
    let drawerIds = Set(graph.panes.compactMap(\.drawer?.drawerId))
    try deleteDrawerMembershipRows(database, workspaceId: workspaceId)
    try deleteDrawersNotIn(database, workspaceId: workspaceId, drawerIds: drawerIds)
    try deletePanesNotIn(database, workspaceId: workspaceId, paneIds: paneIds)

    for pane in layoutPanesBeforeDrawerChildren(graph.panes) {
        try upsertPane(database, workspaceId: workspaceId, pane: pane)
        try replacePaneContent(database, pane: pane)
    }

    for drawer in graph.panes.compactMap(\.drawer) {
        try upsertDrawer(database, drawer: drawer)
    }
    for drawer in graph.panes.compactMap(\.drawer) {
        try insertDrawerMembershipRows(database, drawer: drawer)
    }
}

private func deleteDrawerMembershipRows(_ database: Database, workspaceId: UUID) throws {
    try database.execute(
        sql: """
            DELETE FROM drawer_pane
            WHERE drawer_id IN (
                SELECT drawer.id
                FROM drawer
                JOIN pane ON pane.id = drawer.parent_pane_id
                WHERE pane.workspace_id = ?
            )
            """,
        arguments: [workspaceId.uuidString]
    )
}

private func deleteDrawersNotIn(_ database: Database, workspaceId: UUID, drawerIds: Set<UUID>) throws {
    if drawerIds.isEmpty {
        try database.execute(
            sql: """
                DELETE FROM drawer
                WHERE parent_pane_id IN (
                    SELECT id
                    FROM pane
                    WHERE workspace_id = ?
                )
                """,
            arguments: [workspaceId.uuidString]
        )
        return
    }

    try database.execute(
        sql: """
            DELETE FROM drawer
            WHERE parent_pane_id IN (
                SELECT id
                FROM pane
                WHERE workspace_id = ?
            )
            AND id NOT IN (\(paneGraphPlaceholders(count: drawerIds.count)))
            """,
        arguments: StatementArguments([workspaceId.uuidString] + sortedUUIDStrings(drawerIds))
    )
}

private func deletePanesNotIn(_ database: Database, workspaceId: UUID, paneIds: Set<UUID>) throws {
    let removedPaneIds = try String.fetchAll(
        database, sql: "SELECT id FROM pane WHERE workspace_id = ?", arguments: [workspaceId.uuidString]
    ).compactMap(UUID.init(uuidString:)).filter { !paneIds.contains($0) }
    try deleteBrowserContent(database, paneIds: Set(removedPaneIds))
    if paneIds.isEmpty {
        try database.execute(
            sql: """
                DELETE FROM pane
                WHERE workspace_id = ?
                """,
            arguments: [workspaceId.uuidString]
        )
        return
    }

    try database.execute(
        sql: """
            DELETE FROM pane
            WHERE workspace_id = ?
            AND id NOT IN (\(paneGraphPlaceholders(count: paneIds.count)))
            """,
        arguments: StatementArguments([workspaceId.uuidString] + sortedUUIDStrings(paneIds))
    )
}

private func upsertPane(_ database: Database, workspaceId: UUID, pane: WorkspaceCoreRepository.PaneRecord) throws {
    try database.execute(
        sql: """
            INSERT INTO pane(
                id, workspace_id, content_type, execution_backend,
                launch_directory, title, note, is_pinned,
                cwd, facet_repo_id, facet_worktree_id,
                checkout_ref, residency_kind, pending_undo_expires_at,
                orphan_reason_kind, orphan_worktree_path, kind, parent_pane_id,
                created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content_type = excluded.content_type,
                execution_backend = excluded.execution_backend,
                launch_directory = excluded.launch_directory,
                title = excluded.title,
                note = excluded.note,
                is_pinned = excluded.is_pinned,
                cwd = excluded.cwd,
                facet_repo_id = excluded.facet_repo_id,
                facet_worktree_id = excluded.facet_worktree_id,
                checkout_ref = excluded.checkout_ref,
                residency_kind = excluded.residency_kind,
                pending_undo_expires_at = excluded.pending_undo_expires_at,
                orphan_reason_kind = excluded.orphan_reason_kind,
                orphan_worktree_path = excluded.orphan_worktree_path,
                kind = excluded.kind,
                parent_pane_id = excluded.parent_pane_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
            """,
        arguments: try paneStatementArguments(
            workspaceId: workspaceId,
            pane: paneWithValidatedTopologyFacets(database, pane: pane)
        )
    )
}

private func replacePaneContent(_ database: Database, pane: WorkspaceCoreRepository.PaneRecord) throws {
    try deletePaneContentRows(database, paneId: pane.id)
    switch pane.content {
    case .terminal(let provider, let lifetime, let zmxSessionID):
        try insertTerminalContent(
            database,
            paneId: pane.id,
            provider: provider,
            lifetime: lifetime,
            zmxSessionID: zmxSessionID
        )
    case .browser(let activeWebviewId, let showNavigation, let webviews):
        try insertBrowserContent(
            database, paneId: pane.id, activeWebviewId: activeWebviewId, showNavigation: showNavigation,
            webviews: webviews)
    case .codeViewer(let filePath, let scrollToLine):
        try insertCodeViewerContent(database, paneId: pane.id, filePath: filePath, scrollToLine: scrollToLine)
    case .payload(_, let payloadKind, let payloadJSON):
        try insertPayloadContent(database, paneId: pane.id, payloadKind: payloadKind, payloadJSON: payloadJSON)
    }
}

private func deletePaneContentRows(_ database: Database, paneId: UUID) throws {
    for table in ["pane_content_terminal", "pane_content_code_viewer", "pane_content_payload"] {
        try database.execute(sql: "DELETE FROM \(table) WHERE pane_id = ?", arguments: [paneId.uuidString])
    }
    try deleteBrowserContent(database, paneIds: [paneId])
}

/// Deletes the browser rows of every pane in `paneIds`. These tables have no
/// cascade from `pane`, so every route that removes panes calls this first,
/// in the same transaction.
func deleteBrowserContent(_ database: Database, paneIds: Set<UUID>) throws {
    let ids = sortedUUIDStrings(paneIds)
    for chunkStart in stride(from: 0, to: ids.count, by: 500) {
        let chunk = Array(ids[chunkStart..<min(chunkStart + 500, ids.count)])
        let placeholders = paneGraphPlaceholders(count: chunk.count)
        try database.execute(
            sql: "DELETE FROM pane_content_webview WHERE browser_pane_id IN (\(placeholders))",
            arguments: StatementArguments(chunk))
        try database.execute(
            sql: "DELETE FROM pane_content_browser WHERE pane_id IN (\(placeholders))",
            arguments: StatementArguments(chunk))
    }
}

private func insertTerminalContent(
    _ database: Database,
    paneId: UUID,
    provider: SessionProvider,
    lifetime: SessionLifetime,
    zmxSessionID: ZmxSessionID
) throws {
    try database.execute(
        sql: """
            INSERT INTO pane_content_terminal(pane_id, provider, lifetime, zmx_session_id)
            VALUES (?, ?, ?, ?)
            """,
        arguments: [paneId.uuidString, provider.rawValue, lifetime.rawValue, zmxSessionID.rawValue]
    )
}

/// Writes one browser row and its webviews; each webview's array index is its `position`.
private func insertBrowserContent(
    _ database: Database,
    paneId: UUID,
    activeWebviewId: UUID,
    showNavigation: Bool,
    webviews: [WebviewTabSnapshot]
) throws {
    try database.execute(
        sql: """
            INSERT INTO pane_content_browser(pane_id, active_webview_id, show_navigation)
            VALUES (?, ?, ?)
            """,
        arguments: [paneId.uuidString, activeWebviewId.uuidString, showNavigation ? 1 : 0]
    )
    for (position, webview) in webviews.enumerated() {
        try database.execute(
            sql: """
                INSERT INTO pane_content_webview(id, browser_pane_id, position, url, title)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [webview.id.uuidString, paneId.uuidString, position, webview.url.absoluteString, webview.title]
        )
    }
}

private func insertCodeViewerContent(
    _ database: Database,
    paneId: UUID,
    filePath: URL,
    scrollToLine: Int?
) throws {
    try database.execute(
        sql: """
            INSERT INTO pane_content_code_viewer(pane_id, file_path, scroll_to_line)
            VALUES (?, ?, ?)
            """,
        arguments: [paneId.uuidString, filePath.path, scrollToLine]
    )
}

private func insertPayloadContent(
    _ database: Database,
    paneId: UUID,
    payloadKind: String,
    payloadJSON: String
) throws {
    try database.execute(
        sql: """
            INSERT INTO pane_content_payload(pane_id, payload_kind, payload_json)
            VALUES (?, ?, ?)
            """,
        arguments: [paneId.uuidString, payloadKind, payloadJSON]
    )
}

private func upsertDrawer(_ database: Database, drawer: WorkspaceCoreRepository.DrawerRecord) throws {
    try database.execute(
        sql: """
            INSERT INTO drawer(id, parent_pane_id)
            VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET
                parent_pane_id = excluded.parent_pane_id
            """,
        arguments: [drawer.drawerId.uuidString, drawer.parentPaneId.uuidString]
    )
}

private func insertDrawerMembershipRows(_ database: Database, drawer: WorkspaceCoreRepository.DrawerRecord) throws {
    for (index, childPaneId) in drawer.childPaneIds.enumerated() {
        try database.execute(
            sql: """
                INSERT INTO drawer_pane(drawer_id, pane_id, sort_index)
                VALUES (?, ?, ?)
                """,
            arguments: [drawer.drawerId.uuidString, childPaneId.uuidString, index]
        )
    }
}

private func paneStatementArguments(
    workspaceId: UUID,
    pane: WorkspaceCoreRepository.PaneRecord
) throws -> StatementArguments {
    let residency = SQLitePaneGraphStorage.residency(pane.residency)
    let placement = SQLitePaneGraphStorage.placement(pane.placement)
    let values: [(any DatabaseValueConvertible)?] = [
        pane.id.uuidString,
        workspaceId.uuidString,
        SQLitePaneContentTypeStorage.storageValue(for: pane.content.contentType),
        try encodeExecutionBackend(pane.metadata.executionBackend),
        pane.metadata.launchDirectory?.path,
        pane.metadata.title,
        pane.metadata.note,
        pane.metadata.isPinned ? 1 : 0,
        pane.metadata.durableFacets.cwd?.path,
        pane.metadata.durableFacets.repoId?.uuidString,
        pane.metadata.durableFacets.worktreeId?.uuidString,
        pane.metadata.checkoutRef,
        residency.kind,
        residency.pendingUndoExpiresAt,
        residency.orphanReasonKind,
        residency.orphanWorktreePath,
        placement.kind,
        placement.parentPaneId?.uuidString,
        pane.metadata.createdAt.timeIntervalSince1970,
        pane.updatedAt.timeIntervalSince1970,
    ]
    return StatementArguments(values)
}

private func paneGraphPlaceholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

private func layoutPanesBeforeDrawerChildren(
    _ panes: [WorkspaceCoreRepository.PaneRecord]
) -> [WorkspaceCoreRepository.PaneRecord] {
    panes.sorted { lhs, rhs in
        switch (lhs.placement, rhs.placement) {
        case (.layout, .drawerChild):
            true
        case (.drawerChild, .layout):
            false
        default:
            lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private func sortedUUIDStrings(_ ids: Set<UUID>) -> [String] {
    ids.sorted { $0.uuidString < $1.uuidString }.map(\.uuidString)
}
