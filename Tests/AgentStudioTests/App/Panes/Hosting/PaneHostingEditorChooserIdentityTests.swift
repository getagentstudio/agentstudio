import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioTestSupport

@MainActor
@Suite("Pane hosting editor chooser identity")
struct PaneHostingEditorChooserIdentityTests {
    @Test("main and drawer pane leaves receive the exact App root editor chooser")
    func mainAndDrawerPaneLeavesReceiveExactAppRootEditorChooser() throws {
        let atomRegistry = makeTestAtomRegistry()
        try withTestCoreAtoms(using: atomRegistry.core) { coreAtoms in
            // Arrange
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                windowMemoryAtom: coreAtoms.workspaceWindowMemory,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
                paneAtom: coreAtoms.workspacePane,
                tabLayoutAtom: coreAtoms.workspaceTabLayout,
                mutationCoordinator: coreAtoms.workspaceMutationCoordinator
            )
            let mainPane = store.createPane()
            let tab = Tab(paneId: mainPane.id)
            store.appendTab(tab)
            let drawerPane = try #require(store.addDrawerPane(to: mainPane.id))
            let dispatcher = PaneTabActionDispatcher(
                dispatch: { _ in },
                shouldHandleSplitDragPayload: { _ in false },
                shouldAcceptDrop: { _, _, _, _ in false },
                handleDrop: { _, _, _, _ in }
            )

            // Act
            let mainPaneLeaf = makePaneLeaf(
                paneId: mainPane.id,
                tabId: tab.id,
                store: store,
                editorChooser: atomRegistry.editorChooser,
                dispatcher: dispatcher
            )
            let drawerPaneLeaf = makePaneLeaf(
                paneId: drawerPane.id,
                tabId: tab.id,
                store: store,
                editorChooser: atomRegistry.editorChooser,
                dispatcher: dispatcher
            )

            // Assert
            #expect(mainPaneLeaf.editorChooser === atomRegistry.editorChooser)
            #expect(drawerPaneLeaf.editorChooser === atomRegistry.editorChooser)
        }
    }

    private func makePaneLeaf(
        paneId: UUID,
        tabId: UUID,
        store: WorkspaceStore,
        editorChooser: EditorChooserState,
        dispatcher: PaneTabActionDispatcher
    ) -> PaneLeafContainer {
        PaneLeafContainer(
            paneHost: PaneHostView(paneId: paneId),
            octiconLoader: makeTestOcticonLoader(),
            tabId: tabId,
            isActive: true,
            isSplit: false,
            isSplitResizing: false,
            store: store,
            repoCache: RepoCacheAtom(),
            editorChooser: editorChooser,
            closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
            actionDispatcher: dispatcher,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), onPaneFocusTrigger: { _ in },
            onOpenPaneGitHub: { _ in },
            toolbarPresentation: .hidden
        )
    }
}
