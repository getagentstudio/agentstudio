import Foundation
import GRDB

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

func makeWorkspaceCoreRepositoryFixture() throws -> WorkspaceCoreTopologyRepositoryFixture {
    let databaseQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
    try WorkspaceCoreMigrations.migrate(databaseQueue)
    return .init(
        repository: WorkspaceCoreRepository(databaseWriter: databaseQueue),
        databaseQueue: databaseQueue
    )
}

struct WorkspaceCoreTopologyRepositoryFixture {
    let repository: WorkspaceCoreRepository
    let databaseQueue: DatabaseQueue

    func insertPane(
        workspaceId: UUID,
        paneId: UUID,
        cwd: URL
    ) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO pane(
                        id, workspace_id, content_type, execution_backend,
                        launch_directory, title, cwd,
                        residency_kind, kind, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    paneId.uuidString,
                    workspaceId.uuidString,
                    SQLitePaneContentTypeStorage.storageValue(for: .terminal),
                    "local",
                    cwd.path,
                    "Terminal",
                    cwd.path,
                    "active",
                    "leaf",
                    1.0,
                    1.0,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO pane_content_terminal(pane_id, provider, lifetime, zmx_session_id)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [paneId.uuidString, "zmx", "persistent", "test-\(paneId.uuidString)"]
            )
        }
    }

    func insertTabShell(workspaceId: UUID, tabId: UUID) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO tab_shell(id, workspace_id, name, sort_index)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [tabId.uuidString, workspaceId.uuidString, "First", 0]
            )
        }
    }

    func insertTabPane(tabId: UUID, paneId: UUID) throws {
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO tab_pane(tab_id, pane_id, sort_index)
                    VALUES (?, ?, ?)
                    """,
                arguments: [tabId.uuidString, paneId.uuidString, 0]
            )
        }
    }

    func fetchTabPaneCount(tabId: UUID, paneId: UUID) throws -> Int {
        try databaseQueue.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT count(*)
                    FROM tab_pane
                    WHERE tab_id = ?
                    AND pane_id = ?
                    """,
                arguments: [tabId.uuidString, paneId.uuidString]
            ) ?? 0
        }
    }

    func fetchPaneContentRouteCounts() throws -> PaneContentRouteCounts {
        try databaseQueue.read { database in
            try .init(
                terminal: fetchCount(database, tableName: "pane_content_terminal"),
                webview: fetchCount(database, tableName: "pane_content_browser"),
                codeViewer: fetchCount(database, tableName: "pane_content_code_viewer"),
                payload: fetchCount(database, tableName: "pane_content_payload")
            )
        }
    }

    private func fetchCount(_ database: Database, tableName: String) throws -> Int {
        try Int.fetchOne(database, sql: "SELECT count(*) FROM \(tableName)") ?? 0
    }
}

struct PaneSourceRecord: Equatable {
    let repoId: UUID?
    let worktreeId: UUID?
}

struct PaneContentRouteCounts: Equatable {
    let terminal: Int
    let webview: Int
    let codeViewer: Int
    let payload: Int
}

extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
