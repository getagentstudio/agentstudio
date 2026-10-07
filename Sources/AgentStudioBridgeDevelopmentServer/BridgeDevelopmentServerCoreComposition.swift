import AgentStudioBridge
import AgentStudioCore
import Foundation

enum BridgeDevelopmentServerCoreCompositionError: Error, Equatable {
    case databasePreparationFailed
    case paneIsNotBridge
    case paneIsNotWorkspaceBacked
    case paneMissingAfterSeed
    case repositoryMissing
    case restoredWorktreeDoesNotMatchSeed
    case topologyFlushFailed
    case topologyIdentityMissing
    case workspaceLoadFailed
    case workspaceFlushFailed
}

@MainActor
final class BridgeDevelopmentServerCoreComposition {
    let productSource: BridgeDevelopmentProductSource
    let worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor
    let worktreeAnnotationStore: WorktreeAnnotationServiceActor

    package let paneContextMembershipDirectory: PaneContextMembershipDirectory

    private let atoms: CoreAtoms
    private let repositoryTopologyStore: RepositoryTopologyStore
    private let workspaceStore: WorkspaceStore
    private var isShutdown = false

    private init(
        atoms: CoreAtoms,
        productSource: BridgeDevelopmentProductSource,
        repositoryTopologyStore: RepositoryTopologyStore,
        workspaceStore: WorkspaceStore,
        worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor,
        worktreeAnnotationStore: WorktreeAnnotationServiceActor
    ) {
        self.atoms = atoms
        self.paneContextMembershipDirectory = atoms.workspacePaneGraph.paneContextMembershipDirectory
        self.productSource = productSource
        self.repositoryTopologyStore = repositoryTopologyStore
        self.workspaceStore = workspaceStore
        self.worktreeAnnotationOutputCoordinator = worktreeAnnotationOutputCoordinator
        self.worktreeAnnotationStore = worktreeAnnotationStore
    }

