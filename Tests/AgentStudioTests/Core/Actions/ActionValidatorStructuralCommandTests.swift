import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite(.serialized)
struct ActionValidatorStructuralCommandTests {
    @Test("structural split commands validate against layout split even when one pane is hidden")
    func structuralSplitCommandsUseLayoutSplit() {
        let tabId = UUID()
        let primaryPaneId = UUIDv7.generate()
        let hiddenPaneId = UUIDv7.generate()
        let tab = makeSplitTabWithHiddenPane(
            tabId: tabId,
            primaryPaneId: primaryPaneId,
            hiddenPaneId: hiddenPaneId
        )
        let snapshot = WorkspaceCommandResolver.snapshot(
            from: [tab],
            activeTabId: tabId,
            isManagementLayerActive: false,
            visiblePaneIds: { _ in [primaryPaneId] }
        )

        let breakUpResult = WorkspaceCommandValidator.validate(.breakUpTab(tabId: tabId), state: snapshot)
        let equalizeResult = WorkspaceCommandValidator.validate(.equalizePanes(tabId: tabId), state: snapshot)

        #expect((try? breakUpResult.get()) != nil)
        #expect((try? equalizeResult.get()) != nil)
    }

    @Test("existing pane insert request allows same-tab pane moves")
    func existingPaneInsertAllowsSameTabPaneMoves() {
        let tabId = UUID()
        let sourcePaneId = UUIDv7.generate()
        let targetPaneId = UUIDv7.generate()
        let snapshot = ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: tabId,
                    visiblePaneIds: [sourcePaneId, targetPaneId],
                    ownedPaneIds: [sourcePaneId, targetPaneId],
                    activePaneId: sourcePaneId
                )
            ],
            activeTabId: tabId,
            isManagementLayerActive: false
        )

        let result = WorkspaceCommandValidator.validate(
            .insertPane(
                source: .existingPane(paneId: sourcePaneId, sourceTabId: tabId),
                targetTabId: tabId,
                targetPaneId: targetPaneId,
                direction: .right,
                sizingMode: .halveTarget
            ),
            state: snapshot
        )

        #expect((try? result.get()) != nil)
    }

    @Test("expand pane accepts a minimized pane in the active layout")
    func expandPaneAcceptsMinimizedLayoutPane() {
        let tabId = UUID()
        let visiblePaneId = UUIDv7.generate()
        let minimizedPaneId = UUIDv7.generate()
        let snapshot = ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: tabId,
                    visiblePaneIds: [visiblePaneId],
                    layoutPaneIds: [visiblePaneId, minimizedPaneId],
                    ownedPaneIds: [visiblePaneId, minimizedPaneId],
                    minimizedPaneIds: [minimizedPaneId],
                    activePaneId: visiblePaneId
                )
            ],
            activeTabId: tabId,
            isManagementLayerActive: false
        )

        let result = WorkspaceCommandValidator.validate(
            .expandPane(tabId: tabId, paneId: minimizedPaneId),
            state: snapshot
        )

        #expect((try? result.get()) != nil)
    }

    @Test("Zoom-active tabs reject terminal main-pane creation")
    func zoomActiveTabsRejectMainPaneCreation() {
        let tabId = UUID()
        let sourcePaneId = UUIDv7.generate()
        let snapshot = ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: tabId,
                    visiblePaneIds: [sourcePaneId],
                    ownedPaneIds: [sourcePaneId],
                    activePaneId: sourcePaneId
                )
            ],
            activeTabId: tabId,
            isManagementLayerActive: false,
            zoomSourcePaneIdByTabId: [tabId: sourcePaneId]
        )
        let actions: [WorkspaceActionCommand] = [
            .insertPane(
                source: .newTerminal,
                targetTabId: tabId,
                targetPaneId: sourcePaneId,
                direction: .right,
                sizingMode: .halveTarget
            )
        ]

        for action in actions {
            let result = WorkspaceCommandValidator.validate(action, state: snapshot)

            #expect(result == .failure(.zoomActive(tabId: tabId)))
        }
    }

    @Test("Zoom-active tabs preserve source Drawer creation")
    func zoomActiveTabsAllowSourceDrawerCreation() {
        let tabId = UUID()
        let sourcePaneId = UUIDv7.generate()
        let webviewState = WebviewState(url: URL(string: "https://example.com/zoom-drawer")!)
        let snapshot = ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: tabId,
                    visiblePaneIds: [sourcePaneId],
                    ownedPaneIds: [sourcePaneId],
                    activePaneId: sourcePaneId
                )
            ],
            activeTabId: tabId,
            isManagementLayerActive: false,
            zoomSourcePaneIdByTabId: [tabId: sourcePaneId]
        )
        let actions: [WorkspaceActionCommand] = [
            .addDrawerPane(parentPaneId: sourcePaneId),
            .addWebviewDrawerPane(parentPaneId: sourcePaneId, state: webviewState),
        ]

        for action in actions {
            let result = WorkspaceCommandValidator.validate(action, state: snapshot)

            #expect((try? result.get())?.action == action)
        }
    }

    @Test("Zoom-active tabs allow arrangement creation but reject pane visibility mutation")
    func zoomActiveTabsAllowArrangementCreationButRejectPaneVisibilityMutation() throws {
        let tabId = UUID()
        let sourcePaneId = UUIDv7.generate()
        let minimizedPaneId = UUIDv7.generate()
        let snapshot = ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: tabId,
                    visiblePaneIds: [sourcePaneId],
                    layoutPaneIds: [sourcePaneId, minimizedPaneId],
                    ownedPaneIds: [sourcePaneId, minimizedPaneId],
                    minimizedPaneIds: [minimizedPaneId],
                    activePaneId: sourcePaneId
                )
            ],
            activeTabId: tabId,
            isManagementLayerActive: false,
            zoomSourcePaneIdByTabId: [tabId: sourcePaneId]
        )
        let createArrangement = WorkspaceActionCommand.createArrangement(
            tabId: tabId,
            name: "Layout 2"
        )
        #expect(
            try WorkspaceCommandValidator.validate(
                createArrangement,
                state: snapshot
            ).get().action == createArrangement
        )

        let actions: [WorkspaceActionCommand] = [
            .minimizePane(tabId: tabId, paneId: sourcePaneId),
            .expandPane(tabId: tabId, paneId: minimizedPaneId),
        ]

        for action in actions {
            let result = WorkspaceCommandValidator.validate(action, state: snapshot)

            #expect(result == .failure(.zoomActive(tabId: tabId)))
        }
    }

    @Test("Zoom-active tabs still allow tab selection, tab closure, and durable arrangement switching")
    func zoomActiveTabsAllowExplicitExitPaths() {
        let zoomTabId = UUID()
        let otherTabId = UUID()
        let zoomSourcePaneId = UUIDv7.generate()
        let otherPaneId = UUIDv7.generate()
        let defaultArrangementId = UUID()
        let userArrangementId = UUID()
        let snapshot = ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: zoomTabId,
                    visiblePaneIds: [zoomSourcePaneId],
                    ownedPaneIds: [zoomSourcePaneId],
                    activePaneId: zoomSourcePaneId,
                    activeArrangementId: defaultArrangementId,
                    arrangements: [
                        ArrangementSnapshot(id: defaultArrangementId, isDefault: true),
                        ArrangementSnapshot(id: userArrangementId, isDefault: false),
                    ]
                ),
                TabSnapshot(
                    id: otherTabId,
                    visiblePaneIds: [otherPaneId],
                    ownedPaneIds: [otherPaneId],
                    activePaneId: otherPaneId
                ),
            ],
            activeTabId: zoomTabId,
            isManagementLayerActive: false,
            zoomSourcePaneIdByTabId: [zoomTabId: zoomSourcePaneId]
        )
        let actions: [WorkspaceActionCommand] = [
            .selectTab(tabId: otherTabId),
            .closeTab(tabId: zoomTabId),
            .switchArrangement(tabId: zoomTabId, arrangementId: userArrangementId),
        ]

        for action in actions {
            let result = WorkspaceCommandValidator.validate(action, state: snapshot)

            #expect((try? result.get())?.action == action)
        }
    }

    private func makeSplitTabWithHiddenPane(
        tabId: UUID,
        primaryPaneId: UUID,
        hiddenPaneId: UUID
    ) -> Tab {
        let layout = Layout.autoTiled([primaryPaneId, hiddenPaneId])
        let arrangement = PaneArrangement(
            layout: layout,
            minimizedPaneIds: [hiddenPaneId],
            activePaneId: primaryPaneId
        )
        return Tab(
            id: tabId,
            allPaneIds: [primaryPaneId, hiddenPaneId],
            arrangements: [arrangement],
            activeArrangementId: arrangement.id
        )
    }
}
