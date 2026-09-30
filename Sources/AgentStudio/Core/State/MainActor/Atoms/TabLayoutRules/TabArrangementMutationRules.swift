import Foundation

enum TabArrangementMutationRules {
    private struct PaneInsertion {
        let paneID: UUID
        let anchorID: UUID
        let direction: Layout.SplitDirection
        let position: Layout.Position
        let sizingMode: DropSizingMode
    }

    static func insertingPane(
        _ paneID: UUID, in state: TabArrangementState, at anchorID: UUID,
        direction: Layout.SplitDirection, position: Layout.Position, sizingMode: DropSizingMode
    ) -> TabArrangementState? {
        insertingPane(
            in: state,
            insertion: PaneInsertion(
                paneID: paneID,
                anchorID: anchorID,
                direction: direction,
                position: position,
                sizingMode: sizingMode
            ),
            arrangementIndices: Array(state.arrangements.indices)
        )
    }

    static func insertingNewPane(
        _ paneID: UUID, in state: TabArrangementState, at anchorID: UUID,
        direction: Layout.SplitDirection, position: Layout.Position, sizingMode: DropSizingMode
    ) -> TabArrangementState? {
        guard !state.arrangements.isEmpty else { return nil }
        let activeIndex = activeArrangementIndex(in: state)
        let defaultIndex = defaultArrangementIndex(in: state)
        let insertionArrangementIndices =
            activeIndex == defaultIndex ? [activeIndex] : [activeIndex, defaultIndex]
        return insertingPane(
            in: state,
            insertion: PaneInsertion(
                paneID: paneID,
                anchorID: anchorID,
                direction: direction,
                position: position,
                sizingMode: sizingMode
            ),
            arrangementIndices: insertionArrangementIndices
        )
    }

    private static func insertingPane(
        in state: TabArrangementState,
        insertion: PaneInsertion,
        arrangementIndices: [Int]
    ) -> TabArrangementState? {
        let paneID = insertion.paneID
        guard !state.arrangements.isEmpty else { return nil }
        let activeIndex = activeArrangementIndex(in: state)
        guard
            let activeLayout = state.arrangements[activeIndex].layout.inserting(
                paneId: paneID,
                at: insertion.anchorID,
                direction: insertion.direction,
                position: insertion.position,
                sizingMode: insertion.sizingMode
            )
        else { return nil }
        var updated = state
        for index in arrangementIndices {
            if index == activeIndex {
                updated.arrangements[index].layout = activeLayout
                updated.arrangements[index].activePaneId = paneID
            } else if !updated.arrangements[index].layout.contains(paneID) {
                let layout = updated.arrangements[index].layout
                if let lastID = layout.paneIds.last {
                    guard
                        let appended = layout.inserting(
                            paneId: paneID, at: lastID, direction: .horizontal, position: .after,
                            sizingMode: .proportional
                        )
                    else { return nil }
                    updated.arrangements[index].layout = appended
                } else {
                    updated.arrangements[index].layout = Layout(paneId: paneID)
                }
            }
            updated.arrangements[index].minimizedPaneIds.remove(paneID)
        }
        if !updated.allPaneIds.contains(paneID) { updated.allPaneIds.append(paneID) }
        return updated
    }

    struct DrawerInsertion {
        let parentPaneId: UUID
        let drawerId: UUID
        let targetDrawerPaneId: UUID?
        let direction: SplitNewDirection
        let sizingMode: DropSizingMode
        /// Background creation keeps an existing selection; a first child of
        /// an empty drawer is still its only, and so its active, child.
        var selectsInsertedChild = true
    }

    static func insertingDrawerPane(
        _ drawerPaneId: UUID, in state: TabArrangementState, insertion: DrawerInsertion
    ) -> TabArrangementState? {
        insertingDrawerPane(
            drawerPaneId,
            in: state,
            insertion: insertion,
            arrangementIndices: Array(state.arrangements.indices)
        )
    }

