import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

private struct WorkspaceActionExecutorHarness {
    let store: WorkspaceStore
    let viewRegistry: ViewRegistry
    let runtime: SessionRuntime
    let coordinator: WorkspaceSurfaceCoordinator
    let executor: WorkspaceActionExecutor
    let tempDir: URL
}

@MainActor
private func makeWorkspaceActionExecutorHarness() throws -> WorkspaceActionExecutorHarness {
    let tempDir = FileManager.default.temporaryDirectory
        .appending(path: "agentstudio-action-executor-tests-\(UUID().uuidString)")
    let store = try makeWorkspaceJournalTestStore()
    let viewRegistry = ViewRegistry()
    let runtime = SessionRuntime(store: store)
    let coordinator = {
        let fixtureSurfaceManager = makeAppTerminalFixtureSurfaceManager()
        return WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: fixtureSurfaceManager, terminalSurfaceCommandDispatcher: fixtureSurfaceManager,
            terminalSurfaceOperations: fixtureSurfaceManager.makeTerminalPaneSurfaceOperations(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
    }()
    let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
    return WorkspaceActionExecutorHarness(
        store: store,
        viewRegistry: viewRegistry,
        runtime: runtime,
        coordinator: coordinator,
        executor: executor,
        tempDir: tempDir
    )
}

@MainActor
private func assertFileViewPane(
    _ pane: Pane,
    repo: Repo,
    worktree: Worktree,
    store: WorkspaceStore,
    viewRegistry: ViewRegistry
) {
    #expect(pane.repoId == repo.id)
    #expect(pane.worktreeId == worktree.id)
    #expect(pane.metadata.cwd == worktree.path)
    #expect(pane.metadata.title == "Files")
    assertDurablePaneAssociation(pane.id, repo: repo, worktree: worktree, store: store)
    let bridgeView = viewRegistry.view(for: pane.id)?.mountedContentViewForTesting as? BridgePaneMountView
    #expect(bridgeView?.controller.runtime.metadata.worktreeId == worktree.id)
    #expect(bridgeView?.controller.runtime.metadata.repoId == repo.id)
    #expect(bridgeView?.controller.runtime.metadata.cwd == worktree.path)
    guard case .bridgePanel(let state) = pane.content,
        state.panelKind == .fileViewer,
        case .workspace(let rootPath, let comparisonIntent) = state.source
    else {
        Issue.record("Expected Bridge file-viewer workspace source")
        return
    }
    #expect(rootPath == worktree.path.path)
    #expect(
        comparisonIntent == nil
    )
    guard let script = bridgeView?.controller.bootstrapScriptSourceForTesting else {
        Issue.record("Expected mounted Bridge file-viewer bootstrap script")
        return
    }
    #expect(script.contains("const APP_PROTOCOL = \"worktree-file\""))
    #expect(script.contains("data-bridge-app-protocol"))
    #expect(!script.contains("data-bridge-worktree-file-source-spec"))
    #expect(!script.contains(repo.id.uuidString))
    #expect(!script.contains(worktree.id.uuidString))
    #expect(!script.contains(StableKey.fromPath(worktree.path)))
}

@MainActor
private func assertDurablePaneAssociation(
    _ paneId: UUID,
    repo: Repo,
    worktree: Worktree,
    store: WorkspaceStore
) {
    let facets = store.paneAtom.graphAtom.paneState(paneId)?.durableContextFacets
    #expect(facets?.repoId == repo.id)
    #expect(facets?.worktreeId == worktree.id)
    #expect(facets?.cwd?.standardizedFileURL == worktree.path.standardizedFileURL)
}

