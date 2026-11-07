import Foundation
import GRDB

extension WorkspaceCoreRepository {
    struct PaneGraphRecord: Equatable, Sendable {
        var panes: [PaneRecord]
    }

    struct PaneRecord: Equatable, Sendable {
        let id: UUID
        var content: PaneContentRecord
        var metadata: PaneMetadataRecord
        var residency: PaneResidencyRecord
        var placement: PanePlacementRecord
        var drawer: DrawerRecord?
        var updatedAt: Date
    }

    enum PaneContentRecord: Equatable, Sendable {
        case terminal(provider: SessionProvider, lifetime: SessionLifetime, zmxSessionID: ZmxSessionID)
        /// A browser pane: its webviews (tabs) in order and the active one.
        case browser(activeWebviewId: UUID, showNavigation: Bool, webviews: [WebviewTabSnapshot])
        case codeViewer(filePath: URL, scrollToLine: Int?)
        /// `contentType` and `payloadKind` are routing/index tokens; `payloadJSON`
        /// is the content-specific representation for payload-backed pane types.
        case payload(contentType: PaneContentType, payloadKind: String, payloadJSON: String)

        var contentType: PaneContentType {
            switch self {
            case .terminal:
                .terminal
            case .browser:
                .browser
            case .codeViewer:
                .codeViewer
            case .payload(let contentType, _, _):
                contentType
            }
        }
    }

    struct PaneMetadataRecord: Equatable, Sendable {
        var launchDirectory: URL?
        var executionBackend: ExecutionBackend
        var createdAt: Date
        var title: String
        var note: String?
        var checkoutRef: String?
        var isPinned: Bool
        var durableFacets: DurableFacetsRecord

        init(
            launchDirectory: URL? = nil,
            executionBackend: ExecutionBackend,
            createdAt: Date,
            title: String,
            note: String? = nil,
            checkoutRef: String? = nil,
            isPinned: Bool = false,
            durableFacets: DurableFacetsRecord = .init()
        ) {
            self.launchDirectory = launchDirectory
            self.executionBackend = executionBackend
            self.createdAt = createdAt
            self.title = title
            self.note = note
            self.checkoutRef = checkoutRef
            self.isPinned = isPinned
            self.durableFacets = durableFacets
        }
    }

    struct DurableFacetsRecord: Equatable, Sendable {
        var repoId: UUID?
        var worktreeId: UUID?
        var cwd: URL?

        init(repoId: UUID? = nil, worktreeId: UUID? = nil, cwd: URL? = nil) {
            self.repoId = repoId
            self.worktreeId = worktreeId
            self.cwd = cwd
        }

    }

    enum PaneResidencyRecord: Equatable, Sendable {
        case active
        case backgrounded
        case pendingUndo(expiresAt: Date)
        case orphaned(worktreePath: String)
    }

    enum PanePlacementRecord: Equatable, Sendable {
        case layout
        case drawerChild(parentPaneId: UUID)
    }

    struct DrawerRecord: Equatable, Sendable {
        let drawerId: UUID
        let parentPaneId: UUID
        var childPaneIds: [UUID]
    }

    func replacePaneGraph(workspaceId: UUID, graph: PaneGraphRecord) throws {
        try databaseWriter.write { database in
            try requireWorkspaceExists(database, id: workspaceId)
            try validatePaneGraph(database, workspaceId: workspaceId, graph: graph)
            try replacePaneGraphRows(database, workspaceId: workspaceId, graph: graph)
        }
    }

    func fetchPaneGraph(workspaceId: UUID) throws -> PaneGraphRecord {
        try databaseWriter.read { database in
            try readPaneGraph(database, workspaceId: workspaceId)
        }
    }
}

func readPaneGraph(
    _ database: Database,
    workspaceId: UUID
) throws -> WorkspaceCoreRepository.PaneGraphRecord {
    try requireWorkspaceExists(database, id: workspaceId)
    let rows = try Row.fetchAll(
        database,
        sql: """
            SELECT *
            FROM pane
            WHERE workspace_id = ?
            ORDER BY created_at ASC, id ASC
            """,
        arguments: [workspaceId.uuidString]
    )
    let panes = try rows.map { row in
        try decodePaneRecord(database, row: row)
    }
    return .init(panes: panes)
}

private func decodePaneRecord(_ database: Database, row: Row) throws -> WorkspaceCoreRepository.PaneRecord {
    let idString: String = row["id"]
    guard let id = UUID(uuidString: idString) else {
        throw WorkspaceCoreRepositoryError.malformedPaneId(idString)
    }
    let contentTypeString: String = row["content_type"]
    let contentType = try decodePaneContentType(contentTypeString)
    let content = try decodePaneContentRecord(database, paneId: id, contentType: contentType)
    let launchDirectoryPath: String? = row["launch_directory"]
    let executionBackendString: String = row["execution_backend"]
    let executionBackend = try decodeExecutionBackend(executionBackendString)
    let createdAt: Double = row["created_at"]
    let title: String = row["title"]
    let note: String? = row["note"]
    let checkoutRef: String? = row["checkout_ref"]
    let isPinned = (row["is_pinned"] as Int) == 1
    let cwdPath: String? = row["cwd"]
    let facetRepoId = try decodeOptionalUUID(
        row["facet_repo_id"],
        malformedError: WorkspaceCoreRepositoryError.malformedRepoId
    )
    let facetWorktreeId = try decodeOptionalUUID(
        row["facet_worktree_id"],
        malformedError: WorkspaceCoreRepositoryError.malformedWorktreeId
    )
    let metadata = WorkspaceCoreRepository.PaneMetadataRecord(
        launchDirectory: launchDirectoryPath.map {
            URL(filePath: $0, directoryHint: .isDirectory)
        },
        executionBackend: executionBackend,
        createdAt: Date(timeIntervalSince1970: createdAt),
        title: title,
        note: note,
        checkoutRef: checkoutRef,
        isPinned: isPinned,
        durableFacets: .init(
            repoId: facetRepoId,
            worktreeId: facetWorktreeId,
            cwd: cwdPath.map {
                URL(filePath: $0, directoryHint: .isDirectory)
            }
        )
    )
    let residency = try decodePaneResidency(row)
    let placement = try decodePanePlacement(row)
    let drawer = try fetchDrawerRecord(database, parentPaneId: id)
    let updatedAt: Double = row["updated_at"]
    return .init(
        id: id,
        content: content,
        metadata: metadata,
        residency: residency,
        placement: placement,
        drawer: drawer,
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

private func decodeOptionalUUID(
    _ value: String?,
    malformedError: (String) -> WorkspaceCoreRepositoryError
) throws -> UUID? {
    guard let value else { return nil }
    guard let id = UUID(uuidString: value) else {
        throw malformedError(value)
    }
    return id
}
