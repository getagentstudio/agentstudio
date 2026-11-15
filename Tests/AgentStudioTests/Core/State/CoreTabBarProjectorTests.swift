import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
final class CoreTabBarProjectorTests {
    private let coreAtoms: CoreAtoms
    private let store: WorkspaceStore

    init() {
        coreAtoms = makeInstalledTestCoreAtoms()
        store = WorkspaceStore(
            identityAtom: coreAtoms.workspaceIdentity,
            windowMemoryAtom: coreAtoms.workspaceWindowMemory,
            repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
            paneAtom: coreAtoms.workspacePane,
            tabLayoutAtom: coreAtoms.workspaceTabLayout
        )
    }

    @Test
    func projectorMatchesCurrentReadersForTitlesOrderingAndActiveFallback() throws {
        try withTestCoreAtoms(using: coreAtoms) { _ in
            let customPane = store.createPane(title: "Ignored custom pane title")
            let customTab = Tab(paneId: customPane.id, name: "  Custom\nWorkspace  ")
            store.appendTab(customTab)

            let runtimePane = store.createPane(title: "  Runtime title  ")
            let runtimeTab = Tab(paneId: runtimePane.id, name: "Tab")
            store.appendTab(runtimeTab)

            let emptyPane = store.createPane(title: "   ")
            let emptyTab = Tab(paneId: emptyPane.id, name: "Tab")
            store.appendTab(emptyTab)
            store.setActiveTab(nil)

            let projection = try projectCurrentState()

            #expect(projection.items.map(\.id) == [customTab.id, runtimeTab.id, emptyTab.id])
            #expect(projection.items.map(\.displayTitle) == ["Custom Workspace", "Runtime title", "Terminal"])
            #expect(projection.activeTabId == emptyTab.id)
            assertCurrentReaderParity(projection)
        }
    }

    @Test
    func projectorMatchesWorktreeAndEnrichmentTitlePrecedence() throws {
        try withTestCoreAtoms(using: coreAtoms) { _ in
            let repo = store.addRepo(at: URL(filePath: "/tmp/core-tab-bar-title/agent-studio"))
            let matchingMainWorktree = repo.worktrees.first { $0.isMainWorktree }
            let mainWorktree = try #require(matchingMainWorktree)
            let linkedWorktree = Worktree(
                repoId: repo.id,
                name: "feature-title",
                path: URL(filePath: "/tmp/core-tab-bar-title/agent-studio-feature"),
                isMainWorktree: false
            )
            store.reconcileDiscoveredWorktrees(repo.id, worktrees: [mainWorktree, linkedWorktree])
            coreAtoms.repoCache.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: linkedWorktree.id,
                    repoId: repo.id,
                    branch: "feature/off-main-title"
                )
            )

            let enrichedPane = store.createPane(
                launchDirectory: linkedWorktree.path,
                title: "Ignored runtime title",
                facets: PaneContextFacets(
                    repoId: repo.id,
                    worktreeId: linkedWorktree.id,
                    cwd: linkedWorktree.path
                )
            )
            let enrichedTab = Tab(paneId: enrichedPane.id)
            store.appendTab(enrichedTab)

            let detachedPane = store.createPane(
                launchDirectory: mainWorktree.path,
                title: "Also ignored",
                facets: PaneContextFacets(
                    repoId: repo.id,
                    worktreeId: mainWorktree.id,
                    cwd: mainWorktree.path
                )
            )
            let detachedTab = Tab(paneId: detachedPane.id)
            store.appendTab(detachedTab)

            let projection = try projectCurrentState()