    static func prepare(
        configuration: BridgeDevelopmentServerConfiguration
    ) async throws -> BridgeDevelopmentServerCoreComposition {
        try FileManager.default.createDirectory(
            at: configuration.dataRoot,
            withIntermediateDirectories: true
        )
        let datastore = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: configuration.dataRoot.appending(path: "core.sqlite"),
            localDatabaseURL: configuration.dataRoot.appending(path: "local.sqlite"),
            localDatabaseReplacementObserver: WorktreeAnnotationRecoveryWitnessWriter.write
        ).makeDatastore()
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            throw BridgeDevelopmentServerCoreCompositionError.databasePreparationFailed
        }

        let atoms = CoreAtoms()
        let workspaceStore = WorkspaceStore(
            identityAtom: atoms.workspaceIdentity,
            windowMemoryAtom: atoms.workspaceWindowMemory,
            repositoryTopologyAtom: atoms.workspaceRepositoryTopology,
            paneAtom: atoms.workspacePane,
            tabLayoutAtom: atoms.workspaceTabLayout,
            mutationCoordinator: atoms.workspaceMutationCoordinator,
            sqliteDatastore: datastore
        )
        switch await workspaceStore.loadCanonicalComposition() {
        case .loaded, .initializedDefaultWorkspace:
            break
        case .failed:
            throw BridgeDevelopmentServerCoreCompositionError.workspaceLoadFailed
        }
        let repositoryTopologyStore = RepositoryTopologyStore(
            atom: atoms.workspaceRepositoryTopology,
            sqliteDatastore: datastore
        )

        if atoms.workspacePane.pane(configuration.paneID) == nil {
            let worktree = atoms.workspaceMutationCoordinator.ensureMainWorktree(
                at: configuration.seedWorktreeRoot
            )
            guard let repository = atoms.workspaceRepositoryTopology.repo(worktree.repoId) else {
                throw BridgeDevelopmentServerCoreCompositionError.repositoryMissing
            }
            let paneState = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: worktree.path.path,
                    baseline: WorkspaceBaseline(
                        contributionTarget: configuration.seedContributionTarget
                    )
                )
            )
            atoms.workspacePane.addPane(
                Pane(
                    id: configuration.paneID,
                    content: .bridgePanel(paneState),
                    metadata: PaneMetadata(
                        paneId: PaneId(existingUUID: configuration.paneID),
                        contentType: .diff,
                        launchDirectory: worktree.path,
                        title: "Bridge development review",
                        facets: PaneContextFacets(
                            repoId: repository.id,
                            repoName: repository.name,
                            worktreeId: worktree.id,
                            worktreeName: worktree.name,
                            cwd: worktree.path
                        )
                    )
                )
            )
            atoms.workspaceTabLayout.appendTab(
                Tab(paneId: configuration.paneID, name: "Bridge development review")
            )
            guard await workspaceStore.flushAsync() == .persisted else {
                throw BridgeDevelopmentServerCoreCompositionError.workspaceFlushFailed
            }
            do {
                try await repositoryTopologyStore.flushAsync()
            } catch {
                throw BridgeDevelopmentServerCoreCompositionError.topologyFlushFailed
            }
        }

        let productSource = try restoredProductSource(
            atoms: atoms,
            configuration: configuration
        )
        let annotationOwners = await makeAnnotationOwners(
            workspaceStore: workspaceStore,
            datastore: datastore,
            dataRoot: configuration.dataRoot
        )
        workspaceStore.startObserving()
        repositoryTopologyStore.startObserving()
        return BridgeDevelopmentServerCoreComposition(
            atoms: atoms,
            productSource: productSource,
            repositoryTopologyStore: repositoryTopologyStore,
            workspaceStore: workspaceStore,
            worktreeAnnotationOutputCoordinator: annotationOwners.outputCoordinator,
            worktreeAnnotationStore: annotationOwners.store
        )
    }

    private static func makeAnnotationOwners(
        workspaceStore: WorkspaceStore,
        datastore: WorkspaceSQLiteDatastoreActor,
        dataRoot: URL
    ) async -> (store: WorktreeAnnotationServiceActor, outputCoordinator: WorktreeAnnotationOutputCoordinatorActor) {
        let store = WorktreeAnnotationServiceActor(
            sqliteAdapter: WorktreeAnnotationSQLiteDatastoreAdapter(
                workspaceID: workspaceStore.identityAtom.workspaceId,
                datastore: datastore
            )
        )
        let outputCoordinator = WorktreeAnnotationOutputCoordinatorActor(
            store: store,
            effect: BridgeDevelopmentWorktreeAnnotationOutputEffect(dataRoot: dataRoot)
        )
        _ = await store.restoreRecoveryState()
        return (store, outputCoordinator)
    }

    func applyContributionTarget(
        _ target: WorkspaceReviewContributionTarget
    ) -> BridgePaneStateMutationResult {
        atoms.workspacePane.setBridgeContributionTarget(productSource.paneID, target: target)
    }

    func shutdown() async throws {
        guard !isShutdown else { return }
        isShutdown = true
        guard await workspaceStore.flushAsync() == .persisted else {
            throw BridgeDevelopmentServerCoreCompositionError.workspaceFlushFailed
        }
        do {
            try await repositoryTopologyStore.flushAsync()
        } catch {
            throw BridgeDevelopmentServerCoreCompositionError.topologyFlushFailed
        }
    }

    private static func restoredProductSource(
        atoms: CoreAtoms,
        configuration: BridgeDevelopmentServerConfiguration
    ) throws -> BridgeDevelopmentProductSource {
        guard let pane = atoms.workspacePane.pane(configuration.paneID) else {
            throw BridgeDevelopmentServerCoreCompositionError.paneMissingAfterSeed
        }
        guard case .bridgePanel(let paneState) = pane.content else {
            throw BridgeDevelopmentServerCoreCompositionError.paneIsNotBridge
        }
        guard case .workspace(let rootPath, _)? = paneState.source else {
            throw BridgeDevelopmentServerCoreCompositionError.paneIsNotWorkspaceBacked
        }
        guard let repoID = pane.metadata.repoId,
            let worktreeID = pane.metadata.worktreeId,
            let repository = atoms.workspaceRepositoryTopology.repo(repoID),
            let worktree = atoms.workspaceRepositoryTopology.worktree(worktreeID),
            worktree.repoId == repository.id
        else {
            throw BridgeDevelopmentServerCoreCompositionError.topologyIdentityMissing
        }
        let restoredRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        let topologyRoot = worktree.path.standardizedFileURL.resolvingSymlinksInPath()
        guard restoredRoot.path == topologyRoot.path,
            topologyRoot.path == configuration.seedWorktreeRoot.path
        else {
            throw BridgeDevelopmentServerCoreCompositionError.restoredWorktreeDoesNotMatchSeed
        }
        return BridgeDevelopmentProductSource(
            paneID: pane.id,
            paneState: paneState,
            repoID: repository.id,
            reviewedSubjectLabel: pane.metadata.worktreeName ?? pane.metadata.checkoutRef,
            worktreeID: worktree.id,
            worktreeRoot: topologyRoot
        )
    }
}
