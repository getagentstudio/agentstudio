import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorHardeningTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    let trustedBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    struct Harness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let runtime: SessionRuntime
        let coordinator: WorkspaceSurfaceCoordinator
        let surfaceManager: HardeningSurfaceManager
        let tempDir: URL
    }

    func makeHarness(
        createSurfaceResult: Result<ManagedSurface, SurfaceError> = .failure(.ghosttyNotInitialized)
    ) -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-hardening-\(UUIDv7.generate().uuidString)")
        let store: WorkspaceStore
        do { store = try makeWorkspaceJournalTestStore() } catch {
            preconditionFailure("Could not prepare the hardening harness SQLite store: \(error)")
        }
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let surfaceManager = HardeningSurfaceManager(createSurfaceResult: createSurfaceResult)
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        return Harness(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            coordinator: coordinator,
            surfaceManager: surfaceManager,
            tempDir: tempDir
        )
    }

    func withHardeningHarness(
        _ harness: Harness, operation: () async throws -> Void
    ) async throws {
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        do {
            try await operation()
        } catch {
            await harness.coordinator.shutdown()
            throw error
        }
        await harness.coordinator.shutdown()
    }

    func makeRepoAndWorktree(_ store: WorkspaceStore, root: URL) -> (Repo, Worktree) {
        let repoPath = root.appending(path: "repo-\(UUIDv7.generate().uuidString)")
        let worktreePath = repoPath.appending(path: "wt-main")
        try? FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)

        let repo = store.addRepo(at: repoPath)
        let worktree = Worktree(repoId: repo.id, name: "wt-main", path: worktreePath)
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [worktree])
        return (repo, worktree)
    }

    func makeWebviewPane(_ store: WorkspaceStore, title: String) -> Pane {
        let url = URL(string: "https://example.com/\(UUIDv7.generate().uuidString)")!
        return store.createPane(
            content: .webview(WebviewState(url: url, showNavigation: true)),
            metadata: PaneMetadata(title: title)
        )
    }

    func makeWorktreePane(
        _ store: WorkspaceStore,
        repo: Repo,
        worktree: Worktree,
        title: String
    ) -> Pane {
        store.createPane(
            launchDirectory: worktree.path,
            title: title,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
    }

    @Test("openTerminal keeps pane state and attempts geometry-gated creation when bounds exist")
    func openTerminal_keepsPaneStateWhenSurfaceCreationFails() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            guard let persistedRepo = harness.store.repo(repo.id) else {
                Issue.record("Expected repo to be persisted in WorkspaceStore")
                return
            }
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
            let openedPane = try await harness.coordinator.openTerminal(for: worktree, in: persistedRepo)

            #expect(openedPane != nil)
            #expect(harness.store.tabs.count == 1)
            #expect(harness.store.panes.count == 1)
            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
        }
    }

    @Test("closeTab tears down views for panes hidden by non-active arrangements")
    func closeTab_tearsDownAllOwnedPaneViews() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let paneA = makeWebviewPane(harness.store, title: "A")
            let paneB = makeWebviewPane(harness.store, title: "B")
            let paneC = makeWebviewPane(harness.store, title: "C")
            let tab = Tab(paneId: paneA.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                paneB.id,
                inTab: tab.id,
                at: paneA.id,
                direction: .horizontal,
                position: .after, sizingMode: .halveTarget
            )
            harness.store.insertPane(
                paneC.id,
                inTab: tab.id,
                at: paneB.id,
                direction: .horizontal,
                position: .after, sizingMode: .halveTarget
            )
            guard
                let focusArrangementId = harness.store.createArrangement(
                    name: "Focus AB",
                    inTab: tab.id
                )
            else {
                Issue.record("Expected arrangement creation to succeed")
                return
            }
            harness.store.switchArrangement(to: focusArrangementId, inTab: tab.id)

            harness.viewRegistry.register(PaneHostView(paneId: paneA.id), for: paneA.id)
            harness.viewRegistry.register(PaneHostView(paneId: paneB.id), for: paneB.id)
            harness.viewRegistry.register(PaneHostView(paneId: paneC.id), for: paneC.id)

            try await harness.coordinator.execute(.closeTab(tabId: tab.id))

            #expect(harness.store.tab(tab.id) == nil)
            #expect(harness.viewRegistry.registeredPaneIds.isEmpty)
            guard case .tab(let snapshot)? = harness.coordinator.undoStack.last else {
                Issue.record("Expected tab snapshot in undo stack")
                return
            }
            #expect(Set(snapshot.panes.map(\.id)) == Set([paneA.id, paneB.id, paneC.id]))
        }
    }

    @Test("purgeOrphanedPane only purges panes that are backgrounded")
    func purgeOrphanedPane_requiresBackgroundedResidency() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let pane = makeWebviewPane(harness.store, title: "Transient")
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.viewRegistry.register(PaneHostView(paneId: pane.id), for: pane.id)
            harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [pane.id])

            try await harness.coordinator.execute(.purgeOrphanedPane(paneId: pane.id))
            #expect(harness.store.pane(pane.id) != nil)
            #expect(harness.viewRegistry.view(for: pane.id) != nil)

            try await harness.coordinator.execute(.backgroundPane(paneId: pane.id))
            try await harness.coordinator.execute(.purgeOrphanedPane(paneId: pane.id))
            #expect(harness.store.pane(pane.id) == nil)
            #expect(harness.viewRegistry.view(for: pane.id) == nil)
            #expect(harness.viewRegistry.isRetiredForTesting(pane.id))
            #expect(harness.viewRegistry.peekSlotForTesting(pane.id) != nil)
        }
    }

    @Test("insertPane newTerminal keeps inserted pane state when terminal view creation fails")
    func insertPaneNewTerminal_keepsPaneStateOnSurfaceCreationFailure() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let targetPane = harness.store.createPane(
                launchDirectory: worktree.path,
                title: "Target",
                provider: .zmx,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
            )
            let tab = Tab(paneId: targetPane.id)
            harness.store.appendTab(tab)
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
            let initialPaneIds = Set(harness.store.panes.keys)

            try await harness.coordinator.execute(
                .insertPane(
                    source: .newTerminal,
                    targetTabId: tab.id,
                    targetPaneId: targetPane.id,
                    direction: .right,
                    sizingMode: .halveTarget
                )
            )

            #expect(Set(harness.store.panes.keys).count == initialPaneIds.count + 1)
            #expect(harness.store.tab(tab.id)?.paneIds.count == 2)
            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
        }
    }

    @Test("insertPane newTerminal resolves worktree context from floating target cwd before surface creation")
    func insertPaneNewTerminal_resolvesWorktreeContextFromFloatingCwd() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let targetPane = harness.store.createPane(
                launchDirectory: worktree.path.appending(path: "nested"),
                title: "Target",
                provider: .zmx,
                facets: PaneContextFacets(cwd: worktree.path.appending(path: "nested"))
            )
            let tab = Tab(paneId: targetPane.id)
            harness.store.appendTab(tab)
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
            let initialPaneIds = Set(harness.store.panes.keys)

            try await harness.coordinator.execute(
                .insertPane(
                    source: .newTerminal,
                    targetTabId: tab.id,
                    targetPaneId: targetPane.id,
                    direction: .right,
                    sizingMode: .halveTarget
                )
            )

            #expect(Set(harness.store.panes.keys).count == initialPaneIds.count + 1)
            #expect(harness.store.tab(tab.id)?.paneIds.count == 2)
            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
            #expect(harness.store.repo(repo.id) != nil)
            #expect(
                harness.surfaceManager.lastCreatedSurfaceMetadata?.cwd
                    == worktree.path.appending(path: "nested", directoryHint: .isDirectory))
        }
    }

    @Test("insertPane newTerminal falls back to floating context when target cwd does not map to a worktree")
    func insertPaneNewTerminal_fallsBackToFloatingContext() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let unknownCwd = harness.tempDir.appending(
                path: "outside-known-repos",
                directoryHint: .isDirectory
            )
            try? FileManager.default.createDirectory(at: unknownCwd, withIntermediateDirectories: true)
            let targetPane = harness.store.createPane(
                launchDirectory: unknownCwd,
                title: "Target",
                provider: .zmx,
                facets: PaneContextFacets(cwd: unknownCwd)
            )
            let tab = Tab(paneId: targetPane.id)
            harness.store.appendTab(tab)
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
            let initialPaneIds = Set(harness.store.panes.keys)

            try await harness.coordinator.execute(
                .insertPane(
                    source: .newTerminal,
                    targetTabId: tab.id,
                    targetPaneId: targetPane.id,
                    direction: .right,
                    sizingMode: .halveTarget
                )
            )

            #expect(Set(harness.store.panes.keys).count == initialPaneIds.count + 1)
            #expect(harness.store.tab(tab.id)?.paneIds.count == 2)
            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
            #expect(harness.surfaceManager.lastCreatedSurfaceMetadata?.cwd == unknownCwd)
        }
    }

    @Test("expandPane restores a missing visible terminal view when the minimized pane had no host")
    func expandPane_restoresMissingVisibleTerminalView() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let firstPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Visible")
            let secondPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Minimized")
            let tab = Tab(paneId: firstPane.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                secondPane.id,
                inTab: tab.id,
                at: firstPane.id,
                direction: .horizontal,
                position: .after, sizingMode: .halveTarget
            )
            _ = harness.store.minimizePane(secondPane.id, inTab: tab.id)

            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
            harness.coordinator.windowLifecycleStore.recordLaunchLayoutSettled()

            #expect(harness.viewRegistry.view(for: secondPane.id) == nil)

            try await harness.coordinator.execute(.expandPane(tabId: tab.id, paneId: secondPane.id))

            #expect(harness.viewRegistry.view(for: secondPane.id) != nil)
        }
    }

    @Test("reactivatePane keeps reactivated pane in canonical state if view creation fails")
    func reactivatePane_keepsCanonicalStateWhenViewCreationFails() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let targetPane = makeWebviewPane(harness.store, title: "Target")
            let tab = Tab(paneId: targetPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)

            let backgroundPane = harness.store.createPane(
                launchDirectory: worktree.path,
                title: "Background",
                provider: .ghostty,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
            )
            harness.store.setResidency(.backgrounded, for: backgroundPane.id)
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
            harness.coordinator.windowLifecycleStore.recordLaunchLayoutSettled()

            try await harness.coordinator.execute(
                .reactivatePane(
                    paneId: backgroundPane.id,
                    targetTabId: tab.id,
                    targetPaneId: targetPane.id,
                    direction: .right
                )
            )

            #expect(harness.store.pane(backgroundPane.id)?.residency == .active)
            #expect(harness.store.tab(tab.id)?.paneIds.contains(backgroundPane.id) == true)
            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
        }
    }

    @Test("addDrawerPane keeps drawer pane state when view creation fails")
    func addDrawerPane_keepsDrawerStateOnViewCreationFailure() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let parentPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Parent")
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let paneIdsBefore = Set(harness.store.panes.keys)
            try await harness.coordinator.execute(.addDrawerPane(parentPaneId: parentPane.id))

            #expect(Set(harness.store.panes.keys).count == paneIdsBefore.count + 1)
            #expect(harness.store.pane(parentPane.id)?.drawer?.paneIds.count == 1)
            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
        }
    }

    @Test("insertDrawerPane keeps drawer pane state when view creation fails")
    func insertDrawerPane_keepsDrawerStateOnViewCreationFailure() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let parentPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Parent")
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            guard let existingDrawerPane = harness.store.addDrawerPane(to: parentPane.id) else {
                Issue.record("Expected initial drawer pane creation")
                return
            }
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let paneIdsBefore = Set(harness.store.panes.keys)
            try await harness.coordinator.execute(
                .insertDrawerPane(
                    parentPaneId: parentPane.id,
                    targetDrawerPaneId: existingDrawerPane.id,
                    direction: .right,
                    sizingMode: .halveTarget
                )
            )

            #expect(Set(harness.store.panes.keys).count == paneIdsBefore.count + 1)
            #expect(harness.store.pane(parentPane.id)?.drawer?.paneIds.count == 2)
            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
        }
    }

}

