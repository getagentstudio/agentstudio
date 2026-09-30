import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite(.serialized)
struct TabArrangementCursorPreservationTests {
    @Test("background creation keeps a live drawer selection the published capture doesn't know about")
    func backgroundInsertionPreservesLiveDrawerSelection() {
        let tabId = UUIDv7.generate()
        let arrangementId = UUIDv7.generate()
        let drawerId = UUIDv7.generate()
        let parentPaneId = UUIDv7.generate()
        let childA = UUIDv7.generate()
        let childB = UUIDv7.generate()

        let published = makeSingleArrangementState(
            tabId: tabId, arrangementId: arrangementId, parentPaneId: parentPaneId,
            drawerId: drawerId, drawerChildIds: [childA, childB], activeDrawerChildId: childA
        )
        let live = makeSingleArrangementState(
            tabId: tabId, arrangementId: arrangementId, parentPaneId: parentPaneId,
            drawerId: drawerId, drawerChildIds: [childA, childB], activeDrawerChildId: childB
        )

        let result = TabArrangementCursorPreservation.committedDrawerInsertionState(
            published: published, live: live, presentation: .background)

        #expect(result.arrangements.first?.drawerViews[drawerId]?.activeChildId == childB)
    }

    @Test("interactive creation always keeps the published capture, selecting the child it just inserted")
    func interactiveInsertionKeepsPublishedSelection() {
        let tabId = UUIDv7.generate()
        let arrangementId = UUIDv7.generate()
        let drawerId = UUIDv7.generate()
        let parentPaneId = UUIDv7.generate()
        let childA = UUIDv7.generate()
        let insertedChild = UUIDv7.generate()

        let published = makeSingleArrangementState(
            tabId: tabId, arrangementId: arrangementId, parentPaneId: parentPaneId,
            drawerId: drawerId, drawerChildIds: [childA, insertedChild], activeDrawerChildId: insertedChild
        )
        let live = makeSingleArrangementState(
            tabId: tabId, arrangementId: arrangementId, parentPaneId: parentPaneId,
            drawerId: drawerId, drawerChildIds: [childA], activeDrawerChildId: childA
        )

        let result = TabArrangementCursorPreservation.committedDrawerInsertionState(
            published: published, live: live, presentation: .interactive)

        #expect(result == published)
        #expect(result.arrangements.first?.drawerViews[drawerId]?.activeChildId == insertedChild)
    }

    @Test("background creation keeps the published selection when the live child isn't in the published drawer")
    func backgroundInsertionIgnoresLiveSelectionMissingFromPublished() {
        let tabId = UUIDv7.generate()
        let arrangementId = UUIDv7.generate()
        let drawerId = UUIDv7.generate()
        let parentPaneId = UUIDv7.generate()
        let childA = UUIDv7.generate()
        let insertedChild = UUIDv7.generate()
        let liveOnlyChild = UUIDv7.generate()

        let published = makeSingleArrangementState(
            tabId: tabId, arrangementId: arrangementId, parentPaneId: parentPaneId,
            drawerId: drawerId, drawerChildIds: [childA, insertedChild], activeDrawerChildId: childA
        )
        let live = makeSingleArrangementState(
            tabId: tabId, arrangementId: arrangementId, parentPaneId: parentPaneId,
            drawerId: drawerId, drawerChildIds: [liveOnlyChild], activeDrawerChildId: liveOnlyChild
        )

        let result = TabArrangementCursorPreservation.committedDrawerInsertionState(
            published: published, live: live, presentation: .background)

        #expect(result.arrangements.first?.drawerViews[drawerId]?.activeChildId == childA)
    }

    @Test("background creation with no live state returns the published capture unchanged")
    func backgroundInsertionWithoutLiveStateKeepsPublished() {
        let tabId = UUIDv7.generate()
        let arrangementId = UUIDv7.generate()
        let drawerId = UUIDv7.generate()
        let parentPaneId = UUIDv7.generate()
        let childA = UUIDv7.generate()

        let published = makeSingleArrangementState(
            tabId: tabId, arrangementId: arrangementId, parentPaneId: parentPaneId,
            drawerId: drawerId, drawerChildIds: [childA], activeDrawerChildId: childA
        )

        let result = TabArrangementCursorPreservation.committedDrawerInsertionState(
            published: published, live: nil, presentation: .background)

        #expect(result == published)
    }

    @Test("background creation keeps a live active arrangement and main pane selection when still valid")
    func backgroundInsertionPreservesLiveArrangementAndMainPaneSelection() throws {
        let tabId = UUIDv7.generate()
        let mainPaneA = UUIDv7.generate()
        let mainPaneB = UUIDv7.generate()

        let defaultLayout = Layout.autoTiled([mainPaneA, mainPaneB])
        let defaultArrangement = PaneArrangement(
            id: UUIDv7.generate(), name: "Default", isDefault: true,
            layout: defaultLayout, activePaneId: mainPaneA
        )
        let customArrangement = PaneArrangement(
            id: UUIDv7.generate(), name: "Custom", isDefault: false,
            layout: Layout(paneId: mainPaneA), activePaneId: mainPaneA
        )
        let published = TabArrangementState(
            tabId: tabId, allPaneIds: [mainPaneA, mainPaneB],
            arrangements: [defaultArrangement, customArrangement],
            activeArrangementId: defaultArrangement.id
        )

        var liveDefaultArrangement = defaultArrangement
        liveDefaultArrangement.activePaneId = mainPaneB
        let live = TabArrangementState(
            tabId: tabId, allPaneIds: [mainPaneA, mainPaneB],
            arrangements: [liveDefaultArrangement, customArrangement],
            activeArrangementId: customArrangement.id
        )

        let result = TabArrangementCursorPreservation.committedDrawerInsertionState(
            published: published, live: live, presentation: .background)

        #expect(result.activeArrangementId == customArrangement.id)
        let resultDefault = try #require(result.arrangements.first { $0.id == defaultArrangement.id })
        #expect(resultDefault.activePaneId == mainPaneB)
    }

    /// Builds a single-arrangement tab: a main pane hosting a drawer with the
    /// given children, mirroring the shape `WorkspaceMutationCoordinator`
    /// publishes for a drawer terminal creation.
    private func makeSingleArrangementState(
        tabId: UUID, arrangementId: UUID, parentPaneId: UUID,
        drawerId: UUID, drawerChildIds: [UUID], activeDrawerChildId: UUID
    ) -> TabArrangementState {
        let drawerView = DrawerView(
            layout: DrawerGridLayout(topRow: Layout.autoTiled(drawerChildIds)),
            activeChildId: activeDrawerChildId
        )
        let arrangement = PaneArrangement(
            id: arrangementId, name: "Default", isDefault: true,
            layout: Layout(paneId: parentPaneId), activePaneId: parentPaneId,
            drawerViews: [drawerId: drawerView]
        )
        return TabArrangementState(
            tabId: tabId, allPaneIds: [parentPaneId] + drawerChildIds,
            arrangements: [arrangement], activeArrangementId: arrangementId
        )
    }
}
