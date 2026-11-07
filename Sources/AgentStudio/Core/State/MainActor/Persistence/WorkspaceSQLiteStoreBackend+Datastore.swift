import Foundation

extension WorkspaceSQLiteStoreBackend {
    func loadCompletedSnapshot(
        localRepositoryForWorkspaceId: @Sendable (UUID) async throws -> WorkspaceLocalRepository
    ) async throws -> WorkspaceCoreLoadSnapshot {
        let authoritativeSnapshot = try strictlySelectedAuthoritativeSnapshot()
        return try await loadCompletedSnapshot(
            authoritativeSnapshot: authoritativeSnapshot,
            localRepositoryForWorkspaceId: localRepositoryForWorkspaceId
        )
    }

    func loadCompletedSnapshot(
        authoritativeSnapshot: WorkspaceCoreRepository.AuthoritativeSnapshot,
        localRepositoryForWorkspaceId: @Sendable (UUID) async throws -> WorkspaceLocalRepository
    ) async throws -> WorkspaceCoreLoadSnapshot {
        let localRepository = try? await localRepositoryForWorkspaceId(authoritativeSnapshot.workspace.id)
        return try loadCompletedSnapshot(
            authoritativeSnapshot: authoritativeSnapshot,
            localRepository: localRepository
        )
    }

    func loadCompletedSnapshot(
        authoritativeSnapshot: WorkspaceCoreRepository.AuthoritativeSnapshot,
        localRepository: WorkspaceLocalRepository?
    ) throws -> WorkspaceCoreLoadSnapshot {
        let localCursorState = localRepository.flatMap { repository in
            try? repository.fetchCursorState()
        }
        let localWindowState = localRepository.flatMap { repository in
            try? repository.fetchWindowState()
        }
        let bridgeSnapshot = WorkspaceSQLiteStateBridge.Snapshot(
            workspace: authoritativeSnapshot.workspace,
            paneGraph: authoritativeSnapshot.paneGraph,
            tabShells: authoritativeSnapshot.tabShells,
            tabGraph: authoritativeSnapshot.tabGraph,
            cursorState: WorkspaceSQLiteStateBridge.localCursorStateForComposition(
                persisted: localCursorState,
                paneGraph: authoritativeSnapshot.paneGraph,
                tabGraph: authoritativeSnapshot.tabGraph
            ),
            windowState: localWindowState,
            drawerPresentationPreferences: drawerPresentationPreferencesForComposition(
                workspaceId: authoritativeSnapshot.workspace.id,
                paneGraph: authoritativeSnapshot.paneGraph,
                localRepository: localRepository
            )
        )
        let workspaceSnapshot = try WorkspaceSQLiteStateBridge.workspaceSnapshot(from: bridgeSnapshot)
        return WorkspaceCoreLoadSnapshot(
            workspace: workspaceSnapshot,
            repositoryTopology: WorkspaceSQLiteStateBridge.repositoryTopologySnapshot(
                topology: authoritativeSnapshot.topology,
                updatedAt: authoritativeSnapshot.workspace.updatedAt
            ),
            persistenceReasons: try WorkspaceSQLiteStateBridge.paneLocationRestoreReasons(
                from: bridgeSnapshot
            ),
            terminalSessionProtocolVersions: try coreRepository.terminalSessionProtocolVersions()
        )
    }
}
