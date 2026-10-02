import AgentStudioInfrastructure
import Foundation

package struct WorkspaceUndoCloseProposal: Sendable {
    let bundle: WorkspaceSQLiteSaveBundle
    package let snapshot: WorkspaceUndoCloseSnapshot
    package let write: WorkspaceUndoCloseWrite
    package let removedPaneIDs: Set<UUID>
    package let tabID: UUID
}

enum WorkspaceUndoCompositionFailure: Error, Equatable {
    case missingTarget
    case invalidComposition
}

enum WorkspaceUndoComposition {
    @concurrent nonisolated static func prepareCloseOffMain(
        in source: WorkspaceSQLiteSaveBundle,
        tabID: UUID,
        paneID: UUID?,
        closeID: UUID,
        time: WorkspaceUndoJournalTime,
        isManagementLayerActive: Bool = false
    ) async throws -> WorkspaceUndoCloseProposal {
        try prepareClose(
            in: source, tabID: tabID, paneID: paneID, closeID: closeID, time: time,
            isManagementLayerActive: isManagementLayerActive)
    }

    static func prepareClose(
        in source: WorkspaceSQLiteSaveBundle,
        tabID: UUID,
        paneID: UUID?,
        closeID: UUID,
        time: WorkspaceUndoJournalTime,
        isManagementLayerActive: Bool = false
    ) throws -> WorkspaceUndoCloseProposal {
        try validateUndoJournalTime(time)
        let original = source.workspace
        guard let tabIndex = original.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw WorkspaceUndoCompositionFailure.missingTarget
        }
        guard Set(original.panes.map(\.id)).count == original.panes.count else {
            throw WorkspaceUndoCompositionFailure.invalidComposition
        }
        let panes = Dictionary(uniqueKeysWithValues: original.panes.map { ($0.id, $0) })
        let tab = original.tabs[tabIndex]
        let snapshot = try closeSnapshot(tab: tab, tabIndex: tabIndex, paneID: paneID, panes: panes)
        var updated = original

        switch snapshot {
        case .tab:
            updated.tabs.remove(at: tabIndex)
        case .pane(let close):
            let updatedTab = try removingPane(close.pane, from: tab, workspace: &updated)
            updated.tabs[tabIndex] = updatedTab
        }