@MainActor
final class HardeningSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    let createSurfaceResult: Result<ManagedSurface, SurfaceError>

    private(set) var createSurfaceCallCount = 0
    private(set) var lastCreatedSurfaceMetadata: SurfaceMetadata?
    var onCreateSurface: ((SurfaceMetadata) -> Void)?
    var onUndoClose: (() -> Void)?
    var undoCloseResult: ManagedSurface?

    init(
        createSurfaceResult: Result<ManagedSurface, SurfaceError>,
        undoCloseResult: ManagedSurface? = nil,
        onUndoClose: (() -> Void)? = nil
    ) {
        self.createSurfaceResult = createSurfaceResult
        self.undoCloseResult = undoCloseResult
        self.onUndoClose = onUndoClose
    }

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        createSurfaceCallCount += 1
        lastCreatedSurfaceMetadata = metadata
        onCreateSurface?(metadata)
        return createSurfaceResult
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? {
        onUndoClose?()
        guard undoCloseResult?.metadata.paneId == paneId else { return nil }
        return undoCloseResult
    }

    func destroy(_ surfaceId: UUID) {}
}

@MainActor
final class HardeningFocusableMountedContentView: NSView, PaneMountedContent {
    override var acceptsFirstResponder: Bool { true }

    func setContentInteractionEnabled(_: Bool) {}
}

final class HardeningFocusableResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
