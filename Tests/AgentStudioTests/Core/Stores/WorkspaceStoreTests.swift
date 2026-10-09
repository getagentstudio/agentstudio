import AgentStudioTestSupport
import Foundation
// swiftlint:disable file_length type_body_length
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@MainActor
@Suite(.serialized)
final class WorkspaceStoreTests {

    private var store: WorkspaceStore!
    private var tempDir: URL!
    private var sqliteDatastore: WorkspaceSQLiteDatastoreActor!

    init() {
        // Use a temp directory to avoid polluting real workspace data
        let testSQLiteRoot = FileManager.default.temporaryDirectory
            .appending(path: "workspace-store-tests-\(UUID().uuidString)")
        tempDir = testSQLiteRoot
        sqliteDatastore = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: testSQLiteRoot.appending(path: "core.sqlite"),
            localDatabaseURL: testSQLiteRoot.appending(path: "local.sqlite")
        ).makeDatastore()
        store = WorkspaceStore(sqliteDatastore: sqliteDatastore)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        sqliteDatastore = nil
    }

    private func prepareSharedDatastoreForBoot() async {
        guard case .prepared = await sqliteDatastore.prepareDatabasesForBoot() else {
            Issue.record("expected workspace-store test databases to prepare")
            return
        }
    }

    // MARK: - Initialization

    @Test

    func test_init_hasExplicitEmptyState() {
        // Assert
        #expect(store.panes.isEmpty)
        #expect(store.repos.isEmpty)
        #expect(store.tabs.isEmpty)
        #expect((store.activeTabId) == nil)
    }

    @Test
    func persistenceObservationArmsExplicitlyAndIdempotently() async {
        let unarmedStore = WorkspaceStore(
            startsObserving: false
        )
        unarmedStore.identityAtom.replaceIdentity(
            workspaceId: UUIDv7.generate(),
            workspaceName: "Installed Composition",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(!unarmedStore.isAutosaveObservationActive)
        #expect(!unarmedStore.isDirty)

        unarmedStore.startObserving()
        unarmedStore.startObserving()
        unarmedStore.identityAtom.setWorkspaceName("User Rename")

        #expect(unarmedStore.isAutosaveObservationActive)
        #expect(unarmedStore.isDirty)
    }

    @Test
    func test_workspaceStore_exposesResolvedTabWriteOwners() {
        let tabCursorAtom = WorkspaceTabCursorAtom()
        let tabShellAtom = WorkspaceTabShellAtom(cursorAtom: tabCursorAtom)
        let tabGraphAtom = WorkspaceTabGraphAtom()
        let arrangementCursorAtom = WorkspaceArrangementCursorAtom()
        let panePresentationAtom = WorkspacePanePresentationAtom()
        let tabArrangementAtom = WorkspaceTabArrangementAtom(
            graphAtom: tabGraphAtom,
            cursorAtom: arrangementCursorAtom,
            presentationAtom: panePresentationAtom
        )
        let tabLayoutAtom = WorkspaceTabLayoutAtom(
            shellAtom: tabShellAtom,
            arrangementAtom: tabArrangementAtom
        )

        let store = WorkspaceStore(
            tabLayoutAtom: tabLayoutAtom)

        #expect(store.tabShellAtom === tabShellAtom)
        #expect(store.tabCursorAtom === tabCursorAtom)
        #expect(store.tabArrangementAtom === tabArrangementAtom)
        #expect(store.tabGraphAtom === tabGraphAtom)
        #expect(store.arrangementCursorAtom === arrangementCursorAtom)
        #expect(store.panePresentationAtom === panePresentationAtom)
    }

    // MARK: - Pane CRUD

    @Test

    func test_createPane_addsToPanes() {
        // Act
        let pane = store.createPane()

        // Assert
        #expect(store.panes.count == 1)
        #expect((store.pane(pane.id)) != nil)
        #expect(store.pane(pane.id)?.provider == .zmx)
    }

    @Test

    func test_createPane_worktreeSource() {
        // Arrange
        let launchDirectory = URL(fileURLWithPath: "/tmp/worktree")
        let repo = store.addRepo(at: launchDirectory)
        let worktree = repo.worktrees[0]

        // Act
        let pane = store.createPane(
            launchDirectory: launchDirectory,
            title: "Feature",
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: launchDirectory)
        )

        // Assert
        #expect(pane.worktreeId == worktree.id)
        #expect(pane.repoId == repo.id)
        #expect(pane.title == "Feature")
    }

    @Test
    func updatePaneLiveLocation_resolvesKnownWorktreeAndPreservesLaunchSource() {
        let repo = store.addRepo(at: URL(filePath: "/tmp/live-identity-repo"))
        let main = Worktree(
            repoId: repo.id,
            name: "main",
            path: URL(filePath: "/tmp/live-identity-repo"),
            isMainWorktree: true
        )
        let feature = Worktree(
            repoId: repo.id,
            name: "feature",
            path: URL(filePath: "/tmp/live-identity-repo-feature")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [main, feature])

        let pane = store.createPane(
            launchDirectory: main.path,
            title: "Terminal",
            facets: PaneContextFacets(repoId: repo.id, worktreeId: main.id, cwd: main.path)
        )

        let cwd = URL(
            filePath: feature.path.appending(path: "Sources").path,
            directoryHint: .isDirectory
        )
        let result = store.paneAtom.updatePaneCWDAndResolvedContext(
            pane.id,
            cwd: cwd,
            resolvedContext: store.repositoryTopologyAtom.repoAndWorktree(containing: cwd)
        )
        #expect(result == .applied)

        let updated = store.pane(pane.id)
        #expect(updated?.metadata.cwd == cwd)
        #expect(updated?.repoId == repo.id)
        #expect(updated?.worktreeId == feature.id)
        #expect(updated?.metadata.repoName == repo.name)
        #expect(updated?.metadata.worktreeName == "feature")

        #expect(
            updated?.metadata.launchDirectory
                == URL(filePath: main.path.path, directoryHint: .isDirectory)
        )
    }

    @Test
    func updatePaneLiveLocation_clearsLiveRepoAndWorktreeWhenCwdLeavesKnownWorktrees() async throws {
        await prepareSharedDatastoreForBoot()
        _ = await store.loadCanonicalComposition()

        let repo = store.addRepo(at: URL(filePath: "/tmp/live-clear-repo"))
        let main = Worktree(
            repoId: repo.id,
            name: "main",
            path: URL(filePath: "/tmp/live-clear-repo"),
            isMainWorktree: true
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [main])
        let storedWorktree = try #require(store.repos.first { $0.id == repo.id }?.worktrees.first)
        let pane = store.createPane(
            launchDirectory: storedWorktree.path,
            title: "Terminal",
            facets: PaneContextFacets(repoId: repo.id, worktreeId: storedWorktree.id, cwd: storedWorktree.path)
        )
        store.appendTab(Tab(paneId: pane.id))

        let externalCwd = URL(
            filePath: "/tmp/outside-known-worktrees",
            directoryHint: .isDirectory
        )
        let result = store.paneAtom.updatePaneCWDAndResolvedContext(
            pane.id,
            cwd: externalCwd,
            resolvedContext: store.repositoryTopologyAtom.repoAndWorktree(containing: externalCwd)
        )
        #expect(result == .applied)

        let updated = store.pane(pane.id)
        #expect(updated?.metadata.cwd == externalCwd)
        #expect(updated?.repoId == nil)
        #expect(updated?.worktreeId == nil)
        #expect(updated?.metadata.repoName == nil)
        #expect(updated?.metadata.worktreeName == nil)

        #expect((await store.flushAsync()).succeeded)
        let restoredStore = WorkspaceStore(sqliteDatastore: sqliteDatastore)
        _ = await restoredStore.loadCanonicalComposition()
        let restoredPane = try #require(restoredStore.pane(pane.id))
        #expect(restoredPane.metadata.cwd == externalCwd)
        #expect(restoredPane.repoId == nil)
        #expect(restoredPane.worktreeId == nil)

        #expect(
            updated?.metadata.launchDirectory
                == URL(filePath: storedWorktree.path.path, directoryHint: .isDirectory)
        )
    }

    @Test
    func updatePaneLiveLocation_preservesLaunchDirectoryWhileLiveFacetsFollowKnownCwd() {
        let repo = store.addRepo(at: URL(filePath: "/tmp/live-floating-repo"))
        let worktree = Worktree(
            repoId: repo.id,
            name: "floating-target",
            path: URL(filePath: "/tmp/live-floating-repo/floating-target")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: repo.worktrees + [worktree])
        let pane = store.createPane(
            launchDirectory: URL(filePath: "/tmp/scratch"),
            title: "Scratch Terminal"
        )

        let changed = store.paneAtom.updatePaneCWDAndResolvedContext(
            pane.id,
            cwd: worktree.path,
            resolvedContext: store.repositoryTopologyAtom.repoAndWorktree(containing: worktree.path)
        )

        let updated = store.pane(pane.id)
        #expect(changed == .applied)
        #expect(updated?.repoId == repo.id)
        #expect(updated?.worktreeId == worktree.id)
        #expect(
            updated?.metadata.launchDirectory
                == URL(filePath: "/tmp/scratch", directoryHint: .isDirectory)
        )
    }

    @Test
    func updatePaneLiveLocation_isIdempotentWhenCwdAndResolvedContextAreUnchanged() {
        let repo = store.addRepo(at: URL(filePath: "/tmp/live-idempotent-repo"))
        let worktree = repo.worktrees[0]
        let pane = store.createPane(
            launchDirectory: worktree.path,
            title: "Terminal",
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path),
        )
        let resolvedContext = store.repositoryTopologyAtom.repoAndWorktree(containing: worktree.path)

        let first = store.paneAtom.updatePaneCWDAndResolvedContext(
            pane.id,
            cwd: worktree.path,
            resolvedContext: resolvedContext
        )
        let second = store.paneAtom.updatePaneCWDAndResolvedContext(
            pane.id,
            cwd: worktree.path,
            resolvedContext: resolvedContext
        )

        #expect(first == .unchanged)
        #expect(second == .unchanged)
    }

    @Test
    func updatePaneLiveLocation_reportsMissingPaneSeparately() {
        let result = store.paneAtom.updatePaneCWDAndResolvedContext(
            UUID(),
            cwd: URL(filePath: "/tmp/missing-pane"),
            resolvedContext: nil
        )

        #expect(result == .paneMissing)
    }

    @Test("workspace pane atom updates pane note")
    func workspacePaneAtomUpdatesPaneNote() {
        let atom = WorkspacePaneAtom()
        let pane = Pane(
            id: PaneId.generateUUIDv7().uuid,
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata()
        )
        #expect(atom.insertRestoredPane(pane))

        atom.updatePaneNote(pane.id, note: "  Restart backend after deploy  ")

        #expect(atom.pane(pane.id)?.metadata.note == "Restart backend after deploy")
    }

    @Test("workspace pane atom updates pin without changing pending undo identity")
    func workspacePaneAtomUpdatesPinWithoutChangingPendingUndoIdentity() {
        let atom = WorkspacePaneAtom()
        let pane = Pane(
            content: .terminal(
                TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())
            ),
            metadata: PaneMetadata()
        )
        #expect(!pane.metadata.isPinned)
        #expect(atom.insertRestoredPane(pane))
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        atom.setResidency(.pendingUndo(expiresAt: expiresAt), for: pane.id)

        atom.updatePanePinned(pane.id, isPinned: true)
        atom.updatePanePinned(pane.id, isPinned: true)

        #expect(atom.pane(pane.id)?.metadata.isPinned == true)
        #expect(atom.pane(pane.id)?.residency == .pendingUndo(expiresAt: expiresAt))
        #expect(atom.pane(pane.id)?.id == pane.id)
    }

    @Test

    func test_removePane_removesFromPanes() {
        // Arrange
        let pane = store.createPane()

        // Act
        store.removePane(pane.id)

        // Assert
        #expect(store.panes.isEmpty)
    }

    @Test

    func test_removePane_removesFromLayouts() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id])
        store.appendTab(tab)

        // Act
        store.removePane(p1.id)

        // Assert — removePane cascades to layouts and removes empty tabs
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].paneIds == [p2.id])
        #expect(store.tabs[0].activePaneId == p2.id)
    }

    @Test

    func test_removePane_lastInTab_closesTab() {
        // Arrange
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        #expect(store.tabs.count == 1)

        // Act
        store.removePane(pane.id)

        // Assert
        #expect(store.tabs.isEmpty)
    }

    @Test

    func test_updatePaneTitle() {
        // Arrange
        let pane = store.createPane()

        // Act
        store.updatePaneTitle(pane.id, title: "New Title")

        // Assert
        #expect(store.pane(pane.id)?.title == "New Title")
    }

    @Test

    func test_updatePaneCWD_updatesValue() {
        // Arrange
        let pane = store.createPane()
        let cwd = URL(filePath: "/tmp/workspace", directoryHint: .isDirectory)

        // Act
        store.updatePaneCWD(pane.id, cwd: cwd)

        // Assert
        #expect(store.pane(pane.id)?.metadata.cwd == cwd)
    }

    @Test

    func test_updatePaneCWD_nilClearsValue() {
        // Arrange
        let pane = store.createPane()
        store.updatePaneCWD(pane.id, cwd: URL(fileURLWithPath: "/tmp"))

        // Act
        store.updatePaneCWD(pane.id, cwd: nil)

        // Assert
        #expect((store.pane(pane.id)?.metadata.cwd) == nil)
    }

    @Test

    func test_updatePaneCWD_sameCWD_noOpDoesNotMarkDirty() async {
        // Arrange
        let pane = store.createPane()
        let cwd = URL(fileURLWithPath: "/tmp")
        store.updatePaneCWD(pane.id, cwd: cwd)
        store.appendTab(Tab(paneId: pane.id))
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        // Act — update with same CWD
        store.updatePaneCWD(pane.id, cwd: cwd)

        // Assert — should not be dirty (dedup guard)
        #expect(!(store.isDirty))
    }

    @Test

    func test_updatePaneCWD_unknownPane_doesNotCrash() {
        // Act — should just log warning, not crash
        store.updatePaneCWD(UUID(), cwd: URL(fileURLWithPath: "/tmp"))

        // Assert — no crash, panes unchanged
        #expect(store.panes.isEmpty)
    }

    @Test

    func test_setResidency() {
        // Arrange
        let pane = store.createPane()
        #expect(pane.residency == .active)

        // Act
        let expiresAt = Date(timeIntervalSinceNow: 300)
        store.setResidency(.pendingUndo(expiresAt: expiresAt), for: pane.id)

        // Assert
        #expect(store.pane(pane.id)?.residency == .pendingUndo(expiresAt: expiresAt))
    }

    @Test

    func test_setResidency_backgrounded() {
        // Arrange
        let pane = store.createPane()

        // Act
        store.setResidency(.backgrounded, for: pane.id)

        // Assert
        #expect(store.pane(pane.id)?.residency == .backgrounded)
    }

    @Test

    func test_createPane_withLifetimeAndResidency() {
        // Act
        let pane = store.createPane(
            lifetime: .temporary,
            residency: .backgrounded
        )

        // Assert
        #expect(pane.lifetime == .temporary)
        #expect(pane.residency == .backgrounded)
    }

    // MARK: - Derived State

    @Test

    func test_isWorktreeActive_noPanes_returnsFalse() {
        #expect(!(store.isWorktreeActive(UUID())))
    }

    @Test

    func test_isWorktreeActive_withPane_returnsTrue() {
        // Arrange
        let worktreePath = URL(fileURLWithPath: "/tmp/worktree")
        let repo = store.addRepo(at: worktreePath)
        let worktree = repo.worktrees[0]
        store.createPane(
            launchDirectory: worktreePath,
            facets: PaneContextFacets(
                repoId: repo.id,
                worktreeId: worktree.id,
                cwd: worktreePath
            )
        )

        // Assert
        #expect(store.isWorktreeActive(worktree.id))
    }

    @Test

    func test_paneCount_forWorktree() {
        // Arrange
        let worktreePath = URL(fileURLWithPath: "/tmp/worktree")
        let repo = store.addRepo(at: worktreePath)
        let worktree = repo.worktrees[0]
        let otherWorktreePath = URL(fileURLWithPath: "/tmp/other-worktree")
        let otherRepo = store.addRepo(at: otherWorktreePath)
        let otherWorktree = otherRepo.worktrees[0]
        store.createPane(
            launchDirectory: worktreePath,
            facets: PaneContextFacets(
                repoId: repo.id, worktreeId: worktree.id, cwd: worktreePath)
        )
        store.createPane(
            launchDirectory: worktreePath,
            facets: PaneContextFacets(
                repoId: repo.id, worktreeId: worktree.id, cwd: worktreePath)
        )
        store.createPane(
            launchDirectory: otherWorktreePath,
            facets: PaneContextFacets(
                repoId: otherRepo.id,
                worktreeId: otherWorktree.id,
                cwd: otherWorktreePath
            )
        )

        // Assert
        #expect(store.paneCount(for: worktree.id) == 2)
    }

    // MARK: - Tab Mutations

    @Test

    func test_appendTab_addsToTabs() {
        // Arrange
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)

        // Act
        store.appendTab(tab)

        // Assert
        #expect(store.tabs.count == 1)
        #expect(store.activeTabId == tab.id)
    }

    @Test

    func test_removeTab_removesAndUpdatesActiveTabId() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let tab1 = Tab(paneId: s1.id)
        let tab2 = Tab(paneId: s2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)
        store.setActiveTab(tab1.id)

        // Act
        store.removeTab(tab1.id)

        // Assert
        #expect(store.tabs.count == 1)
        #expect(store.activeTabId == tab2.id)
    }

    @Test

    func test_insertTab_atIndex() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let s3 = store.createPane()
        let tab1 = Tab(paneId: s1.id)
        let tab2 = Tab(paneId: s2.id)
        let tab3 = Tab(paneId: s3.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act
        store.insertTab(tab3, at: 1)

        // Assert
        #expect(store.tabs.count == 3)
        #expect(store.tabs[1].id == tab3.id)
    }

    @Test

    func test_moveTab() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let s3 = store.createPane()
        let tab1 = Tab(paneId: s1.id)
        let tab2 = Tab(paneId: s2.id)
        let tab3 = Tab(paneId: s3.id)
        store.appendTab(tab1)
        store.appendTab(tab2)
        store.appendTab(tab3)

        // Act — move tab3 to position 0
        store.moveTab(fromId: tab3.id, insertionIndex: 0)

        // Assert
        #expect(store.tabs[0].id == tab3.id)
        #expect(store.tabs[1].id == tab1.id)
        #expect(store.tabs[2].id == tab2.id)
    }

    // MARK: - Layout Mutations

    @Test

    func test_insertPane_splitsLayout() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let tab = Tab(paneId: s1.id)
        store.appendTab(tab)

        // Act
        store.insertPane(
            s2.id, inTab: tab.id, at: s1.id,
            direction: .horizontal, position: .after, sizingMode: .halveTarget
        )

        // Assert
        let updatedTab = store.tabs[0]
        #expect(updatedTab.isSplit)
        #expect(updatedTab.paneIds == [s1.id, s2.id])
    }

    @Test

    func test_removePaneFromLayout_collapsesToSingle() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let tab = makeTab(paneIds: [s1.id, s2.id])
        store.appendTab(tab)

        // Act
        store.removePaneFromLayout(s1.id, inTab: tab.id)

        // Assert
        let updatedTab = store.tabs[0]
        #expect(!(updatedTab.isSplit))
        #expect(updatedTab.paneIds == [s2.id])
        #expect(updatedTab.activePaneId == s2.id)
    }

    @Test

    func test_removePaneFromLayout_lastPane_removesTab() {
        // Arrange
        let s1 = store.createPane()
        let tab = Tab(paneId: s1.id)
        store.appendTab(tab)

        // Act
        store.removePaneFromLayout(s1.id, inTab: tab.id)

        // Assert
        #expect(store.tab(tab.id) == nil)
    }

    @Test

    func test_equalizePanes() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let tab = Tab(paneId: s1.id)
        store.appendTab(tab)
        store.insertPane(
            s2.id, inTab: tab.id, at: s1.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)

        guard let dividerId = store.tabs[0].layout.dividerIds.first else {
            Issue.record("Expected divider")
            return
        }
        store.resizePane(tabId: tab.id, splitId: dividerId, ratio: 0.3)

        // Act
        store.equalizePanes(tabId: tab.id)

        // Assert
        #expect(abs((store.tabs[0].layout.ratioForSplit(dividerId) ?? 0.0) - (0.5)) <= 0.001)
    }

    // MARK: - Compound Operations

    @Test

    func test_breakUpTab_splitIntoIndividual() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let s3 = store.createPane()
        let tab = makeTab(paneIds: [s1.id, s2.id, s3.id])
        store.appendTab(tab)

        // Act
        let newTabs = store.breakUpTab(tab.id)

        // Assert
        #expect(newTabs.count == 3)
        #expect(store.tabs.count == 3)
        #expect(store.tabs[0].paneIds == [s1.id])
        #expect(store.tabs[1].paneIds == [s2.id])
        #expect(store.tabs[2].paneIds == [s3.id])
    }

    @Test

    func test_breakUpTab_singlePane_noOp() {
        // Arrange
        let s1 = store.createPane()
        let tab = Tab(paneId: s1.id)
        store.appendTab(tab)

        // Act
        let newTabs = store.breakUpTab(tab.id)

        // Assert
        #expect(newTabs.isEmpty)
        #expect(store.tabs.count == 1)
    }

    @Test

    func test_extractPane() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let tab = makeTab(paneIds: [s1.id, s2.id])
        store.appendTab(tab)

        // Act
        let newTab = store.extractPane(s2.id, fromTab: tab.id)

        // Assert
        #expect((newTab) != nil)
        #expect(store.tabs.count == 2)
        #expect(store.tabs[0].paneIds == [s1.id])
        #expect(store.tabs[1].paneIds == [s2.id])
        #expect(store.activeTabId == newTab?.id)
    }

    @Test
    func test_extractPane_removesPaneFromSourceArrangementMinimizedSet() {
        let s1 = store.createPane()
        let s2 = store.createPane()
        let tab = makeTab(paneIds: [s1.id, s2.id])
        store.appendTab(tab)
        _ = store.minimizePane(s2.id, inTab: tab.id)

        _ = store.extractPane(s2.id, fromTab: tab.id)

        #expect(store.tabs[0].activeMinimizedPaneIds.isEmpty)
    }

    @Test

    func test_extractPane_singlePane_noOp() {
        // Arrange
        let s1 = store.createPane()
        let tab = Tab(paneId: s1.id)
        store.appendTab(tab)

        // Act
        let result = store.extractPane(s1.id, fromTab: tab.id)

        // Assert
        #expect((result) == nil)
        #expect(store.tabs.count == 1)
    }

    @Test

    func test_mergeTab() {
        // Arrange
        let s1 = store.createPane()
        let s2 = store.createPane()
        let tab1 = Tab(paneId: s1.id)
        let tab2 = Tab(paneId: s2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act — merge tab2 into tab1
        store.mergeTab(
            sourceId: tab2.id, intoTarget: tab1.id,
            at: s1.id, direction: .horizontal, position: .after
        )

        // Assert
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].paneIds.count == 2)
        #expect(store.tabs[0].paneIds.contains(s1.id))
        #expect(store.tabs[0].paneIds.contains(s2.id))
    }

    @Test
    func test_mergeTab_sameSourceAndTarget_noOp() {
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)

        store.mergeTab(
            sourceId: tab.id,
            intoTarget: tab.id,
            at: pane.id,
            direction: .horizontal,
            position: .after
        )

        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].id == tab.id)
        #expect(store.tabs[0].paneIds == [pane.id])
    }

    // MARK: - Queries

    @Test

    func test_pane_byId() {
        // Arrange
        let pane = store.createPane()

        // Assert
        #expect(store.pane(pane.id)?.id == pane.id)
        #expect((store.pane(UUID())) == nil)
    }

    @Test

    func test_tabContaining_paneId() {
        // Arrange
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)

        // Assert
        #expect(store.tabContaining(paneId: pane.id)?.id == tab.id)
        #expect((store.tabContaining(paneId: UUID())) == nil)
    }

    @Test

    func test_panes_forWorktree() {
        // Arrange
        let worktreePath = URL(fileURLWithPath: "/tmp/worktree")
        let repo = store.addRepo(at: worktreePath)
        let worktree = repo.worktrees[0]
        let otherWorktreePath = URL(fileURLWithPath: "/tmp/other-worktree")
        let otherRepo = store.addRepo(at: otherWorktreePath)
        let otherWorktree = otherRepo.worktrees[0]
        store.createPane(
            launchDirectory: worktreePath,
            facets: PaneContextFacets(
                repoId: repo.id, worktreeId: worktree.id, cwd: worktreePath)
        )
        store.createPane(
            launchDirectory: worktreePath,
            facets: PaneContextFacets(
                repoId: repo.id, worktreeId: worktree.id, cwd: worktreePath)
        )
        store.createPane(
            launchDirectory: otherWorktreePath,
            facets: PaneContextFacets(
                repoId: otherRepo.id,
                worktreeId: otherWorktree.id,
                cwd: otherWorktreePath
            )
        )

        // Assert
        #expect(store.panes(for: worktree.id).count == 2)
    }

    // MARK: - Persistence Round-Trip

    // MARK: - Orphaned Pane Pruning

    // MARK: - Dirty Flag

    @Test

    func test_isDirty_setOnMutation_clearedOnFlush() async {
        // Arrange
        #expect(!(store.isDirty))

        // Act — mutation marks dirty
        let pane = store.createPane()
        store.appendTab(Tab(paneId: pane.id))
        #expect(store.isDirty)

        // Act — flush clears dirty
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        #expect(!(store.isDirty))
    }

    @Test(.timeLimit(.minutes(1)))
    func debouncedAutosaveReportsPreparedLocalUnavailabilityWhileContinuingCoreSaves()
        async throws
    {
        let workspaceId = UUID()
        let saveProbe = WorkspaceSQLiteSaveProbe()
        guard
            let preparedDatastore = try await preparedDatastoreWithUnavailableLocal(
                workspaceId: workspaceId,
                saveProbe: saveProbe
            )
        else {
            return
        }
        let sqliteDatastore = preparedDatastore.sqliteDatastore
        let clock = TestPushClock()
        var recoveryEvents: [PersistenceRecoveryEvent] = []
        let failureReports = AsyncStream.makeStream(
            of: PaneTopologyPersistenceReason.self,
            bufferingPolicy: .unbounded
        )
        defer { failureReports.continuation.finish() }
        var failureReportIterator = failureReports.stream.makeAsyncIterator()
        let identityAtom = WorkspaceIdentityAtom(workspaceId: UUIDv7.generate())
        identityAtom.replaceIdentity(
            workspaceId: workspaceId,
            workspaceName: "Autosave Damping",
            createdAt: Date(timeIntervalSince1970: 1_700_010_000)
        )
        let store = WorkspaceStore(
            identityAtom: identityAtom,
            sqliteDatastore: sqliteDatastore,
            persistDebounceDuration: .milliseconds(10),
            clock: clock,
            recoveryReporter: { event in recoveryEvents.append(event) },
            persistenceReasonReporter: { reason in
                failureReports.continuation.yield(reason)
            }
        )

        func advanceNextDebouncedSave(
            after mutation: () -> Void
        ) async throws -> PaneTopologyPersistenceReason {
            let nextSleepGeneration = clock.scheduledSleepGeneration
            mutation()
            await clock.waitForPendingSleepGeneration(nextSleepGeneration)
            clock.advance(by: .milliseconds(10))
            // The datastore probe precedes the throw back to WorkspaceStore.
            // This report and any recovery callback run synchronously on MainActor,
            // so this MainActor test resumes after both, including damped failures.
            return try #require(await failureReportIterator.next(isolation: #isolation))
        }

        for attempt in 1...3 {
            let failureReason = try await advanceNextDebouncedSave {
                store.setSidebarWidth(CGFloat(300 + attempt))
            }
            #expect(failureReason == .workspaceSaveDatabaseFailed)
            #expect(store.isDirty)
        }
        #expect(await saveProbe.saveCount == 3)
        #expect(await saveProbe.succeededSaveCount == 0)
        #expect(await saveProbe.failedSaveCount == 3)
        #expect(recoveryEvents.count == 3)
        #expect(recoveryEvents.allSatisfy { $0.store == .workspace && $0.recovery == .saveFailed })
        #expect(store.isDirty)

        let fourthFailureReason = try await advanceNextDebouncedSave {
            store.setSidebarWidth(304)
        }
        #expect(fourthFailureReason == .workspaceSaveDatabaseFailed)

        #expect(await saveProbe.saveCount == 4)
        #expect(await saveProbe.failedSaveCount == 4)
        #expect(await saveProbe.succeededSaveCount == 0)
        #expect(recoveryEvents.count == 3)
        #expect(store.isDirty)

        let fifthFailureReason = try await advanceNextDebouncedSave {
            store.setSidebarWidth(305)
        }
        #expect(fifthFailureReason == .workspaceSaveDatabaseFailed)

        #expect(await saveProbe.saveCount == 5)
        #expect(await saveProbe.succeededSaveCount == 0)
        #expect(await saveProbe.failedSaveCount == 5)
        #expect(recoveryEvents.count == 3)
        #expect(store.isDirty)
    }

    @Test
    func test_isDirty_setOnDirectPaneAtomMutation() async {
        #expect(!(store.isDirty))

        _ = store.paneAtom.createPane(zmxSessionID: .generateUUIDv7())
        #expect(store.isDirty)
    }

    @Test
    func paneAcceptedCommitRevisionDrivesAutosaveWithoutEqualOrPruneNoise() async throws {
        await prepareSharedDatastoreForBoot()
        let pane = store.paneAtom.createPane(zmxSessionID: .generateUUIDv7())
        store.tabLayoutAtom.appendTab(Tab(paneId: pane.id))
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.paneAtom.updatePaneTitle(pane.id, title: "Accepted title")
        #expect(store.isDirty)
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.paneAtom.updatePaneTitle(pane.id, title: "Accepted title")
        #expect(!store.isDirty)

        let missingPaneID = UUIDv7.generate()
        _ = store.paneAtom.graphAtom.paneState(missingPaneID)
        _ = store.paneAtom.graphAtom.paneStructuralFacts(missingPaneID)
        let unchangedReplacement = try requirePaneGraphReplacement(
            store.paneAtom.graphAtom.paneStateSnapshot()
        )
        store.paneAtom.graphAtom.replacePaneStates(unchangedReplacement)
        #expect(!store.isDirty)

        var replacementStates = store.paneAtom.graphAtom.paneStateSnapshot()
        replacementStates[pane.id]?.metadata.title = "Replacement title"
        store.paneAtom.graphAtom.replacePaneStates(
            try requirePaneGraphReplacement(replacementStates)
        )
        #expect(store.isDirty)
    }

    @Test
    func repositoryTopologyStoreAutosavesWithoutWorkspaceActivation() async throws {
        let factSource = RepositoryTopologyStoreFactSource()
        let facts = try factSource.attach()
        await prepareSharedDatastoreForBoot()
        let topologyAtom = RepositoryTopologyAtom()
        let clock = TestPushClock()
        let topologyStore = RepositoryTopologyStore(
            atom: topologyAtom,
            sqliteDatastore: sqliteDatastore,
            persistDebounceDuration: .milliseconds(10),
            clock: clock,
            factSink: factSource.sink
        )
        topologyStore.startObserving()
        #expect(!topologyStore.isDirty)

        let repositoryID = UUIDv7.generate()
        let repositoryPath = URL(fileURLWithPath: "/tmp/direct-topology")
        let repository = Repo(
            id: repositoryID,
            name: repositoryPath.lastPathComponent,
            repoPath: repositoryPath,
            worktrees: [
                Worktree(
                    id: UUIDv7.generate(),
                    repoId: repositoryID,
                    name: repositoryPath.lastPathComponent,
                    path: repositoryPath,
                    isMainWorktree: true
                )
            ]
        )
        guard
            case .prepared(let replacement) = RepositoryTopologyReplacement.prepare(
                repositories: [repository],
                watchedPaths: [],
                unavailableRepositoryIDs: []
            )
        else {
            Issue.record("expected valid repository topology fixture")
            return
        }
        let nextSleepGeneration = clock.scheduledSleepGeneration
        topologyAtom.replaceTopology(replacement)
        let capturedRevision = topologyAtom.lifecycleRevision
        await clock.waitForPendingSleepGeneration(nextSleepGeneration)
        #expect(topologyStore.isDirty)
        clock.advance(by: .milliseconds(10))

        _ = try await facts.expectNextSaveCompleted(captureRevision: capturedRevision)
        guard case .loaded(let snapshot) = await sqliteDatastore.loadRepositoryTopologySnapshot() else {
            Issue.record("expected autosaved repository topology")
            return
        }

        #expect(snapshot.repos.map(\.id) == [repositoryID])
        #expect(!topologyStore.isDirty)
        try await facts.finish()
    }

    private func requirePaneGraphReplacement(
        _ paneStates: [UUID: PaneGraphState]
    ) throws -> WorkspacePaneGraphReplacement {
        switch WorkspacePaneGraphReplacement.prepare(paneStates) {
        case .success(let replacement):
            return replacement
        case .failure(let rejection):
            Issue.record("pane graph replacement rejected: \(rejection)")
            throw rejection
        }
    }

    @Test
    func test_zoomPresentationChangeDoesNotDirtyWorkspacePersistence() async {
        let pane = store.paneAtom.createPane(zmxSessionID: .generateUUIDv7())
        let tab = Tab(paneId: pane.id)
        store.tabLayoutAtom.appendTab(tab)
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: pane.id,
            viewerPresentation: .unavailable
        )
        #expect(!store.isDirty)
    }

    @Test
    func test_isDirty_setOnDirectTabWriteOwnerMutation() async {
        let pane = store.paneAtom.createPane(zmxSessionID: .generateUUIDv7())
        let tab = Tab(paneId: pane.id)
        store.tabLayoutAtom.appendTab(tab)
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.tabGraphAtom.replaceStates([])
        #expect(store.isDirty)
    }

    @Test
    func test_isDirty_setOnActiveTabCursorMutation() async {
        let firstPane = store.createPane()
        let firstTab = Tab(paneId: firstPane.id)
        store.appendTab(firstTab)
        let secondPane = store.createPane()
        let secondTab = Tab(paneId: secondPane.id)
        store.appendTab(secondTab)
        #expect(store.activeTabId == secondTab.id)
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.setActiveTab(firstTab.id)
        #expect(store.isDirty)
    }

    @Test
    func test_isDirty_setOnActiveArrangementCursorMutation() async throws {
        let firstPane = store.createPane()
        let tab = Tab(paneId: firstPane.id)
        store.appendTab(tab)
        let secondPane = store.createPane()
        #expect(
            store.insertPane(
                secondPane.id,
                inTab: tab.id,
                at: firstPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            ))
        let customArrangementId = try #require(store.createArrangement(name: "Focus", inTab: tab.id))
        store.switchArrangement(to: tab.defaultArrangement.id, inTab: tab.id)
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.switchArrangement(to: customArrangementId, inTab: tab.id)
        #expect(store.isDirty)
    }

    @Test
    func test_isDirty_setOnActivePaneCursorMutation() async {
        let firstPane = store.createPane()
        let tab = Tab(paneId: firstPane.id)
        store.appendTab(tab)
        let secondPane = store.createPane()
        #expect(
            store.insertPane(
                secondPane.id,
                inTab: tab.id,
                at: firstPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            ))
        #expect(store.tab(tab.id)?.activePaneId == secondPane.id)
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.setActivePane(firstPane.id, inTab: tab.id)
        #expect(store.isDirty)
    }

    @Test
    func test_isDirty_setOnActiveDrawerChildCursorMutation() async throws {
        let parentPane = store.createPane()
        let tab = Tab(paneId: parentPane.id)
        store.appendTab(tab)
        let firstDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        let secondDrawerPane = try #require(store.addDrawerPane(to: parentPane.id))
        #expect(store.drawerView(forParent: parentPane.id)?.activeChildId == secondDrawerPane.id)
        await prepareSharedDatastoreForBoot()
        #expect((await store.flushAsync()).succeeded)
        #expect(!store.isDirty)

        store.setActiveDrawerPane(firstDrawerPane.id, in: parentPane.id)
        #expect(store.isDirty)
    }

    // MARK: - Undo

    @Test

    func test_snapshotForClose_capturesState() {
        // Arrange
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)

        // Act
        let snapshot = store.snapshotForClose(tabId: tab.id)

        // Assert
        #expect((snapshot) != nil)
        #expect(snapshot?.tab.id == tab.id)
        #expect(snapshot?.panes.count == 1)
        #expect(snapshot?.tabIndex == 0)
    }

    @Test

    func test_restoreFromSnapshot_reinsertTab() {
        // Arrange
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        let snapshot = store.snapshotForClose(tabId: tab.id)!

        // Act — remove tab and pane, then restore
        store.removeTab(tab.id)
        store.removePane(pane.id)
        #expect(store.tabs.isEmpty)
        #expect(store.panes.isEmpty)

        store.restoreFromSnapshot(snapshot)

        // Assert
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].id == tab.id)
        #expect(store.panes.count == 1)
        #expect(store.activeTabId == tab.id)
    }

    // MARK: - Worktree ID Stability

    @Test

    func test_updateRepoWorktrees_preservesExistingIds() {
        // Arrange — add repo then seed initial worktrees
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/wt-test-repo"))
        let wt1 = makeWorktree(repoId: repo.id, name: "main", path: "/tmp/wt-test-repo")
        let wt2 = makeWorktree(repoId: repo.id, name: "feat", path: "/tmp/wt-test-repo/feat")
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [wt1, wt2])

        let storedWt1Id = store.repos.first(where: { $0.id == repo.id })!.worktrees[0].id
        let storedWt2Id = store.repos.first(where: { $0.id == repo.id })!.worktrees[1].id

        // Create a pane referencing wt1's ID
        let pane = store.createPane(
            launchDirectory: store.repos.first!.worktrees.first!.path,
            facets: PaneContextFacets(
                repoId: repo.id, worktreeId: storedWt1Id, cwd: store.repos.first!.worktrees.first!.path)
        )

        // Act — simulate refresh with fresh Worktree instances (new UUIDs, same paths)
        let freshWt1 = makeWorktree(repoId: repo.id, name: "main-updated", path: "/tmp/wt-test-repo")
        let freshWt2 = makeWorktree(repoId: repo.id, name: "feat-updated", path: "/tmp/wt-test-repo/feat")
        #expect(freshWt1.id != storedWt1Id, "precondition: fresh worktree has different UUID")

        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [freshWt1, freshWt2])

        // Assert — IDs preserved, names updated
        let updated = store.repos.first(where: { $0.id == repo.id })!
        #expect(updated.worktrees.count == 2)
        #expect(updated.worktrees[0].id == storedWt1Id, "existing worktree ID preserved")
        #expect(updated.worktrees[1].id == storedWt2Id, "existing worktree ID preserved")
        #expect(updated.worktrees[0].name == "main-updated", "name updated from discovery")
        #expect(updated.worktrees[1].name == "feat-updated", "name updated from discovery")

        // Pane still resolves
        #expect(pane.worktreeId == storedWt1Id)
        #expect((store.worktree(storedWt1Id)) != nil)
    }

    @Test

    func test_updateRepoWorktrees_addsNewWorktrees() {
        // Arrange
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/wt-test-repo2"))
        let wt1 = makeWorktree(repoId: repo.id, name: "main", path: "/tmp/wt-test-repo2")
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [wt1])
        let storedWt1Id = store.repos.first(where: { $0.id == repo.id })!.worktrees[0].id

        // Act — refresh adds a new worktree
        let freshWt1 = makeWorktree(repoId: repo.id, name: "main", path: "/tmp/wt-test-repo2")
        let newWt = makeWorktree(repoId: repo.id, name: "hotfix", path: "/tmp/wt-test-repo2/hotfix")
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [freshWt1, newWt])

        // Assert
        let updated = store.repos.first(where: { $0.id == repo.id })!
        #expect(updated.worktrees.count == 2)
        #expect(updated.worktrees[0].id == storedWt1Id, "existing ID preserved")
        #expect(updated.worktrees[1].id == newWt.id, "new worktree gets its own ID")
    }

    @Test

    func test_updateRepoWorktrees_removesDeletedWorktrees() {
        // Arrange
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/wt-test-repo3"))
        let wt1 = makeWorktree(repoId: repo.id, name: "main", path: "/tmp/wt-test-repo3")
        let wt2 = makeWorktree(repoId: repo.id, name: "feat", path: "/tmp/wt-test-repo3/feat")
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [wt1, wt2])
        let storedWt1Id = store.repos.first(where: { $0.id == repo.id })!.worktrees[0].id

        // Act — refresh returns only wt1 (wt2 was deleted)
        let freshWt1 = makeWorktree(repoId: repo.id, name: "main", path: "/tmp/wt-test-repo3")
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [freshWt1])

        // Assert — only wt1 remains
        let updated = store.repos.first(where: { $0.id == repo.id })!
        #expect(updated.worktrees.count == 1)
        #expect(updated.worktrees[0].id == storedWt1Id)
    }

    @Test

    func test_updateRepoWorktrees_noopWhenMergedResultUnchanged() {
        // Arrange
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/wt-test-repo4"))
        let wt1 = makeWorktree(repoId: repo.id, name: "main", path: "/tmp/wt-test-repo4")
        let wt2 = makeWorktree(repoId: repo.id, name: "feat", path: "/tmp/wt-test-repo4/feat")
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [wt1, wt2])
        let before = store.repos.first(where: { $0.id == repo.id })!

        // Act — same effective data, but fresh worktree instances
        let sameWt1 = makeWorktree(repoId: repo.id, name: "main", path: "/tmp/wt-test-repo4")
        let sameWt2 = makeWorktree(repoId: repo.id, name: "feat", path: "/tmp/wt-test-repo4/feat")
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [sameWt1, sameWt2])
        let after = store.repos.first(where: { $0.id == repo.id })!

        // Assert — IDs/worktrees unchanged
        #expect(after.worktrees == before.worktrees)
    }

    // MARK: - Restore Validation

    @Test

    func test_persistence_activeTabIdNotMutatedDuringSave() async {
        // Arrange — create tabs: tab1 has temporary pane (pruned on save), tab2 is persistent
        let p1 = store.createPane(
            lifetime: .temporary)
        let tab1 = Tab(paneId: p1.id)
        store.appendTab(tab1)
        let p2 = store.createPane()
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab2)
        store.setActiveTab(tab1.id)  // select the temporary tab

        // Act — flush() calls persistNow() which prunes tab1 (all-temporary)
        // from the persisted copy. This should NOT change live activeTabId.
        await prepareSharedDatastoreForBoot()
        _ = await store.flushAsync()

        // Assert — live activeTabId still points to tab1
        #expect(store.activeTabId == tab1.id, "flush/persistNow should not mutate live activeTabId")
    }

    // MARK: - moveTabByDelta

    @Test

    func test_moveTabByDelta_movesForward() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let p3 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        let tab3 = Tab(paneId: p3.id)
        store.appendTab(tab1)
        store.appendTab(tab2)
        store.appendTab(tab3)

        // Act — move tab1 forward by 2
        store.moveTabByDelta(tabId: tab1.id, delta: 2)

        // Assert — tab1 is now at index 2
        #expect(store.tabs[0].id == tab2.id)
        #expect(store.tabs[1].id == tab3.id)
        #expect(store.tabs[2].id == tab1.id)
    }

    @Test

    func test_moveTabByDelta_movesBackward() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let p3 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        let tab3 = Tab(paneId: p3.id)
        store.appendTab(tab1)
        store.appendTab(tab2)
        store.appendTab(tab3)

        // Act — move tab3 backward by 1
        store.moveTabByDelta(tabId: tab3.id, delta: -1)

        // Assert — tab3 is now at index 1
        #expect(store.tabs[0].id == tab1.id)
        #expect(store.tabs[1].id == tab3.id)
        #expect(store.tabs[2].id == tab2.id)
    }

    @Test

    func test_moveTabByDelta_clampsAtEnd() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act — move tab1 forward by 100 (should clamp)
        store.moveTabByDelta(tabId: tab1.id, delta: 100)

        // Assert — tab1 clamped to last position
        #expect(store.tabs[0].id == tab2.id)
        #expect(store.tabs[1].id == tab1.id)
    }

    @Test

    func test_moveTabByDelta_clampsAtStart() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act — move tab2 backward by 100 (should clamp to 0)
        store.moveTabByDelta(tabId: tab2.id, delta: -100)

        // Assert — tab2 clamped to first position
        #expect(store.tabs[0].id == tab2.id)
        #expect(store.tabs[1].id == tab1.id)
    }

    @Test

    func test_moveTabByDelta_singleTab_noOp() {
        // Arrange
        let p1 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        store.appendTab(tab1)

        // Act — single tab, delta should be ignored
        store.moveTabByDelta(tabId: tab1.id, delta: 1)

        // Assert — unchanged
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].id == tab1.id)
    }

    // MARK: - setActiveTab

    @Test

    func test_setActiveTab_setsTabId() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        let tab2 = Tab(paneId: p2.id)
        store.appendTab(tab1)
        store.appendTab(tab2)

        // Act
        store.setActiveTab(tab2.id)

        // Assert
        #expect(store.activeTabId == tab2.id)
    }

    @Test

    func test_setActiveTab_nil_clearsActiveTab() {
        // Arrange
        let p1 = store.createPane()
        let tab1 = Tab(paneId: p1.id)
        store.appendTab(tab1)
        store.setActiveTab(tab1.id)

        // Act
        store.setActiveTab(nil)

        // Assert
        #expect((store.activeTabId) == nil)
    }

    // MARK: - setActivePane

    @Test

    func test_setActivePane_validPane() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id], activePaneId: p1.id)
        store.appendTab(tab)

        // Act
        store.setActivePane(p2.id, inTab: tab.id)

        // Assert
        #expect(store.tabs[0].activePaneId == p2.id)
    }

    @Test

    func test_setActivePane_invalidPane_rejected() {
        // Arrange
        let p1 = store.createPane()
        let tab = Tab(paneId: p1.id)
        store.appendTab(tab)

        // Act — set to a pane ID that doesn't exist in the tab
        let bogus = UUID()
        store.setActivePane(bogus, inTab: tab.id)

        // Assert — unchanged
        #expect(store.tabs[0].activePaneId == p1.id)
    }

    @Test

    func test_setActivePane_nil_clearsActivePane() {
        // Arrange
        let p1 = store.createPane()
        let tab = Tab(paneId: p1.id)
        store.appendTab(tab)

        // Act
        store.setActivePane(nil, inTab: tab.id)

        // Assert
        #expect((store.tabs[0].activePaneId) == nil)
    }

    // MARK: - resizePane

    @Test

    func test_resizePane_changesRatio() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id])
        store.appendTab(tab)
        guard let dividerId = store.tabs[0].layout.dividerIds.first else {
            Issue.record("Expected divider")
            return
        }

        // Act
        store.resizePane(tabId: tab.id, splitId: dividerId, ratio: 0.7)

        // Assert
        #expect(abs((store.tabs[0].layout.ratioForSplit(dividerId) ?? 0.0) - (0.7)) <= 0.001)
    }

    @Test
    func test_resizeVisiblePanePair_preservesMinimizedRatioAndUnrelatedPane() {
        let p1 = store.createPane()
        let p2 = store.createPane()
        let p3 = store.createPane()
        let p4 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id, p3.id, p4.id], activePaneId: p1.id)
        store.appendTab(tab)
        store.minimizePane(p2.id, inTab: tab.id)
        let before = store.tabs[0].layout

        store.resizeVisiblePanePair(tabId: tab.id, leftPaneId: p1.id, rightPaneId: p3.id, ratio: 0.7)

        let after = store.tabs[0].layout
        #expect(abs((after.ratioForPanePair(leftPaneId: p1.id, rightPaneId: p3.id) ?? 0) - 0.7) <= 0.001)
        #expect(abs((after.paneRatio(p2.id) ?? 0) - (before.paneRatio(p2.id) ?? 0)) <= 1e-9)
        #expect(abs((after.paneRatio(p4.id) ?? 0) - (before.paneRatio(p4.id) ?? 0)) <= 1e-9)
    }

    // MARK: - resizePaneByDelta

    @Test

    func test_resizePaneByDelta_adjustsRatio() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id])
        store.appendTab(tab)
        guard let dividerId = store.tabs[0].layout.dividerIds.first else {
            Issue.record("Expected divider")
            return
        }
        let ratioBefore = store.tabs[0].layout.ratioForSplit(dividerId)

        // Act — resize p1 to the right (increase left pane)
        store.resizePaneByDelta(tabId: tab.id, paneId: p1.id, direction: .right, amount: 10)

        // Assert — ratio changed
        #expect(store.tabs[0].layout.ratioForSplit(dividerId) != ratioBefore)
    }

    @Test
    func test_resizePaneByDelta_skipsMinimizedNeighbor() {
        let p1 = store.createPane()
        let p2 = store.createPane()
        let p3 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id, p3.id], activePaneId: p1.id)
        store.appendTab(tab)
        store.minimizePane(p2.id, inTab: tab.id)
        let before = store.tabs[0].layout

        store.resizePaneByDelta(tabId: tab.id, paneId: p1.id, direction: .right, amount: 10)

        let after = store.tabs[0].layout
        #expect(abs((after.paneRatio(p2.id) ?? 0) - (before.paneRatio(p2.id) ?? 0)) <= 1e-9)
        #expect((after.ratioForPanePair(leftPaneId: p1.id, rightPaneId: p3.id) ?? 0) > 0.5)
    }

    @Test
    func test_resizePaneByDelta_noOpsWhenMinimizedNeighborHasNoVisiblePartner() {
        let p1 = store.createPane()
        let p2 = store.createPane()
        let p3 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id, p3.id], activePaneId: p2.id)
        store.appendTab(tab)
        store.minimizePane(p3.id, inTab: tab.id)
        let before = store.tabs[0].layout

        store.resizePaneByDelta(tabId: tab.id, paneId: p2.id, direction: .right, amount: 10)

        #expect(store.tabs[0].layout == before)
    }

    // MARK: - addRepo / removeRepo

    @Test

    func test_addRepo_addsToRepos() {
        // Act
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/new-repo"))

        // Assert
        #expect(store.repos.count == 1)
        #expect(store.repos[0].id == repo.id)
        #expect(store.repos[0].name == "new-repo")
        #expect(store.repos[0].worktrees.count == 1)
        #expect(store.repos[0].worktrees[0].isMainWorktree)
        #expect(store.repos[0].worktrees[0].path == URL(fileURLWithPath: "/tmp/new-repo"))
    }

    @Test

    func test_addRepo_duplicate_returnsExisting() {
        // Arrange
        let path = URL(fileURLWithPath: "/tmp/dup-repo")
        let first = store.addRepo(at: path)

        // Act
        let second = store.addRepo(at: path)

        // Assert — same repo returned, not duplicated
        #expect(store.repos.count == 1)
        #expect(first.id == second.id)
        #expect(store.repos[0].worktrees.count == 1)
    }

    @Test

    func test_removeRepo_removesFromRepos() {
        // Arrange
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/del-repo"))
        #expect(store.repos.count == 1)

        // Act
        store.removeRepo(repo.id)

        // Assert
        #expect(store.repos.isEmpty)
    }

    // MARK: - setSidebarWidth / setWindowFrame

    @Test

    func test_setSidebarWidth_updatesValue() {
        // Act
        store.setSidebarWidth(300)

        // Assert
        #expect(store.sidebarWidth == 300)
    }

    @Test

    func test_setWindowFrame_updatesValue() {
        // Arrange
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

        // Act
        store.setWindowFrame(frame)

        // Assert
        #expect(store.windowFrame == frame)
    }

    @Test

    func test_setWindowFrame_nil_clearsValue() {
        // Arrange
        store.setWindowFrame(CGRect(x: 0, y: 0, width: 100, height: 100))

        // Act
        store.setWindowFrame(nil)

        // Assert
        #expect((store.windowFrame) == nil)
    }

    // MARK: - removePaneFromLayout updates activePaneId

    @Test

    func test_removePaneFromLayout_updatesActivePaneIdWhenActiveRemoved() {
        // Arrange
        let p1 = store.createPane()
        let p2 = store.createPane()
        let tab = makeTab(paneIds: [p1.id, p2.id], activePaneId: p1.id)
        store.appendTab(tab)
        #expect(store.tabs[0].activePaneId == p1.id)

        // Act — remove the active pane
        store.removePaneFromLayout(p1.id, inTab: tab.id)

        // Assert — activePaneId updated to remaining pane
        #expect(store.tabs[0].activePaneId == p2.id)
    }

    // MARK: - WatchedPath

    @Test func addWatchedPath_addsAndMarksDirty() {
        // Arrange & Act
        let result = store.addWatchedPath(URL(fileURLWithPath: "/projects"))

        // Assert
        #expect(result != nil)
        #expect(store.watchedPaths.count == 1)
        #expect(store.watchedPaths[0].path.path == "/projects")
    }

    @Test func addWatchedPath_deduplicatesByStableKey() {
        // Arrange & Act
        store.addWatchedPath(URL(fileURLWithPath: "/projects"))
        store.addWatchedPath(URL(fileURLWithPath: "/projects"))

        // Assert
        #expect(store.watchedPaths.count == 1)
    }

}

