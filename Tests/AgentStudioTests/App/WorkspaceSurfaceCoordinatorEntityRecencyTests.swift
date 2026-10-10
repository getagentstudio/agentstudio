import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("WorkspaceSurfaceCoordinator EntityRecency", .serialized)
struct WorkspaceSurfaceCoordinatorEntityRecencyTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("successful worktree open records repository and worktree with one timestamp")
    func successfulWorktreeOpen_recordsCoherentApplicationRecency() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: coreAtoms.workspaceIdentity.workspaceId)
            let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                windowMemoryAtom: coreAtoms.workspaceWindowMemory,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
                paneAtom: coreAtoms.workspacePane,
                tabLayoutAtom: coreAtoms.workspaceTabLayout,
                mutationCoordinator: coreAtoms.workspaceMutationCoordinator,
                sqliteDatastore: datastore
            )
            let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/entity-recency-repo"))
            let worktree = try #require(store.repo(repo.id)?.worktrees.first)
            let coordinator = {
                let fixtureSurfaceManager = makeAppTerminalFixtureSurfaceManager()
                return WorkspaceSurfaceCoordinator(
                    store: store,
                    viewRegistry: ViewRegistry(),
                    runtime: SessionRuntime(store: store),
                    surfaceManager: fixtureSurfaceManager, terminalSurfaceCommandDispatcher: fixtureSurfaceManager,
                    terminalSurfaceOperations: fixtureSurfaceManager.makeTerminalPaneSurfaceOperations(),
                    runtimeRegistry: RuntimeRegistry(),
                    windowLifecycleStore: coreAtoms.windowLifecycle,
                    ipcLifecycle: .testUnavailable,
                    bridgePaneAttendance: BridgePaneAttendanceAtom()
                )
            }()

            let openedPane = try await coordinator.openTerminal(for: worktree, in: repo)

            #expect(openedPane != nil)
            let repositoryRecency = try #require(
                coreAtoms.applicationEntityRecency.recentEntities.first {
                    $0.entity == .repository(repositoryStableKey: repo.stableKey)
                }
            )
            let worktreeRecency = try #require(
                coreAtoms.applicationEntityRecency.recentEntities.first {
                    $0.entity == .worktree(worktreeStableKey: worktree.stableKey)
                }
            )
            #expect(repositoryRecency.interaction == .opened)
            #expect(worktreeRecency.interaction == .opened)
            #expect(repositoryRecency.lastInteractedAt == worktreeRecency.lastInteractedAt)
            await coordinator.shutdown()
        }
    }

    @Test("rejected unknown worktree action records no application recency")
    func rejectedUnknownWorktreeAction_recordsNothing() async throws {
        await withAsyncTestCoreAtoms { coreAtoms in
            let store = makeStore(coreAtoms: coreAtoms)
            let coordinator = {
                let fixtureSurfaceManager = makeAppTerminalFixtureSurfaceManager()
                return WorkspaceSurfaceCoordinator(
                    store: store,
                    viewRegistry: ViewRegistry(),
                    runtime: SessionRuntime(store: store),
                    surfaceManager: fixtureSurfaceManager, terminalSurfaceCommandDispatcher: fixtureSurfaceManager,
                    terminalSurfaceOperations: fixtureSurfaceManager.makeTerminalPaneSurfaceOperations(),
                    runtimeRegistry: RuntimeRegistry(),
                    windowLifecycleStore: coreAtoms.windowLifecycle,
                    ipcLifecycle: .testUnavailable,
                    bridgePaneAttendance: BridgePaneAttendanceAtom()
                )
            }()
            let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)

            let accepted = await executor.execute(.openWorktree(worktreeId: UUID()))

            #expect(!accepted)
            #expect(coreAtoms.applicationEntityRecency.recentEntities.isEmpty)
        }
    }

    @Test("failed split insertion records no application recency")
    func failedSplitInsertion_recordsNothing() async throws {
        try await withAsyncTestCoreAtoms { coreAtoms in
            let store = makeStore(coreAtoms: coreAtoms)
            let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/entity-recency-split-failure"))
            let worktree = try #require(store.repo(repo.id)?.worktrees.first)
            let targetPane = store.createPane(title: "Target")
            let tab = Tab(paneId: targetPane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            let arrangementID = try #require(store.tab(tab.id)?.activeArrangementId)
            store.arrangementCursorAtom.replaceCursors(
                activeArrangementIdsByTabId: [tab.id: arrangementID],
                paneCursorsByArrangementId: [
                    arrangementID: ArrangementPaneCursorState(activePaneId: UUID())
                ],
                drawerCursorsByKey: [:]
            )
            let coordinator = {
                let fixtureSurfaceManager = makeAppTerminalFixtureSurfaceManager()
                return WorkspaceSurfaceCoordinator(
                    store: store,
                    viewRegistry: ViewRegistry(),
                    runtime: SessionRuntime(store: store),
                    surfaceManager: fixtureSurfaceManager, terminalSurfaceCommandDispatcher: fixtureSurfaceManager,
                    terminalSurfaceOperations: fixtureSurfaceManager.makeTerminalPaneSurfaceOperations(),
                    runtimeRegistry: RuntimeRegistry(),
                    windowLifecycleStore: coreAtoms.windowLifecycle,
                    ipcLifecycle: .testUnavailable,
                    bridgePaneAttendance: BridgePaneAttendanceAtom()
                )
            }()
            let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)

            let accepted = await executor.execute(.openWorktreeInPane(worktreeId: worktree.id))

            #expect(accepted)
            #expect(store.panes.count == 1)
            #expect(coreAtoms.applicationEntityRecency.recentEntities.isEmpty)
        }
    }

    private func makeStore(coreAtoms: CoreAtoms) -> WorkspaceStore {
        WorkspaceStore(
            identityAtom: coreAtoms.workspaceIdentity,
            windowMemoryAtom: coreAtoms.workspaceWindowMemory,
            repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
            paneAtom: coreAtoms.workspacePane,
            tabLayoutAtom: coreAtoms.workspaceTabLayout,
            mutationCoordinator: coreAtoms.workspaceMutationCoordinator
        )
    }
}