    static func insertingNewDrawerPane(
        _ drawerPaneId: UUID, in state: TabArrangementState, insertion: DrawerInsertion
    ) -> TabArrangementState? {
        guard !state.arrangements.isEmpty else { return nil }
        let activeIndex = activeArrangementIndex(in: state)
        let defaultIndex = defaultArrangementIndex(in: state)
        let insertionArrangementIndices =
            activeIndex == defaultIndex ? [activeIndex] : [activeIndex, defaultIndex]
        guard
            var updated = insertingDrawerPane(
                drawerPaneId,
                in: state,
                insertion: insertion,
                arrangementIndices: insertionArrangementIndices
            )
        else { return nil }
        for arrangementIndex in insertionArrangementIndices {
            guard var drawerView = updated.arrangements[arrangementIndex].drawerViews[insertion.drawerId] else {
                continue
            }
            if insertion.selectsInsertedChild || drawerView.activeChildId != nil {
                drawerView.minimizedPaneIds.remove(drawerPaneId)
            } else {
                // Background creation keeps selection unchanged. A drawer with
                // no selection has every child minimized, and a visible child
                // there would need one, so the new child joins them minimized.
                drawerView.minimizedPaneIds.insert(drawerPaneId)
            }
            updated.arrangements[arrangementIndex].drawerViews[insertion.drawerId] = drawerView
        }
        return updated
    }

    private static func insertingDrawerPane(
        _ drawerPaneId: UUID, in state: TabArrangementState, insertion: DrawerInsertion,
        arrangementIndices: [Int]
    ) -> TabArrangementState? {
        let parentPaneId = insertion.parentPaneId
        let drawerId = insertion.drawerId
        let targetDrawerPaneId = insertion.targetDrawerPaneId
        let direction = insertion.direction
        let sizingMode = insertion.sizingMode
        var updated = state
        var didPlaceDrawerPane = false
        let activeIndex = activeArrangementIndex(in: updated)
        for arrangementIndex in arrangementIndices {
            guard updated.arrangements[arrangementIndex].layout.contains(parentPaneId) else {
                continue
            }
            var drawerView =
                updated.arrangements[arrangementIndex].drawerViews[drawerId]
                ?? DrawerView(layout: DrawerGridLayout(topRow: Layout(paneId: drawerPaneId)))

            if drawerView.layout.contains(drawerPaneId) {
                drawerView.activeChildId = drawerPaneId
                didPlaceDrawerPane = true
            } else if drawerView.layout.isEmpty {
                drawerView.layout = DrawerGridLayout(topRow: Layout(paneId: drawerPaneId))
                drawerView.activeChildId = drawerPaneId
                didPlaceDrawerPane = true
            } else {
                let targetPaneId = targetDrawerPaneId ?? drawerView.layout.paneIds.last
                if let targetPaneId,
                    let updatedLayout = drawerView.layout.inserting(
                        paneId: drawerPaneId,
                        at: targetPaneId,
                        direction: direction,
                        sizingMode: sizingMode
                    )
                {
                    drawerView.layout = updatedLayout
                    if arrangementIndex == activeIndex, insertion.selectsInsertedChild {
                        drawerView.activeChildId = drawerPaneId
                    }
                    didPlaceDrawerPane = true
                }
            }

            updated.arrangements[arrangementIndex].drawerViews[drawerId] = drawerView
        }

        if didPlaceDrawerPane, !updated.allPaneIds.contains(drawerPaneId) {
            updated.allPaneIds.append(drawerPaneId)
        }
        return didPlaceDrawerPane ? updated : nil
    }