@MainActor
private func preparedDatastoreWithUnavailableLocal(
    workspaceId: UUID,
    saveProbe: WorkspaceSQLiteSaveProbe
) async throws -> (
    sqliteDatastore: WorkspaceSQLiteDatastoreActor,
    localRepositoryFactory: FailingThenSucceedingLocalRepositoryFactory
)? {
    let coreQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "AgentStudio.t8.damping.core")
    let localQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "AgentStudio.t8.damping.local")
    try WorkspaceCoreMigrations.migrate(coreQueue)
    try WorkspaceLocalMigrations.migrate(localQueue)
    let coreRepository = WorkspaceCoreRepository(databaseWriter: coreQueue)
    let localRepositoryFactory = FailingThenSucceedingLocalRepositoryFactory(
        localQueue: localQueue,
        failuresBeforeSuccess: 1
    )
    let retainedLocalFailure: WorkspaceSQLiteDatastoreFailure
    do {
        _ = try localRepositoryFactory.makeLocalRepository(workspaceId: workspaceId)
        Issue.record("expected injected local preparation to fail")
        return nil
    } catch {
        retainedLocalFailure = .init(error)
    }
    let sqliteDatastore = try await preparedWorkspaceSQLiteDatastore(
        coreRepository: coreRepository,
        localUnavailable: retainedLocalFailure,
        probe: { event in
            await saveProbe.record(event)
        }
    )
    let preparation = await sqliteDatastore.prepareDatabasesForBoot()
    guard case .prepared(let preparationReceipt) = preparation else {
        Issue.record("expected core preparation to succeed")
        return nil
    }
    guard case .unavailable = preparationReceipt.local else {
        Issue.record("expected injected local preparation to be unavailable")
        return nil
    }
    return (sqliteDatastore, localRepositoryFactory)
}