@MainActor
private func assertDurablyUnassociatedPane(_ paneId: UUID, store: WorkspaceStore) {
    let facets = store.paneAtom.graphAtom.paneState(paneId)?.durableContextFacets
    #expect(facets?.repoId == nil)
    #expect(facets?.worktreeId == nil)
}

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WorkspaceActionExecutorWebKitTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("openWebview creates a generic GitHub tab without workspace association")
        func openWebview_addsGenericGitHubTabAndRegistersView() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pane = executor.openWebview()

            #expect(pane != nil)
            #expect(store.tabs.count == 1)
            #expect(store.activeTabId == store.tabs[0].id)
            #expect(viewRegistry.view(for: pane!.id) != nil)
            #expect(viewRegistry.webviewView(for: pane!.id) != nil)
            #expect(pane?.webviewState?.url == URL(string: "https://github.com"))
            #expect(pane?.repoId == nil)
            #expect(pane?.worktreeId == nil)
            #expect(pane?.metadata.cwd == nil)
            assertDurablyUnassociatedPane(pane!.id, store: store)
        }

        @Test("openBridgeReviewInNewTab inherits active pane worktree context")
        func openBridgeReviewInNewTab_inheritsActivePaneWorktreeContext() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }
            let sourcePane = store.createPane(
                launchDirectory: worktree.path,
                title: "Source",
                facets: PaneContextFacets(
                    repoId: repo.id,
                    repoName: repo.name,
                    worktreeId: worktree.id,
                    worktreeName: worktree.name,
                    cwd: worktree.path
                )
            )
            let tab = Tab(paneId: sourcePane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)

            let pane = executor.openBridgeReviewInNewTab()

            #expect(pane != nil)
            #expect(store.tabs.count == 2)
            #expect(store.activeTabId == store.tabs[1].id)
            #expect(pane?.repoId == repo.id)
            #expect(pane?.worktreeId == worktree.id)
            #expect(pane?.metadata.cwd == worktree.path)
            assertDurablePaneAssociation(pane!.id, repo: repo, worktree: worktree, store: store)
            guard case .bridgePanel(let state) = pane?.content,
                case .workspace(let rootPath, let comparisonIntent) = state.source
            else {
                Issue.record("Expected Bridge workspace source")
                return
            }
            #expect(rootPath == worktree.path.path)
            #expect(
                comparisonIntent == nil
            )
        }

        @Test("openBridgeReviewInNewTab starts without a target when enrichment is unavailable")
        func openBridgeReviewInNewTab_startsWithoutTargetWhenEnrichmentIsUnavailable() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }

            let pane = executor.openBridgeReviewInNewTab()

            #expect(pane != nil)
            #expect(pane?.repoId == repo.id)
            #expect(pane?.worktreeId == worktree.id)
            #expect(pane?.metadata.cwd == worktree.path)
            assertDurablePaneAssociation(pane!.id, repo: repo, worktree: worktree, store: store)
            let bridgeView = viewRegistry.view(for: pane!.id)?.mountedContentViewForTesting as? BridgePaneMountView
            #expect(bridgeView?.controller.runtime.metadata.worktreeId == worktree.id)
            #expect(bridgeView?.controller.runtime.metadata.repoId == repo.id)
            #expect(bridgeView?.controller.runtime.metadata.cwd == worktree.path)
            guard case .bridgePanel(let state) = pane?.content,
                case .workspace(let rootPath, let comparisonIntent) = state.source
            else {
                Issue.record("Expected Bridge workspace source")
                return
            }
            #expect(rootPath == worktree.path.path)
            #expect(
                comparisonIntent == nil
            )
        }

        @Test("openBridgeReviewInNewTab does not persist the cached main-worktree branch")
        func openBridgeReviewInNewTab_doesNotPersistCachedMainWorktreeBranch() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }
            atom(\.repoCache).setWorktreeEnrichment(
                WorktreeEnrichment(worktreeId: worktree.id, repoId: repo.id, branch: "master")
            )
            defer { atom(\.repoCache).removeWorktree(worktree.id) }

            let pane = executor.openBridgeReviewInNewTab(worktreeId: worktree.id)

            guard case .bridgePanel(let state) = pane?.content,
                case .workspace(_, let comparisonIntent) = state.source
            else {
                Issue.record("Expected Bridge workspace source")
                return
            }
            #expect(
                comparisonIntent == nil
            )
        }

        @Test("openBridgeReviewInNewTab can target a registered worktree without an active source pane")
        func openBridgeReviewInNewTab_targetsRegisteredWorktree() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }

            let pane = executor.openBridgeReviewInNewTab(worktreeId: worktree.id)

            #expect(pane != nil)
            #expect(store.tabs.count == 1)
            #expect(store.activeTabId == store.tabs[0].id)
            #expect(pane?.repoId == repo.id)
            #expect(pane?.worktreeId == worktree.id)
            #expect(pane?.metadata.cwd == worktree.path)
            assertDurablePaneAssociation(pane!.id, repo: repo, worktree: worktree, store: store)
            let bridgeView = viewRegistry.view(for: pane!.id)?.mountedContentViewForTesting as? BridgePaneMountView
            #expect(bridgeView?.controller.runtime.metadata.worktreeId == worktree.id)
            #expect(bridgeView?.controller.runtime.metadata.repoId == repo.id)
            #expect(bridgeView?.controller.runtime.metadata.cwd == worktree.path)
            guard case .bridgePanel(let state) = pane?.content,
                case .workspace(let rootPath, let comparisonIntent) = state.source
            else {
                Issue.record("Expected Bridge workspace source")
                return
            }
            #expect(rootPath == worktree.path.path)
            #expect(
                comparisonIntent == nil
            )
        }

        @Test("openBridgeFilesInNewTab can target a registered worktree without an active source pane")
        func openBridgeFilesInNewTab_targetsRegisteredWorktree() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }

            let pane = executor.openBridgeFilesInNewTab(worktreeId: worktree.id)

            #expect(pane != nil)
            #expect(store.tabs.count == 1)
            #expect(store.activeTabId == store.tabs[0].id)
            #expect(pane?.repoId == repo.id)
            #expect(pane?.worktreeId == worktree.id)
            #expect(pane?.metadata.cwd == worktree.path)
            #expect(pane?.metadata.title == "Files")
            assertDurablePaneAssociation(pane!.id, repo: repo, worktree: worktree, store: store)
            let bridgeView = viewRegistry.view(for: pane!.id)?.mountedContentViewForTesting as? BridgePaneMountView
            #expect(bridgeView?.controller.runtime.metadata.worktreeId == worktree.id)
            #expect(bridgeView?.controller.runtime.metadata.repoId == repo.id)
            #expect(bridgeView?.controller.runtime.metadata.cwd == worktree.path)
            guard case .bridgePanel(let state) = pane?.content,
                state.panelKind == .fileViewer,
                case .workspace(let rootPath, let comparisonIntent) = state.source
            else {
                Issue.record("Expected Bridge file-viewer workspace source")
                return
            }
            #expect(rootPath == worktree.path.path)
            #expect(
                comparisonIntent == nil
            )
        }

        @Test("openBridgeFilesInNewTab inherits active pane worktree context")
        func openBridgeFilesInNewTab_inheritsActivePaneWorktreeContext() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            let worktree = try #require(
                store.repos.first(where: { $0.id == repo.id })?.worktrees.first,
                "Expected main worktree"
            )
            let sourcePane = store.createPane(
                launchDirectory: worktree.path,
                title: "Source",
                facets: PaneContextFacets(
                    repoId: repo.id,
                    repoName: repo.name,
                    worktreeId: worktree.id,
                    worktreeName: worktree.name,
                    cwd: worktree.path
                )
            )
            let tab = Tab(paneId: sourcePane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            _ = store.addRepo(
                at: tempDir.appending(path: "distracting-repo", directoryHint: .isDirectory)
            )

            let pane = try #require(executor.openBridgeFilesInNewTab())

            #expect(store.tabs.count == 2)
            #expect(store.activeTabId == store.tabs[1].id)
            assertFileViewPane(
                pane,
                repo: repo,
                worktree: worktree,
                store: store,
                viewRegistry: viewRegistry
            )
        }

        @Test("openBridgeFilesInNewTab falls back to the only registered worktree when no pane has context")
        func openBridgeFilesInNewTab_usesOnlyRegisteredWorktreeWithoutActivePaneContext() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            let worktree = try #require(
                store.repos.first(where: { $0.id == repo.id })?.worktrees.first,
                "Expected main worktree"
            )

            let pane = try #require(executor.openBridgeFilesInNewTab())

            assertFileViewPane(
                pane,
                repo: repo,
                worktree: worktree,
                store: store,
                viewRegistry: viewRegistry
            )
        }

        @Test("openBridgeFilesInNewTab keeps source identity out of the page bootstrap")
        func openBridgeFilesInNewTab_keepsSourceIdentityOutOfPageBootstrap() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            let worktree = try #require(
                store.repos.first(where: { $0.id == repo.id })?.worktrees.first,
                "Expected main worktree"
            )

            let pane = try #require(executor.openBridgeFilesInNewTab(worktreeId: worktree.id))
            let bridgeView = try #require(
                viewRegistry.view(for: pane.id)?.mountedContentViewForTesting as? BridgePaneMountView,
                "Expected mounted Bridge file-viewer view"
            )
            let script = bridgeView.controller.bootstrapScriptSourceForTesting

            #expect(script.contains("const APP_PROTOCOL = \"worktree-file\""))
            #expect(script.contains("data-bridge-app-protocol"))
            #expect(!script.contains("data-bridge-worktree-file-source-spec"))
            #expect(!script.contains(repo.id.uuidString))
            #expect(!script.contains(worktree.id.uuidString))
            #expect(!script.contains(StableKey.fromPath(worktree.path)))
        }

        @Test("typed webview insertion creates a split browser pane with inherited workspace association")
        func typedWebviewInsertionAddsSplitPaneWithAssociation() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(
                at: tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }

            let sourcePane = store.createPane(
                launchDirectory: worktree.path,
                title: "Source",
                facets: PaneContextFacets(
                    repoId: repo.id,
                    repoName: repo.name,
                    worktreeId: worktree.id,
                    worktreeName: worktree.name,
                    cwd: worktree.path
                )
            )
            let tab = Tab(paneId: sourcePane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            let untouchedArrangementID = try #require(
                store.createArrangement(name: "Untouched", inTab: tab.id)
            )
            let activeArrangementID = try #require(
                store.createArrangement(name: "Active", inTab: tab.id)
            )
            let untouchedBeforeCreation = try #require(
                store.tab(tab.id)?.arrangements.first { $0.id == untouchedArrangementID }
            )
            let paneIdsBefore = store.paneAtom.graphAtom.paneIDs
            let url = URL(string: "https://github.com/ShravanSunder/agentstudio/pulls")!

            let didExecute = await executor.execute(
                .insertPane(
                    source: .newWebview(WebviewState(url: url)),
                    targetTabId: tab.id,
                    targetPaneId: sourcePane.id,
                    direction: .right,
                    sizingMode: .halveTarget
                )
            )
            let createdPaneIds = store.paneAtom.graphAtom.paneIDs.subtracting(paneIdsBefore)
            #expect(createdPaneIds.count == 1)
            let createdPaneId = try #require(createdPaneIds.first)
            let pane = try #require(store.pane(createdPaneId))

            #expect(didExecute)
            #expect(store.tab(tab.id)?.paneIds.count == 2)
            #expect(store.tab(tab.id)?.activePaneId == pane.id)
            let updatedTab = try #require(store.tab(tab.id))
            #expect(updatedTab.defaultArrangement.layout.contains(pane.id))
            #expect(updatedTab.arrangements.first { $0.id == activeArrangementID }?.layout.contains(pane.id) == true)
            #expect(updatedTab.arrangements.first { $0.id == untouchedArrangementID } == untouchedBeforeCreation)
            #expect(pane.webviewState?.url == url)
            #expect(pane.repoId == repo.id)
            #expect(pane.worktreeId == worktree.id)
            #expect(pane.metadata.cwd == worktree.path)
            assertDurablePaneAssociation(pane.id, repo: repo, worktree: worktree, store: store)
        }

        @Test("typed webview drawer insertion inherits the parent workspace association")
        func typedWebviewDrawerInsertionPersistsAssociation() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let coordinator = harness.coordinator
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let repo = store.addRepo(
                at: harness.tempDir.appending(path: "repo", directoryHint: .isDirectory)
            )
            let worktree = try #require(
                store.repos.first(where: { $0.id == repo.id })?.worktrees.first,
                "Expected main worktree"
            )
            let parentPane = store.createPane(
                launchDirectory: worktree.path,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
            )
            let tab = Tab(paneId: parentPane.id)
            store.appendTab(tab)
            let untouchedArrangementID = try #require(
                store.createArrangement(name: "Untouched", inTab: tab.id)
            )
            let activeArrangementID = try #require(
                store.createArrangement(name: "Active", inTab: tab.id)
            )
            let untouchedBeforeCreation = try #require(
                store.tab(tab.id)?.arrangements.first { $0.id == untouchedArrangementID }
            )
            let paneIdsBefore = store.paneAtom.graphAtom.paneIDs

            coordinator.executeAddWebviewDrawerPane(
                parentPaneId: parentPane.id,
                state: WebviewState(url: URL(string: "https://github.com/example/project")!)
            )

            let drawerPaneId = try #require(
                store.paneAtom.graphAtom.paneIDs.subtracting(paneIdsBefore).first
            )
            #expect(store.pane(parentPane.id)?.drawer?.paneIds.contains(drawerPaneId) == true)
            let updatedTab = try #require(store.tab(tab.id))
            let drawerID = try #require(store.pane(parentPane.id)?.drawer?.drawerId)
            #expect(updatedTab.defaultArrangement.drawerViews[drawerID]?.layout.contains(drawerPaneId) == true)
            #expect(
                updatedTab.arrangements.first { $0.id == activeArrangementID }?
                    .drawerViews[drawerID]?.layout.contains(drawerPaneId) == true
            )
            #expect(updatedTab.arrangements.first { $0.id == untouchedArrangementID } == untouchedBeforeCreation)
            assertDurablePaneAssociation(drawerPaneId, repo: repo, worktree: worktree, store: store)
        }

        @Test("failed webview layout insertion tears down its mounted host and runtime")
        func failedWebviewLayoutInsertionTearsDownMountedResources() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }

            let sourcePane = store.createPane()
            let sourceTab = Tab(paneId: sourcePane.id)
            store.appendTab(sourceTab)
            let paneIdsBeforeInsertion = store.paneAtom.graphAtom.paneIDs
            let slotPaneIdsBeforeInsertion = viewRegistry.slotPaneIdsForTesting
            let runtimeCountBeforeInsertion = coordinator.runtimeRegistry.count

            try await coordinator.executeInsertPane(
                source: .newWebview(
                    WebviewState(url: URL(string: "https://example.com/failed-layout-insertion")!)
                ),
                targetTabId: UUID(),
                targetPaneId: sourcePane.id,
                direction: .right,
                sizingMode: .halveTarget
            )

            #expect(store.paneAtom.graphAtom.paneIDs == paneIdsBeforeInsertion)
            #expect(viewRegistry.slotPaneIdsForTesting == slotPaneIdsBeforeInsertion)
            #expect(coordinator.runtimeRegistry.count == runtimeCountBeforeInsertion)
        }

        @Test("failed webview drawer calibration tears down its mounted host and runtime")
        func failedWebviewDrawerCalibrationTearsDownMountedResources() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }

            let parentPane = store.createPane()
            let paneIdsBeforeInsertion = store.paneAtom.graphAtom.paneIDs
            let slotPaneIdsBeforeInsertion = viewRegistry.slotPaneIdsForTesting
            let runtimeCountBeforeInsertion = coordinator.runtimeRegistry.count

            coordinator.executeAddWebviewDrawerPane(
                parentPaneId: parentPane.id,
                state: WebviewState(url: URL(string: "https://example.com/failed-drawer-calibration")!)
            )

            #expect(store.paneAtom.graphAtom.paneIDs == paneIdsBeforeInsertion)
            #expect(store.paneAtom.pane(parentPane.id)?.drawer?.paneIds.isEmpty == true)
            #expect(viewRegistry.slotPaneIdsForTesting == slotPaneIdsBeforeInsertion)
            #expect(coordinator.runtimeRegistry.count == runtimeCountBeforeInsertion)
        }

        @Test("repair recreateSurface replaces a missing webview view")
        func repair_recreateSurface_recreatesWebviewView() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pane = store.createPane(
                content: .webview(WebviewState(url: URL(string: "about:blank")!)),
                metadata: PaneMetadata()
            )
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)

            _ = coordinator.createViewForContent(pane: pane)
            guard let beforeView = viewRegistry.view(for: pane.id) else {
                Issue.record("Expected webview view to exist before repair")
                return
            }

            viewRegistry.unregister(pane.id)

            await executor.execute(.repair(.recreateSurface(paneId: pane.id)))

            let afterView = viewRegistry.view(for: pane.id)
            #expect(afterView != nil)
            #expect(afterView !== beforeView)
        }

        @Test("expandPane does not restore unrelated missing visible views")
        func expandPane_doesNotInvokeVisibleViewRestoreSweep() async throws {
            let harness = try makeWorkspaceActionExecutorHarness()
            let store = harness.store
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            let executor = harness.executor
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            coordinator.windowLifecycleStore.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 1000, height: 600))
            coordinator.windowLifecycleStore.recordLaunchLayoutSettled()

            let paneOne = store.createPane(
                content: .webview(WebviewState(url: URL(string: "https://example.com/one")!)),
                metadata: PaneMetadata(title: "One")
            )
            let paneTwo = store.createPane(
                content: .webview(WebviewState(url: URL(string: "https://example.com/two")!)),
                metadata: PaneMetadata(title: "Two")
            )
            let tab = Tab(paneId: paneOne.id)
            store.appendTab(tab)
            store.insertPane(
                paneTwo.id,
                inTab: tab.id,
                at: paneOne.id,
                direction: .horizontal,
                position: .after, sizingMode: .halveTarget
            )

            _ = coordinator.createViewForContent(
                pane: paneOne,
                initialFrame: CGRect(x: 0, y: 0, width: 500, height: 600)
            )
            #expect(viewRegistry.view(for: paneOne.id) != nil)
            #expect(viewRegistry.view(for: paneTwo.id) == nil)

            await executor.execute(.minimizePane(tabId: tab.id, paneId: paneOne.id))
            await executor.execute(.expandPane(tabId: tab.id, paneId: paneOne.id))

            #expect(viewRegistry.view(for: paneTwo.id) == nil)
        }

    }

}

