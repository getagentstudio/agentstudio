import Foundation

struct RepositoryTopologySQLiteSnapshot: Equatable, Sendable {
    let repos: [CanonicalRepo]
    let worktrees: [CanonicalWorktree]
    let absenceRecords: RepositoryTopologyAbsenceRecords
    var unavailableRepoIds: Set<UUID> { absenceRecords.unavailableRepositoryIDs }
    let watchedPaths: [WatchedPath]
    let watchedPathStableKeysByID: [UUID: String]
    let updatedAt: Date

    init(
        repos: [CanonicalRepo] = [],
        worktrees: [CanonicalWorktree] = [],
        unavailableRepoIds: Set<UUID> = [],
        watchedPaths: [WatchedPath] = [],
        watchedPathStableKeysByID: [UUID: String]? = nil,
        updatedAt: Date,
        absenceRecords: RepositoryTopologyAbsenceRecords = .init()
    ) {
        self.repos = repos
        self.worktrees = worktrees
        self.absenceRecords = absenceRecords.addingLegacyUnavailableRepositories(unavailableRepoIds)
        self.watchedPaths = watchedPaths
        self.watchedPathStableKeysByID =
            watchedPathStableKeysByID
            ?? Dictionary(uniqueKeysWithValues: watchedPaths.map { ($0.id, $0.stableKey) })
        self.updatedAt = updatedAt
    }
}

struct WorkspaceSQLiteSaveBundle: Equatable, Sendable {
    let workspace: WorkspaceSQLiteSnapshot
    let captureRevision: WorkspaceCompositionRevision?
    /// Drawer presentation preference revision captured with this bundle;
    /// a newer live revision keeps the store dirty after this save.
    let drawerPresentationRevision: Int?

    var id: UUID { workspace.id }
    var updatedAt: Date { workspace.updatedAt }

    init(
        workspace: WorkspaceSQLiteSnapshot,
        captureRevision: WorkspaceCompositionRevision? = nil,
        drawerPresentationRevision: Int? = nil
    ) {
        self.workspace = workspace
        self.captureRevision = captureRevision
        self.drawerPresentationRevision = drawerPresentationRevision
    }
}

struct WorkspaceCoreLoadSnapshot: Equatable, Sendable {
    let workspace: WorkspaceSQLiteSnapshot
    let repositoryTopology: RepositoryTopologySQLiteSnapshot
    let persistenceReasons: Set<PaneTopologyPersistenceReason>
    let terminalSessionProtocolVersions: [ZmxSessionID: UInt8]

    init(
        workspace: WorkspaceSQLiteSnapshot, repositoryTopology: RepositoryTopologySQLiteSnapshot,
        persistenceReasons: Set<PaneTopologyPersistenceReason>,
        terminalSessionProtocolVersions: [ZmxSessionID: UInt8] = [:]
    ) {
        self.workspace = workspace
        self.repositoryTopology = repositoryTopology
        self.persistenceReasons = persistenceReasons
        self.terminalSessionProtocolVersions = terminalSessionProtocolVersions
    }
}
