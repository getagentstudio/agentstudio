import Foundation
import GRDB

func decodePaneContentRecord(
    _ database: Database,
    paneId: UUID,
    contentType: PaneContentType
) throws -> WorkspaceCoreRepository.PaneContentRecord {
    switch contentType {
    case .terminal:
        try decodeTerminalContent(database, paneId: paneId)
    case .browser:
        try decodeBrowserContent(database, paneId: paneId)
    case .codeViewer:
        try decodeCodeViewerContent(database, paneId: paneId)
    case .diff, .editor, .review, .agent, .plugin:
        try decodePayloadContent(database, paneId: paneId, contentType: contentType)
    }
}

func decodePaneResidency(_ row: Row) throws -> WorkspaceCoreRepository.PaneResidencyRecord {
    let residencyKind: String = row["residency_kind"]
    switch residencyKind {
    case SQLitePaneGraphStorage.residencyKindActive:
        return .active
    case SQLitePaneGraphStorage.residencyKindBackgrounded:
        return .backgrounded
    case SQLitePaneGraphStorage.residencyKindPendingUndo:
        let expiresAt: Double? = row["pending_undo_expires_at"]
        guard let expiresAt else {
            throw WorkspaceCoreRepositoryError.malformedPaneContent("pending undo residency missing expiration")
        }
        return .pendingUndo(expiresAt: Date(timeIntervalSince1970: expiresAt))
    case SQLitePaneGraphStorage.residencyKindOrphaned:
        let reasonKind: String? = row["orphan_reason_kind"]
        let worktreePath: String? = row["orphan_worktree_path"]
        guard reasonKind == SQLitePaneGraphStorage.orphanReasonWorktreeNotFound, let worktreePath else {
            throw WorkspaceCoreRepositoryError.malformedPaneContent("orphaned residency missing worktree reason")
        }
        return .orphaned(worktreePath: worktreePath)
    default:
        throw WorkspaceCoreRepositoryError.malformedPaneContent("unknown pane residency kind \(residencyKind)")
    }
}

func decodePanePlacement(_ row: Row) throws -> WorkspaceCoreRepository.PanePlacementRecord {
    let kind: String = row["kind"]
    switch kind {
    case SQLitePaneGraphStorage.placementKindLayout, "leaf":
        return .layout
    case SQLitePaneGraphStorage.placementKindDrawerChild:
        let parentPaneIdString: String? = row["parent_pane_id"]
        guard let parentPaneIdString, let parentPaneId = UUID(uuidString: parentPaneIdString) else {
            throw WorkspaceCoreRepositoryError.malformedPaneId(parentPaneIdString ?? "")
        }
        return .drawerChild(parentPaneId: parentPaneId)
    default:
        throw WorkspaceCoreRepositoryError.malformedPaneContent("unknown pane placement kind \(kind)")
    }
}

func fetchDrawerRecord(_ database: Database, parentPaneId: UUID) throws -> WorkspaceCoreRepository.DrawerRecord? {
    guard
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT id, parent_pane_id
                FROM drawer
                WHERE parent_pane_id = ?
                """,
            arguments: [parentPaneId.uuidString]
        )
    else {
        return nil
    }
    let drawerIdString: String = row["id"]
    guard let drawerId = UUID(uuidString: drawerIdString) else {
        throw WorkspaceCoreRepositoryError.malformedDrawerId(drawerIdString)
    }
    let parentPaneIdString: String = row["parent_pane_id"]
    guard let decodedParentPaneId = UUID(uuidString: parentPaneIdString) else {
        throw WorkspaceCoreRepositoryError.malformedPaneId(parentPaneIdString)
    }
    let childPaneIds = try fetchDrawerChildPaneIds(database, drawerId: drawerId)
    return .init(drawerId: drawerId, parentPaneId: decodedParentPaneId, childPaneIds: childPaneIds)
}

func decodePaneContentType(_ storageValue: String) throws -> PaneContentType {
    switch storageValue {
    case SQLitePaneContentTypeStorage.terminal:
        return .terminal
    case SQLitePaneContentTypeStorage.browser:
        return .browser
    case SQLitePaneContentTypeStorage.diff:
        return .diff
    case SQLitePaneContentTypeStorage.editor:
        return .editor
    case SQLitePaneContentTypeStorage.review:
        return .review
    case SQLitePaneContentTypeStorage.agent:
        return .agent
    case SQLitePaneContentTypeStorage.codeViewer:
        return .codeViewer
    default:
        guard storageValue.hasPrefix(SQLitePaneContentTypeStorage.pluginPrefix) else {
            throw WorkspaceCoreRepositoryError.malformedPaneContent("unknown content type \(storageValue)")
        }
        let pluginIdentifier = String(storageValue.dropFirst(SQLitePaneContentTypeStorage.pluginPrefix.count))
        guard !pluginIdentifier.isEmpty else {
            throw WorkspaceCoreRepositoryError.malformedPaneContent("empty plugin content type")
        }
        return .plugin(pluginIdentifier)
    }
}

func encodeExecutionBackend(_ backend: ExecutionBackend) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(backend)
    guard let value = String(data: data, encoding: .utf8) else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("invalid execution backend payload")
    }
    return value
}

func decodeExecutionBackend(_ value: String) throws -> ExecutionBackend {
    if value == "local" {
        return .local
    }
    guard let data = value.data(using: .utf8) else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("invalid execution backend string")
    }
    do {
        return try JSONDecoder().decode(ExecutionBackend.self, from: data)
    } catch {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("invalid execution backend \(value)")
    }
}

private func decodeTerminalContent(
    _ database: Database,
    paneId: UUID
) throws -> WorkspaceCoreRepository.PaneContentRecord {
    guard
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT provider, lifetime, zmx_session_id
                FROM pane_content_terminal
                WHERE pane_id = ?
                """,
            arguments: [paneId.uuidString]
        )
    else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("terminal content row missing for \(paneId)")
    }
    let providerString: String = row["provider"]
    let lifetimeString: String = row["lifetime"]
    guard let provider = SessionProvider(rawValue: providerString) else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("unknown terminal provider \(providerString)")
    }
    guard let lifetime = SessionLifetime(rawValue: lifetimeString) else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("unknown terminal lifetime \(lifetimeString)")
    }
    let storedZmxSessionID: String? = row["zmx_session_id"]
    guard let storedZmxSessionID else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent(
            "terminal content missing zmx session identity for \(paneId)"
        )
    }
    guard let zmxSessionID = ZmxSessionID(restoring: storedZmxSessionID) else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent(
            "terminal content has empty zmx session identity for \(paneId)"
        )
    }
    return .terminal(provider: provider, lifetime: lifetime, zmxSessionID: zmxSessionID)
}