@MainActor
@Suite
struct WorkspaceActionExecutorTestsQuick {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("openBridgeReviewInNewTab without a worktree context does not create a blank Bridge tab")
    func openBridgeReviewInNewTab_withoutWorktreeContextDoesNotCreateBlankBridgeTab() async throws {
        let harness = try makeWorkspaceActionExecutorHarness()
        let store = harness.store
        let viewRegistry = harness.viewRegistry
        let executor = harness.executor
        let tempDir = harness.tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pane = executor.openBridgeReviewInNewTab()

        #expect(pane == nil)
        #expect(store.tabs.isEmpty)
        #expect(store.activeTabId == nil)
        #expect(viewRegistry.allBridgeViews.isEmpty)
    }

    @Test("minimizePane hides pane and expandPane restores active pane")
    func minimize_then_expandPane_updatesTransientState() async throws {
        let harness = try makeWorkspaceActionExecutorHarness()
        let store = harness.store
        let executor = harness.executor
        let tempDir = harness.tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paneOne = store.createPane()
        let paneTwo = store.createPane()
        let tab = Tab(paneId: paneOne.id)
        store.appendTab(tab)
        store.insertPane(
            paneTwo.id,
            inTab: tab.id,
            at: paneOne.id,
            direction: .horizontal,
            position: .after, sizingMode: .halveTarget
        )

        await executor.execute(.minimizePane(tabId: tab.id, paneId: paneOne.id))
        guard let minimized = store.tab(tab.id) else {
            Issue.record("Expected tab \(tab.id) after minimizing pane")
            return
        }
        #expect(minimized.activeMinimizedPaneIds == Set([paneOne.id]))
        #expect(minimized.activePaneId == paneTwo.id)

        await executor.execute(.expandPane(tabId: tab.id, paneId: paneOne.id))
        guard let expanded = store.tab(tab.id) else {
            Issue.record("Expected tab \(tab.id) after expanding pane")
            return
        }
        #expect(expanded.activeMinimizedPaneIds == Set<UUID>())
        #expect(expanded.activePaneId == paneOne.id)
    }
}
