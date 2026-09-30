import Foundation
import Observation
import os.log

private let workspaceTabArrangementLogger = Logger(
    subsystem: "com.agentstudio", category: "WorkspaceTabArrangementAtom")

package struct CrossTabPaneMoveResult: Equatable {
    package let sourceTabClosed: Bool
}

package struct CrossTabPaneMoveMutation: Equatable {
    package let request: CrossTabPaneMoveRequest
    package let drawerId: UUID?
    package let drawerPaneIds: [UUID]

    package init(
        request: CrossTabPaneMoveRequest,
        drawerId: UUID?,
        drawerPaneIds: [UUID]
    ) {
        self.request = request
        self.drawerId = drawerId
        self.drawerPaneIds = drawerPaneIds
    }
}

package struct PaneDrawerMovePayload: Equatable {
    package let drawerId: UUID
    package let drawerPaneIds: [UUID]
    package let drawerView: DrawerView?

    package init(drawerId: UUID, drawerPaneIds: [UUID], drawerView: DrawerView? = nil) {
        self.drawerId = drawerId
        self.drawerPaneIds = drawerPaneIds
        self.drawerView = drawerView
    }
}

extension WorkspaceTabArrangementAtom {
    func resizeVisiblePanePair(
        tabId: UUID,
        leftPaneId: UUID,
        rightPaneId: UUID,
        ratio: Double,
        residencyExcludedPaneIds: Set<UUID> = []
    ) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("resizeVisiblePanePair: tab \(tabId) not found")
            return
        }
        let arrIndex = activeArrangementIndex(for: tabIndex)
        let arrangement = arrangementStates[tabIndex].arrangements[arrIndex]
        guard
            PaneResizeVisibilityResolver.validatesRenderedPanePair(
                layoutPaneIds: arrangement.layout.paneIds,
                resizeExcludedPaneIds: arrangement.minimizedPaneIds.union(residencyExcludedPaneIds),
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId
            )
        else { return }

        arrangementStates[tabIndex].arrangements[arrIndex].layout = arrangement.layout.resizingPanePair(
            leftPaneId: leftPaneId,
            rightPaneId: rightPaneId,
            ratio: ratio
        )
    }

    func resizePaneByDelta(tabId: UUID, paneId: UUID, direction: SplitResizeDirection, amount: UInt16) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("resizePaneByDelta: tab \(tabId) not found")
            return
        }
        let arrangement = activeArrangement(for: tabIndex)
        guard
            let target = PaneResizeVisibilityResolver.keyboardPair(
                layout: arrangement.layout,
                minimizedPaneIds: arrangement.minimizedPaneIds,
                paneId: paneId,
                direction: direction
            )
        else { return }
        guard
            let currentRatio = arrangement.layout.ratioForPanePair(
                leftPaneId: target.pair.leftPaneId,
                rightPaneId: target.pair.rightPaneId
            )
        else {
            workspaceTabArrangementLogger.warning("resizePaneByDelta: ratioForPanePair returned nil for pane \(paneId)")
            return
        }

        let delta = Self.resizeRatioStep * (Double(amount) / Self.resizeBaseAmount)
        let newRatio = min(0.9, max(0.1, target.increase ? currentRatio + delta : currentRatio - delta))
        let arrIndex = activeArrangementIndex(for: tabIndex)
        arrangementStates[tabIndex].arrangements[arrIndex].layout = arrangementStates[tabIndex].arrangements[arrIndex]
            .layout
            .resizingPanePair(
                leftPaneId: target.pair.leftPaneId,
                rightPaneId: target.pair.rightPaneId,
                ratio: newRatio
            )
    }

    package func resizeDrawerVisiblePanePair(
        drawerId: UUID,
        tabId: UUID,
        leftPaneId: UUID,
        rightPaneId: UUID,
        ratio: Double
    ) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("resizeDrawerVisiblePanePair: tab \(tabId) not found")
            return
        }
        let arrangementIndex = activeArrangementIndex(for: tabIndex)
        guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId]
        else { return }
        if PaneResizeVisibilityResolver.validatesRenderedPanePair(
            layoutPaneIds: drawerView.layout.topRow.paneIds,
            resizeExcludedPaneIds: drawerView.minimizedPaneIds,
            leftPaneId: leftPaneId,
            rightPaneId: rightPaneId
        ) {
            drawerView.layout.topRow = drawerView.layout.topRow.resizingPanePair(
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId,
                ratio: ratio
            )
        } else if let bottomRow = drawerView.layout.bottomRow,
            PaneResizeVisibilityResolver.validatesRenderedPanePair(
                layoutPaneIds: bottomRow.paneIds,
                resizeExcludedPaneIds: drawerView.minimizedPaneIds,
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId
            )
        {
            drawerView.layout.bottomRow = bottomRow.resizingPanePair(
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId,
                ratio: ratio
            )
        } else {
            return
        }
        arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
    }
}