/// Reads a browser pane: its `pane_content_browser` row and its webviews in
/// `position` order. A browser with no webviews, or whose active id names none
/// of them, is malformed.
private func decodeBrowserContent(
    _ database: Database,
    paneId: UUID
) throws -> WorkspaceCoreRepository.PaneContentRecord {
    guard
        let browserRow = try Row.fetchOne(
            database,
            sql: """
                SELECT active_webview_id, show_navigation
                FROM pane_content_browser
                WHERE pane_id = ?
                """,
            arguments: [paneId.uuidString]
        )
    else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("browser content row missing for \(paneId)")
    }
    let activeIdString: String = browserRow["active_webview_id"]
    guard let activeWebviewId = UUID(uuidString: activeIdString) else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("invalid active webview id for \(paneId)")
    }
    let webviewRows = try Row.fetchAll(
        database,
        sql: """
            SELECT id, url, title
            FROM pane_content_webview
            WHERE browser_pane_id = ?
            ORDER BY position
            """,
        arguments: [paneId.uuidString]
    )
    let webviews = try webviewRows.map { row -> WebviewTabSnapshot in
        let idString: String = row["id"]
        let urlString: String = row["url"]
        guard let id = UUID(uuidString: idString), let url = URL(string: urlString) else {
            throw WorkspaceCoreRepositoryError.malformedPaneContent("invalid webview row for \(paneId)")
        }
        return WebviewTabSnapshot(id: id, url: url, title: row["title"])
    }
    guard webviews.contains(where: { $0.id == activeWebviewId }) else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("browser \(paneId) is missing its active webview")
    }
    let showNavigation: Int = browserRow["show_navigation"]
    return .browser(activeWebviewId: activeWebviewId, showNavigation: showNavigation != 0, webviews: webviews)
}

private func decodeCodeViewerContent(
    _ database: Database,
    paneId: UUID
) throws -> WorkspaceCoreRepository.PaneContentRecord {
    guard
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT file_path, scroll_to_line
                FROM pane_content_code_viewer
                WHERE pane_id = ?
                """,
            arguments: [paneId.uuidString]
        )
    else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("code viewer content row missing for \(paneId)")
    }
    let filePath: String = row["file_path"]
    let scrollToLine: Int? = row["scroll_to_line"]
    return .codeViewer(filePath: URL(fileURLWithPath: filePath), scrollToLine: scrollToLine)
}

private func decodePayloadContent(
    _ database: Database,
    paneId: UUID,
    contentType: PaneContentType
) throws -> WorkspaceCoreRepository.PaneContentRecord {
    guard
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT payload_kind, payload_json
                FROM pane_content_payload
                WHERE pane_id = ?
                """,
            arguments: [paneId.uuidString]
        )
    else {
        throw WorkspaceCoreRepositoryError.malformedPaneContent("payload content row missing for \(paneId)")
    }
    let payloadKind: String = row["payload_kind"]
    let payloadJSON: String = row["payload_json"]
    return .payload(contentType: contentType, payloadKind: payloadKind, payloadJSON: payloadJSON)
}

private func fetchDrawerChildPaneIds(_ database: Database, drawerId: UUID) throws -> [UUID] {
    let childPaneIdStrings = try String.fetchAll(
        database,
        sql: """
            SELECT pane_id
            FROM drawer_pane
            WHERE drawer_id = ?
            ORDER BY sort_index ASC
            """,
        arguments: [drawerId.uuidString]
    )
    return try childPaneIdStrings.map { childPaneIdString in
        guard let childPaneId = UUID(uuidString: childPaneIdString) else {
            throw WorkspaceCoreRepositoryError.malformedPaneId(childPaneIdString)
        }
        return childPaneId
    }
}
