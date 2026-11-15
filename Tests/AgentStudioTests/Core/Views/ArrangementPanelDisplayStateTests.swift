import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

struct ArrangementPanelDisplayStateTests {

    @Test
    func singleVisiblePane_stillShowsArrangementControls() {
        let state = ArrangementPanelDisplayState(
            visiblePanes: [
                PaneVisibilityInfo(id: UUID(), title: "Terminal", isMinimized: false)
            ],
            zoomMode: nil,
            arrangements: [
                ArrangementInfo(id: UUID(), name: "Default", role: .defaultArrangement, isActive: true)
            ]
        )

        #expect(state.showsSaveArrangementButton)
        #expect(state.showsPaneVisibilitySection)
    }

    @Test
    func noVisiblePanes_hidesPaneSpecificSections() {
        let state = ArrangementPanelDisplayState(
            visiblePanes: [],
            zoomMode: nil,
            arrangements: [
                ArrangementInfo(id: UUID(), name: "Default", role: .defaultArrangement, isActive: true)
            ]
        )

        #expect(!state.showsSaveArrangementButton)
        #expect(!state.showsPaneVisibilitySection)
    }

    @Test
    func inactiveZoom_hasNoModeRowAndKeepsUserLayoutNamedZoomDurable() {
        let defaultArrangement = ArrangementInfo(
            id: UUID(),
            name: "Default",
            role: .defaultArrangement,
            isActive: true
        )
        let userLayoutNamedZoom = ArrangementInfo(
            id: UUID(),
            name: "Zoom",
            role: .userLayout,
            isActive: false
        )
        let state = ArrangementPanelDisplayState(
            visiblePanes: [
                PaneVisibilityInfo(id: UUID(), title: "Terminal", isMinimized: false)
            ],
            zoomMode: nil,
            arrangements: [defaultArrangement, userLayoutNamedZoom]
        )

        #expect(state.zoomMode == nil)
        #expect(state.arrangements == [defaultArrangement, userLayoutNamedZoom])
        #expect(userLayoutNamedZoom.role.expectedDurableRoleForTesting == .userLayout)
        #expect(ArrangementChipAffordance.showsRenamePencil(role: userLayoutNamedZoom.role))
        #expect(state.allowsArrangementCreation)
    }

    @Test
    func activeZoom_isSeparateSelectedModeAndKeepsArrangementCreationAvailable() {
        let zoomMode = ArrangementPanelZoomMode(
            label: "Pane Zoom",
            sourcePaneId: UUID()
        )
        let userLayoutNamedZoom = ArrangementInfo(
            id: UUID(),
            name: "Zoom",
            role: .userLayout,
            isActive: false
        )
        let state = ArrangementPanelDisplayState(
            visiblePanes: [
                PaneVisibilityInfo(id: UUID(), title: "Terminal", isMinimized: false)
            ],
            zoomMode: zoomMode,
            arrangements: [
                ArrangementInfo(
                    id: UUID(),
                    name: "Default",
                    role: .defaultArrangement,
                    isActive: false
                ),
                userLayoutNamedZoom,
            ]
        )

        #expect(state.zoomMode == zoomMode)
        #expect(state.zoomMode?.label == "Pane Zoom")
        #expect(userLayoutNamedZoom.role.expectedDurableRoleForTesting == .userLayout)
        #expect(ArrangementChipAffordance.showsRenamePencil(role: userLayoutNamedZoom.role))
        #expect(state.allowsArrangementCreation)
        #expect(state.showsSaveArrangementButton)
        #expect(!state.showsPaneVisibilitySection)
    }

    @Test
    func arrangementTriggerLabel_usesZoomOnlyWhileZoomIsActive() {
        let selectedLayout = ArrangementInfo(
            id: UUID(),
            name: "Layout 2",
            role: .userLayout,
            isActive: true
        )
        let inactiveState = ArrangementPanelDisplayState(
            visiblePanes: [],
            zoomMode: nil,
            arrangements: [selectedLayout]
        )
        let activeState = ArrangementPanelDisplayState(
            visiblePanes: [],
            zoomMode: ArrangementPanelZoomMode(
                label: "Pane Zoom",
                sourcePaneId: UUID()
            ),
            arrangements: [selectedLayout]
        )

        #expect(inactiveState.arrangementTriggerLabel == "Layout 2")
        #expect(activeState.arrangementTriggerLabel == "Pane Zoom")
    }

    @Test
    func popoverAutoOpen_opensWhenRenameTargetsActiveTabArrangement() {
        let arrangementId = UUID()
        let arrangements = [
            ArrangementInfo(id: UUID(), name: "Default", role: .defaultArrangement, isActive: true),
            ArrangementInfo(id: arrangementId, name: "Layout 1", role: .userLayout, isActive: false),
        ]

        #expect(
            ArrangementPopoverAutoOpen.shouldOpen(
                editingArrangementId: arrangementId,
                activeTabArrangements: arrangements,
                isPresented: false
            )
        )
    }

    @Test
    func popoverAutoOpen_doesNotOpenWhenEditingIdIsNil() {
        let arrangements = [
            ArrangementInfo(id: UUID(), name: "Default", role: .defaultArrangement, isActive: true)
        ]

        #expect(
            !ArrangementPopoverAutoOpen.shouldOpen(
                editingArrangementId: nil,
                activeTabArrangements: arrangements,
                isPresented: false
            )
        )
    }

    @Test
    func popoverAutoOpen_doesNotOpenWhenActiveTabIsMissing() {
        #expect(
            !ArrangementPopoverAutoOpen.shouldOpen(
                editingArrangementId: UUID(),
                activeTabArrangements: nil,
                isPresented: false
            )
        )
    }

    @Test
    func popoverAutoOpen_doesNotOpenWhenArrangementBelongsToDifferentTab() {
        let arrangements = [
            ArrangementInfo(id: UUID(), name: "Default", role: .defaultArrangement, isActive: true),
            ArrangementInfo(id: UUID(), name: "Layout 1", role: .userLayout, isActive: false),
        ]

        #expect(
            !ArrangementPopoverAutoOpen.shouldOpen(
                editingArrangementId: UUID(),
                activeTabArrangements: arrangements,
                isPresented: false
            )
        )
    }

    @Test
    func popoverAutoOpen_doesNotReopenWhenAlreadyPresented() {
        let arrangementId = UUID()
        let arrangements = [
            ArrangementInfo(id: arrangementId, name: "Layout 1", role: .userLayout, isActive: false)
        ]

        #expect(
            !ArrangementPopoverAutoOpen.shouldOpen(
                editingArrangementId: arrangementId,
                activeTabArrangements: arrangements,
                isPresented: true
            )
        )
    }

    @Test
    func chipAffordance_hidesPencilForDefaultArrangement() {
        #expect(!ArrangementChipAffordance.showsRenamePencil(role: .defaultArrangement))
    }

    @Test
    func chipAffordance_showsPencilForCustomArrangement() {
        #expect(ArrangementChipAffordance.showsRenamePencil(role: .userLayout))
    }
}

private enum ExpectedDurableArrangementRole: Equatable {
    case defaultArrangement
    case userLayout
}

extension ArrangementPanelRole {
    fileprivate var expectedDurableRoleForTesting: ExpectedDurableArrangementRole {
        switch self {
        case .defaultArrangement:
            .defaultArrangement
        case .userLayout:
            .userLayout
        }
    }
}