            #expect(projection.items[0].displayTitle == "agent-studio-feature · feature/off-main-title")
            #expect(projection.items[1].displayTitle == mainWorktree.path.lastPathComponent)
            assertCurrentReaderParity(projection)
        }
    }

    @Test
    func keyedCaptureIgnoresUnrelatedEnrichmentAndInvalidatesForItsWorktree() throws {
        try withTestCoreAtoms(using: coreAtoms) { _ in
            let observedRepo = store.addRepo(at: URL(filePath: "/tmp/core-tab-bar-observed-enrichment"))
            let observedWorktree = try #require(observedRepo.worktrees.first)
            let unrelatedRepo = store.addRepo(at: URL(filePath: "/tmp/core-tab-bar-unrelated-enrichment"))
            let unrelatedWorktree = try #require(unrelatedRepo.worktrees.first)
            let pane = store.createPane(
                launchDirectory: observedWorktree.path,
                facets: PaneContextFacets(cwd: observedWorktree.path)
            )
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            let invalidation = CoreTabBarProjectionObservationFlag()

            withObservationTracking {
                _ = CoreTabBarProjectionRequest.capture(
                    tabId: tab.id,
                    store: store,
                    repoCache: coreAtoms.repoCache
                )
            } onChange: {
                invalidation.record()
            }

            coreAtoms.repoCache.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: unrelatedWorktree.id,
                    repoId: unrelatedRepo.id,
                    branch: "unrelated/change"
                )
            )
            #expect(!invalidation.didFire)

            coreAtoms.repoCache.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: observedWorktree.id,
                    repoId: observedRepo.id,
                    branch: "observed/change"
                )
            )
            #expect(invalidation.didFire)
        }
    }

    @Test
    func projectorUsesTopologySnapshotForNestedPathPrecedenceAndFallback() throws {
        try withTestCoreAtoms(using: coreAtoms) { _ in
            let repositoryPath = URL(filePath: "/tmp/core-tab-bar-nested/repository")
            let repository = store.addRepo(at: repositoryPath)
            let mainWorktree = try #require(repository.worktrees.first { $0.isMainWorktree })
            let nestedWorktree = Worktree(
                repoId: repository.id,
                name: "Nested Feature Display",
                path: repositoryPath.appending(path: "worktrees/nested-feature")
            )
            store.reconcileDiscoveredWorktrees(
                repository.id,
                worktrees: [mainWorktree, nestedWorktree]
            )
            let nestedCWD = nestedWorktree.path.appending(path: "Sources/Feature")
            let snapshot = store.repositoryTopologyAtom.captureReadSnapshot()

            let snapshotAssociation = try snapshot.repoAndWorktree(
                containing: nestedCWD,
                cancellationCheck: {}
            )
            let currentAssociation = store.repositoryTopologyAtom.repoAndWorktree(containing: nestedCWD)

            #expect(snapshotAssociation?.repo.id == currentAssociation?.repo.id)
            #expect(snapshotAssociation?.worktree.id == nestedWorktree.id)

            let pane = store.createPane(
                launchDirectory: nestedCWD,
                title: "Path fallback",
                facets: PaneContextFacets(cwd: nestedCWD)
            )
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)

            let projection = try projectCurrentState()
            let item = try #require(projection.items.first { $0.id == tab.id })

            #expect(item.displayTitle == nestedWorktree.path.lastPathComponent)
            #expect(item.activePaneCount == 1)
            assertCurrentReaderParity(projection)
        }
    }

    @Test
    func projectorTracksUnavailableThenReavailablePathRoots() throws {
        try withTestCoreAtoms(using: coreAtoms) { _ in
            let repositoryPath = URL(filePath: "/tmp/core-tab-bar-availability/repository")
            let repository = store.addRepo(at: repositoryPath)
            let paneCWD = repositoryPath.appending(path: "Sources")
            let pane = store.createPane(
                launchDirectory: paneCWD,
                title: "Unavailable fallback",
                facets: PaneContextFacets(cwd: paneCWD)
            )
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)

            let availableProjection = try projectCurrentState()
            #expect(availableProjection.items.first?.displayTitle == repositoryPath.lastPathComponent)
            assertCurrentReaderParity(availableProjection)

            store.markRepoUnavailable(repository.id)

            let unavailableSnapshot = store.repositoryTopologyAtom.captureReadSnapshot()
            #expect(
                try unavailableSnapshot.repoAndWorktree(
                    containing: paneCWD,
                    cancellationCheck: {}
                ) == nil
            )
            let unavailableProjection = try projectCurrentState()
            #expect(unavailableProjection.items.first?.displayTitle == "Unavailable fallback")
            assertCurrentReaderParity(unavailableProjection)

            _ = store.addRepo(at: repositoryPath)

            let reavailableSnapshot = store.repositoryTopologyAtom.captureReadSnapshot()
            let reavailableAssociation = try reavailableSnapshot.repoAndWorktree(
                containing: paneCWD,
                cancellationCheck: {}
            )
            let reavailableProjection = try projectCurrentState()

            #expect(reavailableAssociation?.repo.id == repository.id)
            #expect(reavailableProjection.items.first?.displayTitle == repositoryPath.lastPathComponent)
            assertCurrentReaderParity(reavailableProjection)
        }
    }

    @Test
    func topologySnapshotChecksCancellationForEachPathEntry() {
        withTestCoreAtoms(using: coreAtoms) { _ in
            let repositoryPath = URL(filePath: "/tmp/core-tab-bar-snapshot-cancellation/repository")
            let repository = store.addRepo(at: repositoryPath)
            let mainWorktree = repository.worktrees[0]
            let linkedWorktree = Worktree(
                repoId: repository.id,
                name: "linked",
                path: repositoryPath.appending(path: "linked")
            )
            store.reconcileDiscoveredWorktrees(
                repository.id,
                worktrees: [mainWorktree, linkedWorktree]
            )
            let snapshot = store.repositoryTopologyAtom.captureReadSnapshot()
            var cancellationCheckCount = 0
            func cancelOnSecondPathEntry() throws(CancellationError) {
                cancellationCheckCount += 1
                guard cancellationCheckCount == 2 else { return }
                throw CancellationError()
            }

            #expect(throws: CancellationError.self) {
                try snapshot.repoAndWorktree(
                    containing: URL(filePath: "/tmp/core-tab-bar-snapshot-cancellation/unmatched"),
                    cancellationCheck: cancelOnSecondPathEntry
                )
            }
            #expect(cancellationCheckCount == 2)
        }
    }

    @Test
    func projectorReportsDefaultAndCustomArrangementPresentationWithoutZoom() throws {
        try withTestCoreAtoms(using: coreAtoms) { _ in
            let pane = store.createPane()
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)

            let defaultProjection = try projectCurrentState()
            let defaultItem = try #require(defaultProjection.items.first)
            #expect(defaultItem.activeArrangementName == "Default")
            #expect(defaultItem.activeArrangementBadgeNumber == nil)

            let firstCustomId = try #require(store.createArrangement(name: "Review", inTab: tab.id))
            store.switchArrangement(to: firstCustomId, inTab: tab.id)
            let firstCustomProjection = try projectCurrentState()
            let firstCustomItem = try #require(firstCustomProjection.items.first)
            let firstCustomTab = try #require(store.tabLayoutAtom.tab(tab.id))
            #expect(firstCustomItem.activeArrangementName == "Review")
            #expect(firstCustomItem.activeArrangementBadgeNumber == 1)
            #expect(
                firstCustomItem.activeArrangementBadgeNumber
                    == ArrangementDerived.activeArrangementBadgeNumber(for: firstCustomTab)
            )

            let secondCustomId = try #require(store.createArrangement(name: "Build", inTab: tab.id))
            store.switchArrangement(to: secondCustomId, inTab: tab.id)
            let secondCustomProjection = try projectCurrentState()
            let secondCustomItem = try #require(secondCustomProjection.items.first)
            let secondCustomTab = try #require(store.tabLayoutAtom.tab(tab.id))
            #expect(secondCustomItem.activeArrangementName == "Build")
            #expect(secondCustomItem.activeArrangementBadgeNumber == 2)
            #expect(
                secondCustomItem.activeArrangementBadgeNumber
                    == ArrangementDerived.activeArrangementBadgeNumber(for: secondCustomTab)
            )
        }
    }

    @Test
    func projectorReportsSecondPaneAsZoomSourceOrdinal() throws {
        try withTestCoreAtoms(using: coreAtoms) { _ in
            let firstPane = store.createPane(title: "First")
            let secondPane = store.createPane(title: "Second")
            let tab = Tab(paneId: firstPane.id)
            store.appendTab(tab)
            #expect(
                store.insertPane(
                    secondPane.id,
                    inTab: tab.id,
                    at: firstPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            coreAtoms.workspacePanePresentation.enterZoom(
                inTab: tab.id,
                sourcePaneId: secondPane.id,
                viewerPresentation: .retryable
            )

            let projection = try projectCurrentState()
            let item = try #require(projection.items.first)

            #expect(item.zoomSourcePaneOrdinal == 2)
        }
    }

    @Test
    func projectorMatchesArrangementPaneAndZoomFacts() async throws {
        try await withAsyncTestCoreAtoms(using: coreAtoms) { _ in
            let firstPane = store.createPane(title: "First")
            let secondPane = store.createPane(
                content: .codeViewer(
                    CodeViewerState(
                        filePath: URL(filePath: "/tmp/example.swift"),
                        scrollToLine: nil
                    )
                ),
                metadata: PaneMetadata(title: "Second")
            )
            let tab = Tab(paneId: firstPane.id)
            store.appendTab(tab)
            #expect(
                store.insertPane(
                    secondPane.id,
                    inTab: tab.id,
                    at: firstPane.id,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            )
            let customArrangementId = try #require(store.createArrangement(name: "Review", inTab: tab.id))
            store.switchArrangement(to: customArrangementId, inTab: tab.id)
            #expect(store.minimizePane(secondPane.id, inTab: tab.id))
            coreAtoms.workspacePanePresentation.enterZoom(
                inTab: tab.id,
                sourcePaneId: firstPane.id,
                viewerPresentation: .retryable
            )

            let projection = try projectCurrentState()
            let item = try #require(projection.items.first)

            #expect(item.isSplit)
            #expect(item.arrangementCount == 2)
            #expect(item.activeArrangementName == "Review")
            #expect(item.zoomSourcePaneOrdinal == 1)
            #expect(item.activeArrangementBadgeNumber == nil)
            #expect(item.minimizedCount == 1)
            #expect(item.paneIds == [firstPane.id, secondPane.id])
            #expect(item.activePaneCount == 2)
            let table = try await ArrangementTableProjector.project(
                ArrangementPanelSources(store: store, repoCache: coreAtoms.repoCache).capture(tabId: tab.id))
            #expect(table.panes.map(\.id) == [firstPane.id, secondPane.id])
            #expect(table.panes.first(where: { $0.id == secondPane.id })?.isMinimized == true)
            #expect(table.panes.first(where: { $0.id == firstPane.id })?.supportsZoom == true)
            #expect(table.panes.first(where: { $0.id == secondPane.id })?.supportsZoom == false)
            #expect(table.zoomMode?.sourcePaneId == firstPane.id)
            #expect(item.zoomMode?.sourcePaneId == firstPane.id)
            #expect(item.arrangements.first(where: { $0.id == customArrangementId })?.isActive == true)
            assertCurrentReaderParity(projection)
        }
    }

    @Test
    func projectorPropagatesCancellationFromVariableCardinalityWork() {
        withTestCoreAtoms(using: coreAtoms) { _ in
            let repositoryPath = URL(filePath: "/tmp/core-tab-bar-cancellation/repository")
            let repository = store.addRepo(at: repositoryPath)
            let mainWorktree = repository.worktrees[0]
            store.reconcileDiscoveredWorktrees(
                repository.id,
                worktrees: [
                    mainWorktree,
                    Worktree(
                        repoId: repository.id,
                        name: "first-linked",
                        path: repositoryPath.appending(path: "first-linked")
                    ),
                    Worktree(
                        repoId: repository.id,
                        name: "second-linked",
                        path: repositoryPath.appending(path: "second-linked")
                    ),
                ]
            )
            let pane = store.createPane(
                launchDirectory: URL(filePath: "/tmp/core-tab-bar-cancellation/unmatched"),
                facets: PaneContextFacets(cwd: URL(filePath: "/tmp/core-tab-bar-cancellation/unmatched"))
            )
            store.appendTab(Tab(paneId: pane.id))
            let request = CoreTabBarProjectionRequest.capture(store: store, repoCache: coreAtoms.repoCache)
            var cancellationCheckCount = 0
            func cancel() throws(CancellationError) {
                cancellationCheckCount += 1
                guard cancellationCheckCount >= 3 else { return }
                throw CancellationError()
            }

            #expect(throws: CancellationError.self) {
                try CoreTabBarProjector.project(request, cancellationCheck: cancel)
            }
            #expect(cancellationCheckCount == 3)
        }
    }

    private func projectCurrentState() throws -> CoreTabBarProjection {
        let request = CoreTabBarProjectionRequest.capture(store: store, repoCache: coreAtoms.repoCache)
        return try CoreTabBarProjector.project(request)
    }

    private func assertCurrentReaderParity(_ projection: CoreTabBarProjection) {
        let currentTabs = store.tabLayoutAtom.tabs
        #expect(projection.items.count == currentTabs.count)

        for (item, tab) in zip(projection.items, currentTabs) {
            let displayTitle = TabDisplayDerived().displayTitle(
                for: tab,
                workspacePane: store.paneAtom,
                workspaceRepositoryTopology: store.repositoryTopologyAtom,
                repoCache: coreAtoms.repoCache
            )
            let arrangementDerived = ArrangementDerived()
            let zoomPresentation = store.panePresentationAtom.zoomPresentation(forTab: tab.id)

            #expect(item.id == tab.id)
            #expect(item.title == displayTitle)
            #expect(item.displayTitle == displayTitle)
            #expect(item.isSplit == tab.isSplit)
            #expect(item.colorHex == tab.colorHex)
            #expect(item.activePaneCount == tab.activeArrangement.layout.panes.count)
            #expect(item.zoomMode == arrangementDerived.zoomMode(for: tab.id))
            #expect(item.arrangements == arrangementDerived.arrangementItems(for: tab.id))
            #expect(item.minimizedCount == tab.activeMinimizedPaneIds.count)
            #expect(item.arrangementCount == tab.arrangements.count)
            #expect(item.paneIds == tab.allPaneIds)
            #expect(
                item.activeArrangementBadgeNumber
                    == (zoomPresentation == nil ? ArrangementDerived.activeArrangementBadgeNumber(for: tab) : nil)
            )
        }

        #expect(projection.activeTabId == (store.tabLayoutAtom.activeTabId ?? projection.items.last?.id))
    }

}

private final class CoreTabBarProjectionObservationFlag: Sendable {
    private let state = Mutex(false)

    var didFire: Bool {
        state.withLock { $0 }
    }

    func record() {
        state.withLock { $0 = true }
    }
}
