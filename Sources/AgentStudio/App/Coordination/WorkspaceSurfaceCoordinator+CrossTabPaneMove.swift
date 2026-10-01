import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@MainActor
extension WorkspaceSurfaceCoordinator {
    struct CrossTabMoveViewTransitions: Equatable {
        let paneIdsToDetach: Set<UUID>
        let paneIdsToReattach: Set<UUID>
    }

    nonisolated static func computeCrossTabMoveViewTransitions(
        destinationVisibleBefore: Set<UUID>,
        destinationVisibleAfter: Set<UUID>,
        movedPaneIds: Set<UUID>
    ) -> CrossTabMoveViewTransitions {
        let newlyVisibleDestinationPaneIds = destinationVisibleAfter.subtracting(destinationVisibleBefore)
        let movedPaneIdsVisibleAfterMove = destinationVisibleAfter.intersection(movedPaneIds)
        let hiddenDestinationPaneIds = destinationVisibleBefore.subtracting(destinationVisibleAfter)

        return CrossTabMoveViewTransitions(
            // Persistent source-tab hosts stay mounted. Keep their surfaces attached so
            // renderer visibility reconciliation can resume them when that tab returns.
            paneIdsToDetach: movedPaneIds.union(hiddenDestinationPaneIds),
            paneIdsToReattach: newlyVisibleDestinationPaneIds.union(movedPaneIdsVisibleAfterMove)
        )
    }

    func executeMovePaneAcrossTabs(_ request: CrossTabPaneMoveRequest) {
        let paneId = request.paneId
        let sourceTabId = request.sourceTabId
        let destTabId = request.destTabId
        guard let pane = store.paneAtom.pane(paneId) else {
            Self.logger.warning("movePaneAcrossTabs: pane \(paneId) not found")
            return
        }

        let destinationVisibleBefore = Set(crossTabMoveVisiblePaneIds(forTab: destTabId))
        let capturedZoomCompanion =
            store.panePresentationAtom.zoomCompanion(forSourcePane: paneId)
        let drawer = pane.drawer
        let movedPaneIds = Set([paneId] + (drawer?.paneIds ?? []))
        if store.panePresentationAtom.zoomPresentation(forTab: sourceTabId)?.sourcePaneId == paneId {
            store.panePresentationAtom.cancelZoom(inTab: sourceTabId)
        }
        guard
            let result = store.tabLayoutAtom.movePaneAcrossTabs(
                CrossTabPaneMoveMutation(
                    request: request,
                    drawerId: drawer?.drawerId,
                    drawerPaneIds: drawer?.paneIds ?? []
                )
            )
        else {
            Self.logger.warning("movePaneAcrossTabs: failed moving pane \(paneId) into tab \(destTabId)")
            return
        }

        RestoreTrace.log(
            PaneArrangementTraceMessages.crossTabPaneMove(
                paneId: paneId,
                sourceTabId: sourceTabId,
                destTabId: destTabId,
                sourceTabClosed: result.sourceTabClosed
            )
        )
        updateZoomCompanionOwnership(
            forSourcePane: paneId,
            capturedCompanion: capturedZoomCompanion,
            owningTabId: destTabId
        )
        let destinationVisibleAfter = Set(crossTabMoveVisiblePaneIds(forTab: destTabId))
        let transitions = Self.computeCrossTabMoveViewTransitions(
            destinationVisibleBefore: destinationVisibleBefore,
            destinationVisibleAfter: destinationVisibleAfter,
            movedPaneIds: movedPaneIds
        )
        for paneIdToDetach in transitions.paneIdsToDetach {
            detachForViewSwitch(paneId: paneIdToDetach)
        }
        for paneIdToReattach in transitions.paneIdsToReattach {
            reattachForViewSwitch(paneId: paneIdToReattach)
        }
        restoreViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)
        focusVisiblePaneHost(paneId)
    }

    private func crossTabMoveVisiblePaneIds(forTab tabId: UUID) -> [UUID] {
        var seenPaneIds: Set<UUID> = []
        var paneIds: [UUID] = []
        func append(_ paneId: UUID) {
            guard seenPaneIds.insert(paneId).inserted else { return }
            paneIds.append(paneId)
        }

        for paneId in arrangementView.activeVisiblePaneIds(forTab: tabId) {
            append(paneId)
            guard store.paneAtom.pane(paneId)?.drawer?.isExpanded == true else { continue }
            for drawerPaneId in arrangementView.drawerVisiblePaneIds(forParent: paneId) {
                append(drawerPaneId)
            }
        }
        return paneIds
    }

    func reconcileVisiblePaneTransition(previousVisiblePaneIds: Set<UUID>, newVisiblePaneIds: Set<UUID>) {
        for paneId in previousVisiblePaneIds.subtracting(newVisiblePaneIds) {
            detachForViewSwitch(paneId: paneId)
        }
        for paneId in newVisiblePaneIds.subtracting(previousVisiblePaneIds) {
            restoreVisiblePaneIfNeeded(paneId, forceWhenBoundsExist: true)
            if viewRegistry.terminalView(for: paneId) != nil {
                reattachForViewSwitch(paneId: paneId)
            }
        }
    }
}