    static func createArrangement(
        name: String,
        from state: TabArrangementState
    ) -> PaneArrangement? {
        let activeArrangement = activeArrangement(in: state)
        let mainLayoutPaneIds = mainLayoutPaneIds(in: state)
        guard
            let arrangementLayout = layoutForNewArrangement(
                basedOn: activeArrangement.layout,
                allPaneIds: mainLayoutPaneIds
            )
        else { return nil }
        let arrangementPaneIds = Set(arrangementLayout.paneIds)
        let arrangementMinimizedPaneIds = activeArrangement.minimizedPaneIds.intersection(arrangementPaneIds)

        return PaneArrangement(
            name: name,
            isDefault: false,
            layout: arrangementLayout,
            minimizedPaneIds: arrangementMinimizedPaneIds,
            activePaneId: TabArrangementSelectionRules.fallbackActivePaneId(
                currentActivePaneId: activeArrangement.activePaneId,
                in: PaneArrangement(
                    name: name,
                    isDefault: false,
                    layout: arrangementLayout,
                    minimizedPaneIds: arrangementMinimizedPaneIds
                )
            ),
            drawerViews: activeArrangement.drawerViews
        )
    }

    static func removingArrangement(_ arrangementId: UUID, from state: TabArrangementState) -> TabArrangementState {
        guard let arrangementIndex = state.arrangements.firstIndex(where: { $0.id == arrangementId }) else {
            return state
        }
        guard !state.arrangements[arrangementIndex].isDefault else {
            return state
        }

        var updated = state
        if updated.activeArrangementId == arrangementId {
            let defaultArrangement = defaultArrangement(in: updated)
            updated.activeArrangementId = defaultArrangement.id
        }
        updated.arrangements.remove(at: arrangementIndex)
        return updated
    }

    static func removingUserPane(
        _ paneId: UUID,
        removingDrawerId drawerId: UUID? = nil,
        from arrangements: [PaneArrangement]
    ) -> [PaneArrangement] {
        arrangements.map { arrangement in
            let drawerIds = drawerId.map { Set([$0]) } ?? []
            return TabArrangementRepairRules.removingPane(
                paneId,
                removingDrawerIds: drawerIds,
                layoutSizingMode: .proportional,
                from: [arrangement]
            )[0]
        }
    }

    static func switchingArrangement(to arrangementId: UUID, in state: TabArrangementState) -> TabArrangementState {
        guard state.arrangements.contains(where: { $0.id == arrangementId }) else { return state }
        guard state.activeArrangementId != arrangementId else { return state }

        var updated = state
        updated.activeArrangementId = arrangementId
        let arrangementIndex = activeArrangementIndex(in: updated)
        updated.arrangements[arrangementIndex].activePaneId = TabArrangementSelectionRules.fallbackActivePaneId(
            currentActivePaneId: updated.arrangements[arrangementIndex].activePaneId,
            in: updated.arrangements[arrangementIndex]
        )
        return updated
    }

    static func minimizingPane(_ paneId: UUID, in state: TabArrangementState) -> TabArrangementState? {
        let arrangement = activeArrangement(in: state)
        let layoutPaneIds = arrangement.layout.paneIds
        guard layoutPaneIds.contains(paneId) else { return nil }

        var updated = state
        var arrangementIndex = activeArrangementIndex(in: updated)
        if updated.arrangements[arrangementIndex].isDefault {
            let name = ArrangementDerived.nextCustomArrangementName(existing: updated.arrangements)
            guard let userArrangement = createArrangement(name: name, from: updated) else {
                return nil
            }
            updated.arrangements.append(userArrangement)
            updated.activeArrangementId = userArrangement.id
            arrangementIndex = updated.arrangements.index(before: updated.arrangements.endIndex)
        }
        updated.arrangements[arrangementIndex].minimizedPaneIds.insert(paneId)
        if updated.arrangements[arrangementIndex].activePaneId == paneId {
            let nonMinimized = layoutPaneIds.filter {
                !updated.arrangements[arrangementIndex].minimizedPaneIds.contains($0)
            }
            updated.arrangements[arrangementIndex].activePaneId = nonMinimized.first
        }
        return updated
    }

