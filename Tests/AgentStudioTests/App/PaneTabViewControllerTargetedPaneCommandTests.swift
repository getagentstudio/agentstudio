import Foundation
import Observation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerTargetedPaneCommandTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private final class ObservationInvalidationFlag: @unchecked Sendable {
        var didFire = false
    }

    @Test("management toggle capability does not depend on tab presentation")
    func managementToggleCapabilityDoesNotObserveTabPresentation() async {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        await withWorkspaceCommandHarness(harness) {
            let pane = harness.store.createPane()
            let tab = Tab(paneId: pane.id, name: "Before")
            harness.store.appendTab(tab)
            let invalidation = ObservationInvalidationFlag()

            let enabled = withObservationTracking {
                harness.controller.canExecute(.toggleManagementLayer)
            } onChange: {
                invalidation.didFire = true
            }
            #expect(enabled)

            harness.store.tabLayoutAtom.renameTab(tab.id, name: "After")

            #expect(!invalidation.didFire)
            #expect(harness.controller.canExecute(.toggleManagementLayer))
        }
    }

    @Test("targeted pane capability ignores unrelated repository topology changes")
    func canExecutePaneCommand_doesNotObserveRepositoryTopology() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane()
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        let invalidation = ObservationInvalidationFlag()

        withObservationTracking {
            _ = harness.controller.canExecute(
                .closePane,
                target: pane.id,
                targetType: .pane
            )
        } onChange: {
            invalidation.didFire = true
        }

        let repositoryPath = harness.tempDir.appending(path: "unrelated-repository")
        _ = harness.store.addRepo(at: repositoryPath)

        #expect(!invalidation.didFire)
    }

    @Test("targeted main-pane mutations reject Zoom")
    func targetedMainPaneMutations_zoomedTab_reject() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane()
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: pane.id,
            viewerPresentation: .unavailable
        )

        #expect(
            !harness.controller.canExecute(
                .minimizePane,
                target: pane.id,
                targetType: .pane
            )
        )
        #expect(
            !harness.controller.canExecute(
                .splitRight,
                target: pane.id,
                targetType: .pane
            )
        )
    }

    @Test("targeted Extract Pane requires more than one visible pane")
    func extractPaneToTabCapability_requiresMultipleVisiblePanes() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)

        #expect(
            !harness.controller.canExecute(
                .extractPaneToTab,
                target: sourcePane.id,
                targetType: .pane
            )
        )

        let secondPane = harness.store.createPane()
        #expect(
            harness.store.insertPane(
                secondPane.id,
                inTab: tab.id,
                at: sourcePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )

        #expect(
            harness.controller.canExecute(
                .extractPaneToTab,
                target: sourcePane.id,
                targetType: .pane
            )
        )
    }

    @Test("targeted Detach Drawer Pane accepts only an owned drawer child with a visible parent")
    func detachDrawerPaneCapability_requiresOwnedChildAndVisibleParent() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let parentPane = harness.store.createPane()
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

        #expect(
            harness.controller.canExecute(
                .detachDrawerPane,
                target: drawerPane.id,
                targetType: .pane
            )
        )
        #expect(
            !harness.controller.canExecute(
                .detachDrawerPane,
                target: parentPane.id,
                targetType: .pane
            )
        )

        #expect(harness.store.minimizePane(parentPane.id, inTab: tab.id))
        #expect(
            !harness.controller.canExecute(
                .detachDrawerPane,
                target: drawerPane.id,
                targetType: .pane
            )
        )
    }

    @Test("targeted Add Drawer Pane accepts a visible main pane only")
    func addDrawerPaneCapability_requiresVisibleMainPane() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let parentPane = harness.store.createPane()
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

        #expect(
            harness.controller.canExecute(
                .addDrawerPane,
                target: parentPane.id,
                targetType: .pane
            )
        )
        #expect(
            !harness.controller.canExecute(
                .addDrawerPane,
                target: drawerPane.id,
                targetType: .pane
            )
        )
    }

    @Test("targeted Expand Pane restores a minimized main pane")
    func expandPane_minimizedMainPane_restoresPane() async {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        await withWorkspaceCommandHarness(harness) {
            let pane = harness.store.createPane()
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            #expect(harness.store.minimizePane(pane.id, inTab: tab.id))

            #expect(
                harness.controller.canExecute(
                    .expandPane,
                    target: pane.id,
                    targetType: .pane
                )
            )

            harness.controller.execute(
                .expandPane,
                target: pane.id,
                targetType: .pane
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.tab(tab.id)?.activeMinimizedPaneIds.contains(pane.id) == false)
        }
    }

    @Test("targeted Expand Pane restores a minimized drawer child")
    func expandPane_minimizedDrawerChild_restoresPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
            #expect(harness.store.minimizeDrawerPane(drawerPane.id, in: parentPane.id))

            #expect(
                harness.controller.canExecute(
                    .expandPane,
                    target: drawerPane.id,
                    targetType: .pane
                )
            )

            harness.controller.execute(
                .expandPane,
                target: drawerPane.id,
                targetType: .pane
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(
                harness.store.drawerView(forParent: parentPane.id)?.minimizedPaneIds.contains(drawerPane.id) == false)
        }
    }

    @Test("targeted Minimize Pane minimizes a visible main pane")
    func minimizePane_visibleMainPane_minimizesPane() async {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        await withWorkspaceCommandHarness(harness) {
            let pane = harness.store.createPane()
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)

            #expect(
                harness.controller.canExecute(
                    .minimizePane,
                    target: pane.id,
                    targetType: .pane
                )
            )

            harness.controller.execute(
                .minimizePane,
                target: pane.id,
                targetType: .pane
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.tab(tab.id)?.activeMinimizedPaneIds.contains(pane.id) == true)
        }
    }

    @Test("targeted Minimize Pane minimizes a visible drawer child")
    func minimizePane_visibleDrawerChild_minimizesPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

            #expect(
                harness.controller.canExecute(
                    .minimizePane,
                    target: drawerPane.id,
                    targetType: .pane
                )
            )

            harness.controller.execute(
                .minimizePane,
                target: drawerPane.id,
                targetType: .pane
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(
                harness.store.drawerView(forParent: parentPane.id)?.minimizedPaneIds.contains(drawerPane.id) == true)
        }
    }

    @Test("targeted Toggle Drawer accepts the owned main pane and rejects its drawer child")
    func toggleDrawer_ownedMainPane_togglesOnlyParent() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
            let drawer = try #require(harness.store.pane(parentPane.id)?.drawer)
            let wasExpanded = drawer.isExpanded

            #expect(
                harness.controller.canExecute(
                    .toggleDrawer,
                    target: parentPane.id,
                    targetType: .pane
                )
            )
            #expect(
                !harness.controller.canExecute(
                    .toggleDrawer,
                    target: drawerPane.id,
                    targetType: .pane
                )
            )

            harness.controller.execute(
                .toggleDrawer,
                target: parentPane.id,
                targetType: .pane
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.pane(parentPane.id)?.drawer?.isExpanded == !wasExpanded)
        }
    }

    @Test("targeted Close Pane removes an owned drawer child")
    func closePane_ownedDrawerChild_removesPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        try await withWorkspaceCommandHarness(harness) {
            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

            #expect(
                harness.controller.canExecute(
                    .closePane,
                    target: drawerPane.id,
                    targetType: .pane
                )
            )

            harness.controller.execute(
                .closePane,
                target: drawerPane.id,
                targetType: .pane
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.pane(drawerPane.id) == nil)
            #expect(harness.store.pane(parentPane.id) != nil)
        }
    }

    @Test("targeted pane location commands use the exact drawer child path")
    func paneLocationCommands_drawerChild_useTargetPath() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let parentDirectory = harness.tempDir.appending(path: "parent")
        let drawerDirectory = harness.tempDir.appending(path: "drawer")
        let parentPane = harness.store.createPane(
            launchDirectory: parentDirectory,
            facets: PaneContextFacets(cwd: parentDirectory)
        )
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
        harness.store.paneAtom.updatePaneCWD(drawerPane.id, cwd: drawerDirectory)

        for command in [
            AppCommand.openPaneLocationInFinder,
            .copyCurrentPanePath,
            .openPaneLocationInEditorMenu,
        ] {
            #expect(
                harness.controller.canExecute(
                    command,
                    target: drawerPane.id,
                    targetType: .pane
                )
            )
        }

        harness.controller.execute(
            .openPaneLocationInFinder,
            target: drawerPane.id,
            targetType: .pane
        )
        harness.controller.execute(
            .copyCurrentPanePath,
            target: drawerPane.id,
            targetType: .pane
        )
        harness.controller.execute(
            .openPaneLocationInEditorMenu,
            target: drawerPane.id,
            targetType: .pane
        )

        #expect(harness.launchRecorder.revealedPaths.map(\.path) == [drawerDirectory.path])
        #expect(harness.launchRecorder.copiedPaths.map(\.path) == [drawerDirectory.path])
        #expect(harness.atomRegistry.editorChooser.openForPaneId == drawerPane.id)
        #expect(harness.atomRegistry.editorChooser.availableTargets.map(\.id) == ["cursor", "vscode"])
    }

    @Test("targeted pane commands reject stale pane identities")
    func targetedPaneCommands_stalePane_rejectWithoutSideEffects() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let stalePaneId = UUID()

        for command in [
            AppCommand.expandPane,
            .minimizePane,
            .toggleDrawer,
            .openPaneLocationInFinder,
            .copyCurrentPanePath,
            .openPaneLocationInEditorMenu,
        ] {
            #expect(
                !harness.controller.canExecute(
                    command,
                    target: stalePaneId,
                    targetType: .pane
                )
            )
            harness.controller.execute(
                command,
                target: stalePaneId,
                targetType: .pane
            )
        }

        #expect(harness.launchRecorder.revealedPaths.isEmpty)
        #expect(harness.launchRecorder.copiedPaths.isEmpty)
        #expect(harness.atomRegistry.editorChooser.openForPaneId == nil)
    }

    @Test("targeted Open PR opens only the exact PR URL for that pane")
    func openPullRequest_exactPane_opensExactURL() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let repo = harness.store.addRepo(at: harness.tempDir.appending(path: "repo"))
        let worktree = try #require(
            harness.store.repos.first(where: { $0.id == repo.id })?.worktrees.first
        )
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(
                repoId: repo.id,
                worktreeId: worktree.id,
                cwd: worktree.path
            )
        )
        harness.store.appendTab(Tab(paneId: pane.id))
        harness.repoCache.setWorktreeEnrichment(
            WorktreeEnrichment(
                worktreeId: worktree.id,
                repoId: repo.id,
                branch: "feature/pr-command"
            )
        )
        let branchKey = try #require(
            RepoBranchKey(repoId: repo.id, branch: "feature/pr-command")
        )
        let exactURL = try #require(
            URL(string: "https://github.com/ShravanSunder/agentstudio/pull/264")
        )
        harness.repoCache.applyPullRequestFacts([
            branchKey: PullRequestFacts(openCount: 1, exactOpenURL: exactURL)
        ])

        #expect(
            harness.controller.canExecute(
                .openPullRequest,
                target: pane.id,
                targetType: .pane
            )
        )

        harness.controller.execute(
            .openPullRequest,
            target: pane.id,
            targetType: .pane
        )

        #expect(harness.launchRecorder.openedExternalURLs == [exactURL])
        #expect(
            !harness.controller.canExecute(
                .openPullRequest,
                target: UUID(),
                targetType: .pane
            )
        )
    }

    @Test("targeted Move Pane capability requires an owned source and nonempty alternate tab")
    func movePaneToTabCapability_requiresOwnedSourceAndNonemptyAlternateTab() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let sourcePane = harness.store.createPane()
        let sourceTab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(sourceTab)
        harness.store.setActiveTab(sourceTab.id)

        #expect(
            !harness.controller.canExecute(
                .movePaneToTab,
                target: sourcePane.id,
                targetType: .pane
            )
        )

        let destinationPane = harness.store.createPane()
        let destinationTab = Tab(paneId: destinationPane.id)
        harness.store.appendTab(destinationTab)

        #expect(
            harness.controller.canExecute(
                .movePaneToTab,
                target: sourcePane.id,
                targetType: .pane
            )
        )
        #expect(
            !harness.controller.canExecute(
                .movePaneToTab,
                target: UUID(),
                targetType: .pane
            )
        )
    }

    @Test("Move Pane routes the source pane to the selected nonempty destination")
    func movePaneToTab_selectedDestination_receivesSourcePane() async {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        await withWorkspaceCommandHarness(harness) {
            let sourcePane = harness.store.createPane()
            let sourceTab = Tab(paneId: sourcePane.id)
            let otherDestinationPane = harness.store.createPane()
            let otherDestinationTab = Tab(paneId: otherDestinationPane.id)
            let selectedDestinationPane = harness.store.createPane()
            let selectedDestinationTab = Tab(paneId: selectedDestinationPane.id)
            harness.store.appendTab(sourceTab)
            harness.store.appendTab(otherDestinationTab)
            harness.store.appendTab(selectedDestinationTab)
            harness.store.setActiveTab(sourceTab.id)

            harness.controller.executeMovePaneToTab(
                sourcePaneId: sourcePane.id,
                sourceTabId: sourceTab.id,
                targetTabId: selectedDestinationTab.id
            )
            _ = await harness.executor.submitGesture { _ in true }.value

            #expect(harness.store.tab(selectedDestinationTab.id)?.activePaneIds.contains(sourcePane.id) == true)
            #expect(harness.store.tab(otherDestinationTab.id)?.activePaneIds.contains(sourcePane.id) == false)
        }
    }

    @Test("Move Pane presentation enables with a destination and rechecks before activation")
    func movePaneToTabPresentation_managementModeEndsBeforeActivation_doesNotMove() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let sourcePane = harness.store.createPane()
        let sourceTab = Tab(paneId: sourcePane.id)
        let destinationPane = harness.store.createPane()
        let destinationTab = Tab(paneId: destinationPane.id)
        harness.store.appendTab(sourceTab)
        harness.store.appendTab(destinationTab)
        harness.store.setActiveTab(sourceTab.id)

        try await withCommandDispatcher(
            harness.commandDispatcher,
            body: { dispatcher in
                atom(\.managementLayer).activate()
                defer { atom(\.managementLayer).deactivate() }
                let presentation = try #require(
                    PaneLeafCommandPresentation.resolve(
                        command: .movePaneToTab,
                        surface: .inlineControl,
                        targetPaneId: sourcePane.id,
                        dispatcher: dispatcher
                    )
                )
                #expect(presentation.isEnabled)

                atom(\.managementLayer).deactivate()
                presentation.movePane(
                    sourceTabId: sourceTab.id,
                    targetTabId: destinationTab.id
                )

                #expect(harness.store.tab(sourceTab.id)?.activePaneIds.contains(sourcePane.id) == true)
                #expect(harness.store.tab(destinationTab.id)?.activePaneIds.contains(sourcePane.id) == false)
            }
        )
    }
}