@MainActor
@Observable
package final class WorkspaceTabArrangementAtom {
    package let graphAtom: WorkspaceTabGraphAtom
    package let cursorAtom: WorkspaceArrangementCursorAtom
    package let presentationAtom: WorkspacePanePresentationAtom

    package init(
        graphAtom: WorkspaceTabGraphAtom = WorkspaceTabGraphAtom(),
        cursorAtom: WorkspaceArrangementCursorAtom = WorkspaceArrangementCursorAtom(),
        presentationAtom: WorkspacePanePresentationAtom = WorkspacePanePresentationAtom()
    ) {
        self.graphAtom = graphAtom
        self.cursorAtom = cursorAtom
        self.presentationAtom = presentationAtom
    }

    private(set) var arrangementStates: [TabArrangementState] {
        get { composedArrangementStates() }
        _modify {
            var states = composedArrangementStates()
            defer { replaceArrangementStates(states) }
            yield &states
        }
    }

    func replaceTabs(
        _ tabs: [Tab],
        validPaneIds: Set<UUID>,
        drawerParentPaneIdByDrawerId: [UUID: UUID]? = nil
    ) {
        let replacementStates = tabs.map { tab in
            TabArrangementState(
                tabId: tab.id,
                allPaneIds: tab.allPaneIds,
                arrangements: tab.arrangements,
                activeArrangementId: tab.activeArrangementId
            )
        }
        replaceArrangementStates(
            TabArrangementValidation.validating(
                TabArrangementValidation.pruningInvalidPaneIds(
                    validPaneIds: validPaneIds,
                    from: replacementStates,
                    drawerParentPaneIdByDrawerId: drawerParentPaneIdByDrawerId
                ),
                drawerParentPaneIdByDrawerId: drawerParentPaneIdByDrawerId
            ))
    }

    var allPaneIds: Set<UUID> {
        Set(arrangementStates.flatMap(\.allPaneIds))
    }

    package func arrangementState(_ tabId: UUID) -> TabArrangementState? {
        composedArrangementState(tabId: tabId)
    }

    func tabContaining(paneId: UUID) -> TabArrangementState? {
        guard let tabId = graphAtom.tabID(containingPane: paneId) else { return nil }
        return composedArrangementState(tabId: tabId)
    }

    func appendState(_ state: TabArrangementState) {
        arrangementStates.append(state)
    }

    func removeState(_ tabId: UUID) {
        arrangementStates.removeAll { $0.tabId == tabId }
        presentationAtom.removeZoomTab(tabId)
    }

    func insertState(_ state: TabArrangementState, at index: Int) {
        let clampedIndex = min(index, arrangementStates.count)
        arrangementStates.insert(state, at: clampedIndex)
    }

    @discardableResult
    func insertPane(
        _ paneId: UUID,
        inTab tabId: UUID,
        at targetPaneId: UUID,
        direction: Layout.SplitDirection,
        position: Layout.Position,
        sizingMode: DropSizingMode
    ) -> Bool {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("insertPane: tab \(tabId) not found")
            return false
        }
        guard
            let updatedState = TabArrangementMutationRules.insertingPane(
                paneId, in: arrangementStates[tabIndex], at: targetPaneId,
                direction: direction, position: position, sizingMode: sizingMode
            )
        else {
            workspaceTabArrangementLogger.warning("insertPane: rejected layout insertion")
            return false
        }
        arrangementStates[tabIndex] = updatedState
        return true
    }

    @discardableResult
    package func insertNewPane(
        _ paneId: UUID,
        inTab tabId: UUID,
        at targetPaneId: UUID,
        direction: Layout.SplitDirection,
        position: Layout.Position,
        sizingMode: DropSizingMode
    ) -> Bool {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("insertNewPane: tab \(tabId) not found")
            return false
        }
        guard
            let updatedState = TabArrangementMutationRules.insertingNewPane(
                paneId,
                in: arrangementStates[tabIndex],
                at: targetPaneId,
                direction: direction,
                position: position,
                sizingMode: sizingMode
            )
        else {
            workspaceTabArrangementLogger.warning("insertNewPane: rejected layout insertion")
            return false
        }
        arrangementStates[tabIndex] = updatedState
        return true
    }

    func removePaneFromLayout(_ paneId: UUID, inTab tabId: UUID, removingDrawerId drawerId: UUID? = nil) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("removePaneFromLayout: tab \(tabId) not found")
            return
        }

        arrangementStates[tabIndex].arrangements = TabArrangementMutationRules.removingUserPane(
            paneId,
            removingDrawerId: drawerId,
            from: arrangementStates[tabIndex].arrangements
        )

        if activeArrangement(for: tabIndex).layout.isEmpty && !defaultArrangement(for: tabIndex).layout.isEmpty {
            arrangementStates[tabIndex].activeArrangementId = defaultArrangement(for: tabIndex).id
        }

        arrangementStates[tabIndex].allPaneIds.removeAll { $0 == paneId }
    }

    func removePaneReferences(_ paneIds: Set<UUID>, removingDrawerIds drawerIds: Set<UUID> = []) {
        for tabIndex in arrangementStates.indices {
            arrangementStates[tabIndex].allPaneIds.removeAll { paneIds.contains($0) }
            arrangementStates[tabIndex].arrangements = TabArrangementRepairRules.removingPanes(
                paneIds,
                removingDrawerIds: drawerIds,
                from: arrangementStates[tabIndex].arrangements
            )
        }
    }

    func resizePane(tabId: UUID, splitId: UUID, ratio: Double) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("resizePane: tab \(tabId) not found")
            return
        }
        let arrIndex = activeArrangementIndex(for: tabIndex)
        arrangementStates[tabIndex].arrangements[arrIndex].layout = arrangementStates[tabIndex].arrangements[arrIndex]
            .layout
            .resizing(splitId: splitId, ratio: ratio)
    }

    func equalizePanes(tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("equalizePanes: tab \(tabId) not found")
            return
        }
        let arrIndex = activeArrangementIndex(for: tabIndex)
        arrangementStates[tabIndex].arrangements[arrIndex].layout = arrangementStates[tabIndex].arrangements[arrIndex]
            .layout.equalized()
    }

    func setActivePane(_ paneId: UUID?, inTab tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("setActivePane: tab \(tabId) not found")
            return
        }
        if let paneId {
            guard arrangementStates[tabIndex].allPaneIds.contains(paneId) else {
                workspaceTabArrangementLogger.warning("setActivePane: paneId \(paneId) not found in tab \(tabId)")
                return
            }
        }
        let arrIndex = activeArrangementIndex(for: tabIndex)
        arrangementStates[tabIndex].arrangements[arrIndex].activePaneId = paneId
    }

    @discardableResult
    func createArrangement(name: String, inTab tabId: UUID) -> UUID? {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("createArrangement: tab \(tabId) not found")
            return nil
        }

        guard
            let arrangement = TabArrangementMutationRules.createArrangement(
                name: name,
                from: arrangementStates[tabIndex]
            )
        else {
            workspaceTabArrangementLogger.warning("createArrangement: failed to build arrangement for tab \(tabId)")
            return nil
        }
        arrangementStates[tabIndex].arrangements.append(arrangement)
        arrangementStates[tabIndex].activeArrangementId = arrangement.id
        return arrangement.id
    }

    func removeArrangement(_ arrangementId: UUID, inTab tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("removeArrangement: tab \(tabId) not found")
            return
        }
        guard let arrIndex = arrangementStates[tabIndex].arrangements.firstIndex(where: { $0.id == arrangementId })
        else {
            workspaceTabArrangementLogger.warning(
                "removeArrangement: arrangement \(arrangementId) not found in tab \(tabId)"
            )
            return
        }
        guard !arrangementStates[tabIndex].arrangements[arrIndex].isDefault else {
            workspaceTabArrangementLogger.warning("removeArrangement: cannot remove default arrangement")
            return
        }

        arrangementStates[tabIndex] = TabArrangementMutationRules.removingArrangement(
            arrangementId,
            from: arrangementStates[tabIndex]
        )
    }

    func switchArrangement(to arrangementId: UUID, inTab tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("switchArrangement: tab \(tabId) not found")
            return
        }
        guard arrangementStates[tabIndex].arrangements.contains(where: { $0.id == arrangementId }) else {
            workspaceTabArrangementLogger.warning(
                "switchArrangement: arrangement \(arrangementId) not found in tab \(tabId)"
            )
            return
        }
        guard arrangementStates[tabIndex].activeArrangementId != arrangementId else { return }
        arrangementStates[tabIndex] = TabArrangementMutationRules.switchingArrangement(
            to: arrangementId,
            in: arrangementStates[tabIndex]
        )
    }

    func renameArrangement(_ arrangementId: UUID, name: String, inTab tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("renameArrangement: tab \(tabId) not found")
            return
        }
        guard let arrIndex = arrangementStates[tabIndex].arrangements.firstIndex(where: { $0.id == arrangementId })
        else {
            workspaceTabArrangementLogger.warning(
                "renameArrangement: arrangement \(arrangementId) not found in tab \(tabId)"
            )
            return
        }
        arrangementStates[tabIndex].arrangements[arrIndex].name = name
    }

    @discardableResult
    func minimizePane(_ paneId: UUID, inTab tabId: UUID) -> Bool {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("minimizePane: tab \(tabId) not found")
            return false
        }
        let visiblePaneIds = activeArrangement(for: tabIndex).layout.paneIds
        guard visiblePaneIds.contains(paneId) else {
            workspaceTabArrangementLogger.warning("minimizePane: pane \(paneId) not in active arrangement")
            return false
        }

        guard let updated = TabArrangementMutationRules.minimizingPane(paneId, in: arrangementStates[tabIndex]) else {
            workspaceTabArrangementLogger.warning("minimizePane: pane \(paneId) not in active arrangement")
            return false
        }
        arrangementStates[tabIndex] = updated
        return true
    }

    func expandPane(_ paneId: UUID, inTab tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("expandPane: tab \(tabId) not found")
            return
        }
        arrangementStates[tabIndex] = TabArrangementMutationRules.expandingPane(paneId, in: arrangementStates[tabIndex])
    }

    package func addDrawerPaneView(
        drawerId: UUID,
        parentPaneId: UUID,
        drawerPaneId: UUID,
        inTab tabId: UUID,
        targetDrawerPaneId: UUID? = nil,
        direction: SplitNewDirection = .right,
        sizingMode: DropSizingMode = .halveTarget
    ) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("addDrawerPaneView: tab \(tabId) not found")
            return
        }

        guard
            let updated = TabArrangementMutationRules.insertingDrawerPane(
                drawerPaneId, in: arrangementStates[tabIndex],
                insertion: .init(
                    parentPaneId: parentPaneId,
                    drawerId: drawerId, targetDrawerPaneId: targetDrawerPaneId,
                    direction: direction, sizingMode: sizingMode))
        else { return }
        arrangementStates[tabIndex] = updated
    }

    package func addNewDrawerPaneView(
        drawerId: UUID,
        parentPaneId: UUID,
        drawerPaneId: UUID,
        inTab tabId: UUID,
        targetDrawerPaneId: UUID? = nil,
        direction: SplitNewDirection = .right,
        sizingMode: DropSizingMode = .halveTarget,
        selectsInsertedChild: Bool = true
    ) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("addNewDrawerPaneView: tab \(tabId) not found")
            return
        }

        guard
            let updated = TabArrangementMutationRules.insertingNewDrawerPane(
                drawerPaneId,
                in: arrangementStates[tabIndex],
                insertion: .init(
                    parentPaneId: parentPaneId,
                    drawerId: drawerId,
                    targetDrawerPaneId: targetDrawerPaneId,
                    direction: direction,
                    sizingMode: sizingMode,
                    selectsInsertedChild: selectsInsertedChild
                )
            )
        else { return }
        arrangementStates[tabIndex] = updated
    }

    func restoreDrawerPaneViews(
        drawerId: UUID,
        parentPaneId: UUID,
        drawerPaneIds: [UUID],
        drawerViewsByArrangementId: [UUID: DrawerView],
        inTab tabId: UUID
    ) {
        guard !drawerPaneIds.isEmpty, let tabIndex = findTabIndex(tabId) else { return }
        let fallbackDrawerView = Self.drawerViewSeed(drawerId: drawerId, drawerPaneIds: drawerPaneIds)
        let validDrawerPaneIds = Set(drawerPaneIds)
        var didRestoreDrawerView = false
        var updatedState = arrangementStates[tabIndex]
        for arrangementIndex in updatedState.arrangements.indices {
            guard updatedState.arrangements[arrangementIndex].layout.contains(parentPaneId) else { continue }
            let arrangementId = updatedState.arrangements[arrangementIndex].id
            guard let sourceDrawerView = drawerViewsByArrangementId[arrangementId] ?? fallbackDrawerView else {
                continue
            }
            let repairedDrawerViews = TabArrangementRepairRules.pruningInvalidDrawerViewPaneIds(
                validPaneIds: validDrawerPaneIds,
                from: [drawerId: sourceDrawerView]
            )
            guard
                let drawerView = repairedDrawerViews[drawerId]
            else { continue }

            updatedState.arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
            didRestoreDrawerView = true
        }

        if didRestoreDrawerView {
            for drawerPaneId in drawerPaneIds where !updatedState.allPaneIds.contains(drawerPaneId) {
                updatedState.allPaneIds.append(drawerPaneId)
            }
            arrangementStates[tabIndex] = updatedState
        }
    }

    package func removeDrawerPaneView(drawerId: UUID, drawerPaneId: UUID, inTab tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("removeDrawerPaneView: tab \(tabId) not found")
            return
        }

        for arrangementIndex in arrangementStates[tabIndex].arrangements.indices {
            guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId]
            else { continue }
            drawerView.minimizedPaneIds.remove(drawerPaneId)
            if drawerView.layout.contains(drawerPaneId) {
                drawerView.layout =
                    drawerView.layout.removing(paneId: drawerPaneId, sizingMode: .proportional)
                    ?? DrawerGridLayout()
            }
            if drawerView.layout.isEmpty {
                arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews.removeValue(forKey: drawerId)
                continue
            }
            if drawerView.activeChildId == drawerPaneId {
                drawerView.activeChildId = drawerView.layout.paneIds.first
            }
            arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
        }
        arrangementStates[tabIndex].allPaneIds.removeAll { $0 == drawerPaneId }
    }

    package func setActiveDrawerPane(_ drawerPaneId: UUID, drawerId: UUID, inTab tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("setActiveDrawerPane: tab \(tabId) not found")
            return
        }
        let arrangementIndex = activeArrangementIndex(for: tabIndex)
        guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId],
            drawerView.layout.contains(drawerPaneId)
        else {
            workspaceTabArrangementLogger.warning("setActiveDrawerPane: drawer pane \(drawerPaneId) not found")
            return
        }
        drawerView.activeChildId = drawerPaneId
        arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
    }

    package func resizeDrawerPane(drawerId: UUID, tabId: UUID, splitId: UUID, ratio: Double) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("resizeDrawerPane: tab \(tabId) not found")
            return
        }
        let arrangementIndex = activeArrangementIndex(for: tabIndex)
        guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId]
        else { return }
        drawerView.layout = drawerView.layout.resizing(splitId: splitId, ratio: ratio)
        arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
    }

    package func equalizeDrawerPanes(drawerId: UUID, tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("equalizeDrawerPanes: tab \(tabId) not found")
            return
        }
        let arrangementIndex = activeArrangementIndex(for: tabIndex)
        guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId]
        else { return }
        drawerView.layout = drawerView.layout.equalized()
        arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
    }

    @discardableResult
    package func minimizeDrawerPane(_ drawerPaneId: UUID, drawerId: UUID, tabId: UUID) -> Bool {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("minimizeDrawerPane: tab \(tabId) not found")
            return false
        }
        var arrangementIndex = activeArrangementIndex(for: tabIndex)
        guard let activeDrawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId],
            activeDrawerView.layout.contains(drawerPaneId)
        else { return false }

        if arrangementStates[tabIndex].arrangements[arrangementIndex].isDefault {
            let name = ArrangementDerived.nextCustomArrangementName(
                existing: arrangementStates[tabIndex].arrangements
            )
            guard
                let userArrangement = TabArrangementMutationRules.createArrangement(
                    name: name,
                    from: arrangementStates[tabIndex]
                )
            else { return false }
            arrangementStates[tabIndex].arrangements.append(userArrangement)
            arrangementStates[tabIndex].activeArrangementId = userArrangement.id
            arrangementIndex = arrangementStates[tabIndex].arrangements.index(
                before: arrangementStates[tabIndex].arrangements.endIndex
            )
        }

        guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId]
        else { return false }
        drawerView.minimizedPaneIds.insert(drawerPaneId)
        if drawerView.activeChildId == drawerPaneId {
            drawerView.activeChildId = drawerView.layout.paneIds.first { !drawerView.minimizedPaneIds.contains($0) }
        }
        arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
        return true
    }

    package func expandDrawerPane(_ drawerPaneId: UUID, drawerId: UUID, tabId: UUID) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("expandDrawerPane: tab \(tabId) not found")
            return
        }
        let arrangementIndex = activeArrangementIndex(for: tabIndex)
        guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId]
        else { return }
        drawerView.minimizedPaneIds.remove(drawerPaneId)
        drawerView.activeChildId = drawerPaneId
        arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
    }

    package func moveDrawerPane(
        _ drawerPaneId: UUID,
        drawerId: UUID,
        tabId: UUID,
        target: DrawerRearrangeTarget,
        sizingMode: DropSizingMode
    ) {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("moveDrawerPane: tab \(tabId) not found")
            return
        }
        let arrangementIndex = activeArrangementIndex(for: tabIndex)
        guard var drawerView = arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId]
        else { return }

        switch drawerView.layout.projectedMove(paneId: drawerPaneId, target: target, sizingMode: sizingMode) {
        case .success(let movedLayout):
            drawerView.layout = movedLayout
            drawerView.activeChildId = drawerPaneId
            arrangementStates[tabIndex].arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
        case .failure(let failure):
            workspaceTabArrangementLogger.warning(
                "moveDrawerPane: rejected moving pane \(drawerPaneId): \(failure.description)"
            )
        }
    }

    func breakUpTab(
        _ tabId: UUID,
        drawerPayloadsByParentPaneId: [UUID: PaneDrawerMovePayload] = [:]
    ) -> [TabArrangementState] {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("breakUpTab: tab \(tabId) not found")
            return []
        }
        let state = arrangementStates[tabIndex]
        let newStates = TabArrangementMutationRules.breakingUpTab(
            state,
            drawerPayloadsByParentPaneId: drawerPayloadsByParentPaneId
        )
        guard !newStates.isEmpty else {
            workspaceTabArrangementLogger.warning(
                "breakUpTab: tab \(tabId) has fewer than two panes in the active arrangement")
            return []
        }

        arrangementStates.remove(at: tabIndex)
        let insertIndex = min(tabIndex, arrangementStates.count)
        arrangementStates.insert(contentsOf: newStates, at: insertIndex)
        return newStates
    }

    func extractPane(
        _ paneId: UUID,
        fromTab tabId: UUID,
        drawerPayload: PaneDrawerMovePayload? = nil
    ) -> TabArrangementState? {
        guard let tabIndex = findTabIndex(tabId) else {
            workspaceTabArrangementLogger.warning("extractPane: tab \(tabId) not found")
            return nil
        }
        guard arrangementStates[tabIndex].allPaneIds.contains(paneId) else {
            workspaceTabArrangementLogger.warning("extractPane: paneId \(paneId) not in tab \(tabId)")
            return nil
        }
        guard
            let result = TabArrangementMutationRules.extractingPane(
                paneId,
                from: arrangementStates[tabIndex],
                drawerPayload: drawerPayload
            )
        else {
            workspaceTabArrangementLogger.warning(
                "extractPane: pane \(paneId) cannot be extracted because the active arrangement has fewer than two panes"
            )
            return nil
        }
        arrangementStates[tabIndex] = result.updatedState
        let insertIndex = tabIndex + 1
        arrangementStates.insert(result.extractedState, at: min(insertIndex, arrangementStates.count))
        return result.extractedState
    }

    @discardableResult
    package func movePaneAcrossTabs(_ mutation: CrossTabPaneMoveMutation) -> CrossTabPaneMoveResult? {
        let request = mutation.request
        let paneId = request.paneId
        let sourceTabId = request.sourceTabId
        let destTabId = request.destTabId
        let targetPaneId = request.targetPaneId
        let direction = request.direction
        let position = request.position
        let drawerId = mutation.drawerId
        let drawerPaneIds = mutation.drawerPaneIds

        guard sourceTabId != destTabId else {
            workspaceTabArrangementLogger.warning("movePaneAcrossTabs: source and destination are both \(sourceTabId)")
            return nil
        }
        guard let sourceIndex = findTabIndex(sourceTabId), let destIndex = findTabIndex(destTabId) else {
            workspaceTabArrangementLogger.warning(
                "movePaneAcrossTabs: source \(sourceTabId) or destination \(destTabId) not found")
            return nil
        }

        var sourceState = arrangementStates[sourceIndex]
        var destState = arrangementStates[destIndex]
        let movedPaneIds = [paneId] + drawerPaneIds
        let movedPaneIdSet = Set(movedPaneIds)
        guard sourceState.allPaneIds.contains(paneId), destState.allPaneIds.contains(targetPaneId) else {
            workspaceTabArrangementLogger.warning(
                "movePaneAcrossTabs: pane \(paneId) or target \(targetPaneId) not owned by requested tabs")
            return nil
        }

        let activeDestIndex = Self.activeArrangementIndex(in: destState)
        guard destState.arrangements[activeDestIndex].layout.contains(targetPaneId) else {
            workspaceTabArrangementLogger.warning(
                "movePaneAcrossTabs: target pane \(targetPaneId) not in active destination arrangement")
            return nil
        }

        sourceState.arrangements = TabArrangementMutationRules.removingUserPane(
            paneId,
            from: sourceState.arrangements
        )
        if let drawerId {
            for arrangementIndex in sourceState.arrangements.indices {
                sourceState.arrangements[arrangementIndex].drawerViews.removeValue(forKey: drawerId)
            }
        }
        sourceState.allPaneIds.removeAll { movedPaneIdSet.contains($0) }
        if Self.activeArrangement(in: sourceState).layout.isEmpty
            && !Self.defaultArrangement(in: sourceState).layout.isEmpty
        {
            sourceState.activeArrangementId = Self.defaultArrangement(in: sourceState).id
        }

        for movedPaneId in movedPaneIds where !destState.allPaneIds.contains(movedPaneId) {
            destState.allPaneIds.append(movedPaneId)
        }
        let seededDrawerView = Self.drawerViewSeed(drawerId: drawerId, drawerPaneIds: drawerPaneIds)
        for arrangementIndex in destState.arrangements.indices {
            let updatedLayout: Layout?
            if arrangementIndex == activeDestIndex {
                updatedLayout = destState.arrangements[arrangementIndex].layout.inserting(
                    paneId: paneId,
                    at: targetPaneId,
                    direction: direction,
                    position: position,
                    sizingMode: .halveTarget
                )
                destState.arrangements[arrangementIndex].activePaneId = paneId
            } else {
                updatedLayout = Self.appendingPane(paneId, to: destState.arrangements[arrangementIndex].layout)
            }
            guard let updatedLayout else {
                workspaceTabArrangementLogger.warning(
                    "movePaneAcrossTabs: insertion of pane \(paneId) into destination \(destTabId) failed")
                return nil
            }
            destState.arrangements[arrangementIndex].layout = updatedLayout
            destState.arrangements[arrangementIndex].minimizedPaneIds.remove(paneId)
            if let seededDrawerView, let drawerId {
                destState.arrangements[arrangementIndex].drawerViews[drawerId] = seededDrawerView
            }
        }

        arrangementStates[sourceIndex] = sourceState
        arrangementStates[destIndex] = destState
        return CrossTabPaneMoveResult(sourceTabClosed: sourceState.allPaneIds.isEmpty)
    }

    func mergeTab(
        sourceId: UUID,
        intoTarget targetId: UUID,
        at targetPaneId: UUID,
        direction: Layout.SplitDirection,
        position: Layout.Position,
        drawerPayloadsByParentPaneId: [UUID: PaneDrawerMovePayload] = [:]
    ) {
        guard sourceId != targetId else {
            workspaceTabArrangementLogger.warning("mergeTab: sourceId and targetId are the same tab \(sourceId)")
            return
        }
        var replacementStates = arrangementStates
        guard let sourceTabIndex = replacementStates.firstIndex(where: { $0.tabId == sourceId }),
            let targetTabIndex = replacementStates.firstIndex(where: { $0.tabId == targetId })
        else {
            workspaceTabArrangementLogger.warning("mergeTab: source \(sourceId) or target \(targetId) tab not found")
            return
        }

        let targetArrIndex = activeArrangementIndex(for: targetTabIndex)
        guard replacementStates[targetTabIndex].arrangements[targetArrIndex].layout.contains(targetPaneId) else {
            workspaceTabArrangementLogger.warning("mergeTab: targetPaneId \(targetPaneId) not in target arrangement")
            return
        }

        guard
            let mergedState = TabArrangementMutationRules.merging(
                source: replacementStates[sourceTabIndex],
                into: replacementStates[targetTabIndex],
                at: targetPaneId,
                direction: direction,
                position: position,
                drawerPayloadsByParentPaneId: drawerPayloadsByParentPaneId
            )
        else {
            workspaceTabArrangementLogger.warning(
                "mergeTab: merge helper rejected source \(sourceId) into target \(targetId) at pane \(targetPaneId)"
            )
            return
        }
        replacementStates[targetTabIndex] = mergedState
        replacementStates.remove(at: sourceTabIndex)
        replaceArrangementStates(replacementStates)
    }

}