        let updatedPanes = Dictionary(uniqueKeysWithValues: updated.panes.map { ($0.id, $0) })
        let remainingReferences = Set(
            updated.tabs.flatMap { remainingTab in
                remainingTab.allPaneIds.flatMap { id in [id] + (updatedPanes[id]?.drawer?.paneIds ?? []) }
            }
        )
        let closingIDs = Set(snapshot.panes.map(\.id))
        let removedIDs = closingIDs.subtracting(remainingReferences)
        updated.panes.removeAll { removedIDs.contains($0.id) }
        if let activeID = updated.activeTabId, !updated.tabs.contains(where: { $0.id == activeID }) {
            updated.activeTabId = updated.tabs.last?.id
        }
        updated.updatedAt = time.utc
        guard let grace = Int64(exactly: AppPolicies.WorkspacePersistence.undoGracePeriod.nanosecondsForTaskSleep)
        else {
            throw WorkspaceUndoJournalFailure.deadlineOverflow
        }
        let (deadline, overflow) = time.uptimeNanoseconds.addingReportingOverflow(grace)
        guard !overflow else { throw WorkspaceUndoJournalFailure.deadlineOverflow }
        let write = WorkspaceUndoCloseWrite(
            closeID: closeID,
            workspaceID: original.id,
            kind: snapshot.kind,
            closedAt: time.utc,
            expiresAt: time.utc.addingTimeInterval(Double(grace) / 1_000_000_000),
            deadlineBootID: time.bootID,
            deadlineUptimeNanoseconds: deadline,
            snapshotVersion: WorkspaceUndoCloseSnapshot.currentVersion,
            snapshotPayload: try JSONEncoder().encode(snapshot),
            members: snapshot.members,
            isUndoAvailable: offersUndo(
                snapshot: snapshot, tab: tab, workspace: original, isManagementLayerActive: isManagementLayerActive)
        )
        return .init(
            bundle: .init(workspace: updated, captureRevision: source.captureRevision),
            snapshot: snapshot,
            write: write,
            removedPaneIDs: removedIDs,
            tabID: tabID
        )
    }

    /// Preserve the existing close policy: whole tabs are undoable; a single
    /// hidden/background-tab pane closes without offering an Undo operation.
    private static func offersUndo(
        snapshot: WorkspaceUndoCloseSnapshot, tab: Tab, workspace: WorkspaceSQLiteSnapshot,
        isManagementLayerActive: Bool
    ) -> Bool {
        guard case .pane(let close) = snapshot else { return true }
        guard workspace.activeTabId == tab.id else { return false }
        let pane = close.pane
        let parentID = pane.parentPaneId ?? pane.id
        guard pane.residency.isActive,
            let parent = workspace.panes.first(where: { $0.id == parentID }), parent.residency.isActive,
            tab.activePaneIds.contains(parentID),
            isManagementLayerActive || !tab.activeMinimizedPaneIds.contains(parentID)
        else { return false }
        guard let drawerParentID = pane.parentPaneId else { return true }
        guard parent.id == drawerParentID, let drawer = parent.drawer,
            let view = tab.activeArrangement.drawerViews[drawer.drawerId]
        else { return false }
        return view.layout.paneIds.contains(pane.id)
            && (isManagementLayerActive || !view.minimizedPaneIds.contains(pane.id))
    }

    private static func closeSnapshot(
        tab: Tab,
        tabIndex: Int,
        paneID: UUID?,
        panes: [UUID: Pane]
    ) throws -> WorkspaceUndoCloseSnapshot {
        if let paneID {
            guard let pane = panes[paneID] else { throw WorkspaceUndoCompositionFailure.missingTarget }
            let parent = pane.parentPaneId.flatMap { panes[$0] }
            let belongsToTab =
                tab.allPaneIds.contains(paneID)
                || (parent.map { tab.allPaneIds.contains($0.id) && ($0.drawer?.paneIds.contains(paneID) == true) }
                    ?? false)
            guard belongsToTab else { throw WorkspaceUndoCompositionFailure.missingTarget }
            let remainingMain = tab.allPaneIds.filter { $0 != paneID && panes[$0]?.isDrawerChild == false }
            if pane.isDrawerChild || !remainingMain.isEmpty {
                let children = try ownedDrawerChildren(of: pane, panes: panes)
                let views: [UUID: DrawerView]
                if let drawerID = pane.drawer?.drawerId {
                    views = Dictionary(
                        uniqueKeysWithValues: tab.arrangements.compactMap { arrangement in
                            arrangement.drawerViews[drawerID].map { (arrangement.id, $0) }
                        })
                } else {
                    views = [:]
                }
                return .pane(
                    .init(
                        pane: pane,
                        drawerChildPanes: children,
                        drawerViewsByArrangementID: views,
                        tabID: tab.id,
                        anchorPaneID: pane.isDrawerChild ? pane.parentPaneId : tab.activePaneIds.first { $0 != paneID },
                        direction: .horizontal
                    )
                )
            }
        }
        var seen = Set<UUID>()
        var owned: [Pane] = []
        for id in tab.allPaneIds {
            guard let pane = panes[id] else { throw WorkspaceUndoCompositionFailure.invalidComposition }
            for member in [pane] + (try ownedDrawerChildren(of: pane, panes: panes)) {
                if seen.insert(member.id).inserted { owned.append(member) }
            }
        }
        return .tab(tab: tab, panes: owned, tabIndex: tabIndex)
    }

    private static func ownedDrawerChildren(of pane: Pane, panes: [UUID: Pane]) throws -> [Pane] {
        try (pane.drawer?.paneIds ?? []).map { id in
            guard let child = panes[id] else { throw WorkspaceUndoCompositionFailure.invalidComposition }
            return child
        }
    }

    private static func removingPane(_ pane: Pane, from tab: Tab, workspace: inout WorkspaceSQLiteSnapshot) throws
        -> Tab
    {
        var arrangements = tab.arrangements
        let removedIDs = Set([pane.id] + (pane.drawer?.paneIds ?? []))
        if pane.isDrawerChild {
            guard let parentID = pane.parentPaneId,
                let parentIndex = workspace.panes.firstIndex(where: { $0.id == parentID }),
                let drawerID = workspace.panes[parentIndex].drawer?.drawerId
            else { throw WorkspaceUndoCompositionFailure.invalidComposition }
            workspace.panes[parentIndex].withDrawer { $0.paneIds.removeAll { $0 == pane.id } }
            for index in arrangements.indices {
                guard var view = arrangements[index].drawerViews[drawerID] else { continue }
                view.minimizedPaneIds.remove(pane.id)
                if view.layout.contains(pane.id) {
                    view.layout = view.layout.removing(paneId: pane.id, sizingMode: .proportional) ?? DrawerGridLayout()
                }
                if view.layout.isEmpty {
                    arrangements[index].drawerViews.removeValue(forKey: drawerID)
                } else {
                    if view.activeChildId == pane.id {
                        view.activeChildId = DrawerChildSelectionRule.firstVisibleChild(
                            orderedPaneIds: view.layout.paneIds,
                            minimizedPaneIds: view.minimizedPaneIds
                        )
                    }
                    arrangements[index].drawerViews[drawerID] = view
                }
            }
        } else {
            arrangements = TabArrangementMutationRules.removingUserPane(
                pane.id, removingDrawerId: pane.drawer?.drawerId, from: arrangements
            )
        }
        var activeID = tab.activeArrangementId
        if arrangements.first(where: { $0.id == activeID })?.layout.isEmpty == true,
            let defaultArrangement = arrangements.first(where: { $0.isDefault }), !defaultArrangement.layout.isEmpty
        {
            activeID = defaultArrangement.id
        }
        return Tab(
            id: tab.id, name: tab.name, allPaneIds: tab.allPaneIds.filter { !removedIDs.contains($0) },
            arrangements: arrangements, activeArrangementId: activeID, colorHex: tab.colorHex
        )
    }
}