private actor WorkspaceSQLiteSaveProbe {
    private var saveEvents: Int = 0
    private var succeededSaveEvents: Int = 0
    private var failedSaveEvents: Int = 0

    var saveCount: Int {
        saveEvents
    }

    var succeededSaveCount: Int {
        succeededSaveEvents
    }

    var failedSaveCount: Int {
        failedSaveEvents
    }

    func record(_ event: WorkspaceSQLiteDatastoreActor.ProbeEvent) {
        switch event {
        case .saveWorkspaceSnapshot:
            saveEvents += 1
        case .saveWorkspaceSnapshotSucceeded:
            succeededSaveEvents += 1
        case .saveWorkspaceSnapshotFailed:
            failedSaveEvents += 1
        case .loadWorkspaceSnapshot:
            break
        }
    }

}

private final class FailingThenSucceedingLocalRepositoryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let localQueue: DatabaseQueue
    private let failuresBeforeSuccess: Int
    private var attempts: Int = 0

    init(localQueue: DatabaseQueue, failuresBeforeSuccess: Int) {
        self.localQueue = localQueue
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    var openAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func makeLocalRepository(workspaceId requestedWorkspaceId: UUID) throws -> WorkspaceLocalRepository {
        lock.lock()
        attempts += 1
        let shouldFail = attempts <= failuresBeforeSuccess
        lock.unlock()

        if shouldFail {
            throw CocoaError(.fileNoSuchFile)
        }
        return WorkspaceLocalRepository(workspaceId: requestedWorkspaceId, databaseWriter: localQueue)
    }
}

@MainActor
private func yieldMainActor(times count: Int) async {
    for _ in 0..<count {
        await Task.yield()
    }
}