    static func expandingPane(_ paneId: UUID, in state: TabArrangementState) -> TabArrangementState {
        var updated = state
        let arrangementIndex = activeArrangementIndex(in: updated)
        guard updated.arrangements[arrangementIndex].minimizedPaneIds.contains(paneId) else { return state }
        updated.arrangements[arrangementIndex].minimizedPaneIds.remove(paneId)
        updated.arrangements[arrangementIndex].activePaneId = paneId
        return updated
    }

    static func breakingUpTab(
        _ state: TabArrangementState,
        drawerPayloadsByParentPaneId: [UUID: PaneDrawerMovePayload] = [:]
    ) -> [TabArrangementState] {
        let tabPaneIds = defaultArrangement(in: state).layout.paneIds
        guard tabPaneIds.count > 1 else { return [] }

        return tabPaneIds.map { paneId in
            let tab = Tab(paneId: paneId)
            var newState = TabArrangementState(
                tabId: tab.id,
                allPaneIds: tab.allPaneIds,
                arrangements: tab.arrangements,
                activeArrangementId: tab.activeArrangementId
            )
            if let drawerPayload = drawerPayloadsByParentPaneId[paneId] {
                applyDrawerPayload(drawerPayload, to: &newState)
            }
            return newState
        }
    }

    static func extractingPane(
        _ paneId: UUID,
        from state: TabArrangementState,
        drawerPayload: PaneDrawerMovePayload? = nil
    ) -> (updatedState: TabArrangementState, extractedState: TabArrangementState)? {
        guard activeArrangement(in: state).layout.paneIds.count > 1 else { return nil }
        guard state.allPaneIds.contains(paneId) else { return nil }

        var updated = state
        let movedPaneIds = Set([paneId] + (drawerPayload?.drawerPaneIds ?? []))
        let movedDrawerIds = Set([drawerPayload?.drawerId].compactMap(\.self))
        updated.arrangements = TabArrangementRepairRules.removingPanes(
            movedPaneIds,
            removingDrawerIds: movedDrawerIds,
            layoutSizingMode: .proportional,
            from: updated.arrangements
        )
        updated.allPaneIds.removeAll { movedPaneIds.contains($0) }

        let newTab = Tab(paneId: paneId)
        var extractedState = TabArrangementState(
            tabId: newTab.id,
            allPaneIds: newTab.allPaneIds,
            arrangements: newTab.arrangements,
            activeArrangementId: newTab.activeArrangementId
        )
        if let drawerPayload {
            applyDrawerPayload(drawerPayload, to: &extractedState)
        }
        return (updated, extractedState)
    }

    static func merging(
        source: TabArrangementState,
        into target: TabArrangementState,
        at targetPaneId: UUID,
        direction: Layout.SplitDirection,
        position: Layout.Position,
        drawerPayloadsByParentPaneId: [UUID: PaneDrawerMovePayload] = [:]
    ) -> TabArrangementState? {
        let targetArrangement = activeArrangement(in: target)
        guard targetArrangement.layout.contains(targetPaneId) else { return nil }

        var updated = target
        let sourcePaneIds = defaultArrangement(in: source).layout.paneIds
        for arrangementIndex in updated.arrangements.indices {
            var currentTarget = targetPaneId
            for paneId in sourcePaneIds {
                let updatedLayout: Layout?
                if updated.arrangements[arrangementIndex].layout.contains(currentTarget) {
                    updatedLayout = updated.arrangements[arrangementIndex].layout.inserting(
                        paneId: paneId,
                        at: currentTarget,
                        direction: direction,
                        position: position,
                        sizingMode: .halveTarget
                    )
                } else {
                    updatedLayout = appendingPane(
                        paneId,
                        to: updated.arrangements[arrangementIndex].layout
                    )
                }
                guard let updatedLayout else { return nil }
                updated.arrangements[arrangementIndex].layout = updatedLayout
                updated.arrangements[arrangementIndex].minimizedPaneIds.remove(paneId)
                if let drawerPayload = drawerPayloadsByParentPaneId[paneId] {
                    updated.arrangements[arrangementIndex].drawerViews[drawerPayload.drawerId] =
                        drawerView(for: drawerPayload)
                }
                if position == .after {
                    currentTarget = paneId
                }
            }
        }

        for paneId in sourcePaneIds {
            let movedPaneIds = [paneId] + (drawerPayloadsByParentPaneId[paneId]?.drawerPaneIds ?? [])
            for movedPaneId in movedPaneIds where !updated.allPaneIds.contains(movedPaneId) {
                updated.allPaneIds.append(movedPaneId)
            }
        }
        return updated
    }

    private static func defaultArrangement(in state: TabArrangementState) -> PaneArrangement {
        state.arrangements[defaultArrangementIndex(in: state)]
    }

    private static func activeArrangement(in state: TabArrangementState) -> PaneArrangement {
        state.arrangements[activeArrangementIndex(in: state)]
    }

    private static func mainLayoutPaneIds(in state: TabArrangementState) -> [UUID] {
        let drawerViewPaneIds = Set(
            state.arrangements.flatMap { arrangement in
                arrangement.drawerViews.values.flatMap(\.layout.paneIds)
            })
        return state.allPaneIds.filter { !drawerViewPaneIds.contains($0) }
    }

    private static func applyDrawerPayload(_ drawerPayload: PaneDrawerMovePayload, to state: inout TabArrangementState)
    {
        for drawerPaneId in drawerPayload.drawerPaneIds where !state.allPaneIds.contains(drawerPaneId) {
            state.allPaneIds.append(drawerPaneId)
        }
        for arrangementIndex in state.arrangements.indices {
            state.arrangements[arrangementIndex].drawerViews[drawerPayload.drawerId] =
                drawerView(for: drawerPayload)
        }
    }

    private static func drawerView(for drawerPayload: PaneDrawerMovePayload) -> DrawerView {
        guard let drawerView = drawerPayload.drawerView,
            !drawerView.layout.isEmpty,
            Set(drawerPayload.drawerPaneIds).isSubset(of: Set(drawerView.layout.paneIds))
        else {
            return drawerViewSeed(drawerPayload)
        }
        return drawerView
    }

    private static func drawerViewSeed(_ drawerPayload: PaneDrawerMovePayload) -> DrawerView {
        DrawerView(
            layout: DrawerGridLayout(topRow: Layout.autoTiled(drawerPayload.drawerPaneIds)),
            activeChildId: drawerPayload.drawerPaneIds.first,
            minimizedPaneIds: []
        )
    }

    private static func layoutForNewArrangement(
        basedOn activeLayout: Layout,
        allPaneIds: [UUID]
    ) -> Layout? {
        guard !allPaneIds.isEmpty else { return nil }

        var layout = activeLayout
        let tabPaneIds = Set(allPaneIds)
        for paneId in layout.paneIds where !tabPaneIds.contains(paneId) {
            layout = layout.removing(paneId: paneId, sizingMode: .halveTarget) ?? Layout()
        }

        for paneId in allPaneIds where !layout.contains(paneId) {
            guard let updatedLayout = appendingPane(paneId, to: layout) else {
                return Layout.autoTiled(allPaneIds)
            }
            layout = updatedLayout
        }

        return layout.isEmpty ? Layout.autoTiled(allPaneIds) : layout
    }

    private static func appendingPane(_ paneId: UUID, to layout: Layout) -> Layout? {
        guard let anchorPaneId = layout.paneIds.last else { return Layout(paneId: paneId) }
        return layout.inserting(
            paneId: paneId,
            at: anchorPaneId,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
    }

    private static func defaultArrangementIndex(in state: TabArrangementState) -> Int {
        state.arrangements.firstIndex(where: \.isDefault) ?? 0
    }

    private static func activeArrangementIndex(in state: TabArrangementState) -> Int {
        state.arrangements.firstIndex { $0.id == state.activeArrangementId } ?? defaultArrangementIndex(in: state)
    }
}
