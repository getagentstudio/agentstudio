import Foundation
import os.log

@MainActor
package final class WorkspaceMutationCoordinator {
    package enum RestorePaneResult: Equatable {
        case restored
        case failedMissingDrawerParent(UUID?)
        case failedLayoutInsertion(tabId: UUID, anchorPaneId: UUID?)
    }

    package enum CloseEntry {
        case tab(TabCloseSnapshot)
        case pane(PaneCloseSnapshot)

        package var panes: [Pane] {
            switch self {
            case .tab(let snapshot):
                snapshot.panes
            case .pane(let snapshot):
                [snapshot.pane] + snapshot.drawerChildPanes
            }
        }
    }

    package struct TabCloseSnapshot {
        package let tab: Tab
        package let panes: [Pane]
        package let tabIndex: Int
    }

    package struct PaneCloseSnapshot {
        package let pane: Pane
        package let drawerChildPanes: [Pane]
        package let drawerViewsByArrangementId: [UUID: DrawerView]
        package let tabId: UUID
        package let anchorPaneId: UUID?
        package let direction: Layout.SplitDirection

        package init(
            pane: Pane,
            drawerChildPanes: [Pane],
            drawerViewsByArrangementId: [UUID: DrawerView] = [:],
            tabId: UUID,
            anchorPaneId: UUID?,
            direction: Layout.SplitDirection
        ) {
            self.pane = pane
            self.drawerChildPanes = drawerChildPanes
            self.drawerViewsByArrangementId = drawerViewsByArrangementId
            self.tabId = tabId
            self.anchorPaneId = anchorPaneId
            self.direction = direction
        }
    }

    let repositoryTopologyAtom: RepositoryTopologyAtom
    private let workspacePaneAtom: WorkspacePaneAtom
    private let workspaceTabShellAtom: WorkspaceTabShellAtom
    private let workspaceTabArrangementAtom: WorkspaceTabArrangementAtom

    private var workspaceTab: WorkspaceTabLayoutDerived {
        WorkspaceTabLayoutDerived(
            shellAtom: workspaceTabShellAtom,
            arrangementAtom: workspaceTabArrangementAtom
        )
    }

    package init(
        repositoryTopologyAtom: RepositoryTopologyAtom,
        workspacePaneAtom: WorkspacePaneAtom,
        workspaceTabShellAtom: WorkspaceTabShellAtom,
        workspaceTabArrangementAtom: WorkspaceTabArrangementAtom
    ) {
        self.repositoryTopologyAtom = repositoryTopologyAtom
        self.workspacePaneAtom = workspacePaneAtom
        self.workspaceTabShellAtom = workspaceTabShellAtom
        self.workspaceTabArrangementAtom = workspaceTabArrangementAtom
    }

    @discardableResult
    package func removePane(_ paneId: UUID) -> Bool {
        let removedPane = workspacePaneAtom.pane(paneId)
        let removedDrawerIds = Set([removedPane?.drawer?.drawerId].compactMap(\.self))
        let removedPaneIds = Set([paneId] + (removedPane?.drawer?.paneIds ?? []))
        guard workspacePaneAtom.deletePaneAndOwnedDrawerChildren(paneId) else {
            Logger(subsystem: "com.agentstudio", category: "WorkspaceMutationCoordinator")
                .warning("removePane: pane \(paneId) not found")
            return false
        }
        for removedPaneId in removedPaneIds {
            workspaceTabArrangementAtom.presentationAtom.removeZoomSourcePane(removedPaneId)
        }
        workspaceTabArrangementAtom.removePaneReferences(removedPaneIds, removingDrawerIds: removedDrawerIds)
        removeEmptyTabs()
        return true
    }

    func applyCommittedTerminalCreation(_ proposal: WorkspaceTerminalCreationProposal) {
        let expandsDrawer: Bool
        if case .drawer(let insertion) = proposal.placement {
            expandsDrawer = insertion.presentation == .interactive
        } else {
            expandsDrawer = true
        }
        workspacePaneAtom.insertCommittedTerminalPane(
            proposal.pane, associationOutcome: proposal.associationOutcome, expandsDrawer: expandsDrawer)
        switch proposal.placement {
        case .newTab:
            workspaceTabShellAtom.appendTabShell(
                .init(id: proposal.tab.id, name: proposal.tab.name, colorHex: proposal.tab.colorHex))
            workspaceTabArrangementAtom.appendState(Self.arrangementState(from: proposal.tab))
            workspaceTabShellAtom.setActiveTab(proposal.tab.id)
        case .split:
            workspaceTabArrangementAtom.replaceArrangementStates(
                workspaceTabArrangementAtom.arrangementStates.map {
                    $0.tabId == proposal.tab.id ? Self.arrangementState(from: proposal.tab) : $0
                })
        case .drawer(let insertion):
            // `proposal.tab` was captured before this creation's awaited
            // off-main prepare and SQLite save; a human cursor write (for
            // example selecting a different drawer child) can land during
            // that wait and must survive this stale capture's publish.
            let publishedState = Self.arrangementState(from: proposal.tab)
            let liveState = workspaceTabArrangementAtom.arrangementState(proposal.tab.id)
            let committedState = TabArrangementCursorPreservation.committedDrawerInsertionState(
                published: publishedState, live: liveState, presentation: insertion.presentation)
            workspaceTabArrangementAtom.replaceArrangementStates(
                workspaceTabArrangementAtom.arrangementStates.map {
                    $0.tabId == proposal.tab.id ? committedState : $0
                })
        }
    }

    func applyCommittedDiscard(_ proposal: WorkspacePaneDiscardProposal) {
        _ = removePane(proposal.paneID)
        if let parentID = proposal.parentPaneID {
            workspacePaneAtom.removeDrawerPane(proposal.paneID, from: parentID)
        }
    }

    /// Publish only the committed close delta. Other pane metadata may have advanced during I/O.
    func applyCommittedClose(_ proposal: WorkspaceUndoCloseProposal) {
        for pane in proposal.snapshot.panes where proposal.removedPaneIDs.contains(pane.id) {
            if let parentID = pane.parentPaneId, !proposal.removedPaneIDs.contains(parentID) {
                workspacePaneAtom.removeDrawerPane(pane.id, from: parentID)
            } else {
                _ = workspacePaneAtom.deletePaneAndOwnedDrawerChildren(pane.id)
            }
            workspaceTabArrangementAtom.presentationAtom.removeZoomSourcePane(pane.id)
        }

        let committedTab = proposal.bundle.workspace.tabs.first { $0.id == proposal.tabID }
        let states = workspaceTabArrangementAtom.arrangementStates.compactMap { state -> TabArrangementState? in
            guard state.tabId == proposal.tabID else { return state }
            return committedTab.map(Self.arrangementState)
        }
        workspaceTabArrangementAtom.replaceArrangementStates(states)
        if committedTab == nil {
            workspaceTabShellAtom.removeTabShell(proposal.tabID)
            workspaceTabArrangementAtom.presentationAtom.removeZoomTab(proposal.tabID)
        }
    }

    func applyCommittedRestore(_ proposal: WorkspaceUndoRestoreProposal) {
        for pane in proposal.close.snapshot.panes {
            _ = workspacePaneAtom.insertRestoredPane(paneWithCurrentTopologyFacets(pane))
        }
        if case .pane(let snapshot) = proposal.close.snapshot,
            let parentID = snapshot.pane.parentPaneId
        {
            _ = workspacePaneAtom.restoreDrawerPane(paneWithCurrentTopologyFacets(snapshot.pane), to: parentID)
        }
        guard let tab = proposal.bundle.workspace.tabs.first(where: { $0.id == proposal.tabID }) else {
            preconditionFailure("Committed restore must include its target tab")
        }
        switch proposal.close.snapshot {
        case .tab(_, _, let index):
            workspaceTabShellAtom.insertTabShell(
                .init(id: tab.id, name: tab.name, colorHex: tab.colorHex), at: max(0, index)
            )
            workspaceTabArrangementAtom.insertState(Self.arrangementState(from: tab), at: max(0, index))
        case .pane:
            let states = workspaceTabArrangementAtom.arrangementStates.map { state in
                state.tabId == tab.id ? Self.arrangementState(from: tab) : state
            }
            workspaceTabArrangementAtom.replaceArrangementStates(states)
        }
        workspaceTabShellAtom.setActiveTab(tab.id)
        if let expandedDrawer = proposal.close.snapshot.panes.compactMap(\.drawer).first(where: \.isExpanded) {
            workspacePaneAtom.drawerCursorAtom.expandDrawer(drawerId: expandedDrawer.drawerId)
        }
    }

    @discardableResult
    package func setPanePinned(_ paneId: UUID, isPinned: Bool) -> Bool {
        guard workspacePaneAtom.pane(paneId) != nil else { return false }
        workspacePaneAtom.updatePanePinned(paneId, isPinned: isPinned)
        return true
    }

    @discardableResult
    package func backgroundPane(_ paneId: UUID) -> Bool {
        guard let backgroundedPane = workspacePaneAtom.pane(paneId) else {
            Logger(subsystem: "com.agentstudio", category: "WorkspaceMutationCoordinator")
                .warning("backgroundPane: pane \(paneId) not found")
            return false
        }
        workspacePaneAtom.setResidency(.backgrounded, for: paneId)
        for drawerPaneId in backgroundedPane.drawer?.paneIds ?? [] {
            workspacePaneAtom.setResidency(.backgrounded, for: drawerPaneId)
        }
        return true
    }

    @discardableResult
    package func reactivatePane(
        _ paneId: UUID,
        inTab tabId: UUID,
        at targetPaneId: UUID,
        direction: Layout.SplitDirection,
        position: Layout.Position,
        sizingMode: DropSizingMode
    ) -> Bool {
        guard
            let pane = workspacePaneAtom.pane(paneId),
            pane.residency == .backgrounded
        else {
            Logger(subsystem: "com.agentstudio", category: "WorkspaceMutationCoordinator")
                .warning("reactivatePane: pane \(paneId) not found or not backgrounded")
            return false
        }

        if workspaceTab.tabContaining(paneId: paneId) != nil {
            workspacePaneAtom.setResidency(.active, for: paneId)
            for drawerPaneId in pane.drawer?.paneIds ?? [] {
                workspacePaneAtom.setResidency(.active, for: drawerPaneId)
            }
            return true
        }

        guard
            workspaceTabArrangementAtom.insertPane(
                paneId,
                inTab: tabId,
                at: targetPaneId,
                direction: direction,
                position: position,
                sizingMode: sizingMode
            )
        else {
            Logger(subsystem: "com.agentstudio", category: "WorkspaceMutationCoordinator")
                .warning("reactivatePane: failed inserting pane \(paneId) into tab \(tabId) at anchor \(targetPaneId)")
            return false
        }
        workspacePaneAtom.setResidency(.active, for: paneId)
        if let drawer = pane.drawer, !drawer.paneIds.isEmpty {
            for drawerPaneId in drawer.paneIds {
                workspacePaneAtom.setResidency(.active, for: drawerPaneId)
            }
            workspaceTabArrangementAtom.restoreDrawerPaneViews(
                drawerId: drawer.drawerId,
                parentPaneId: paneId,
                drawerPaneIds: drawer.paneIds,
                drawerViewsByArrangementId: [:],
                inTab: tabId
            )
        }
        return true
    }

    func applyRepoReassociation(
        _ result: RepositoryReassociationResult
    ) -> RepositoryReassociationResult {
        result
    }

    @discardableResult
    package func clearPaneAssociations(forRemovedWorktreeID removedWorktreeID: UUID) -> [UUID] {
        let affectedPaneIDs = workspacePaneAtom.graphAtom.paneStateSnapshot().values.compactMap { state in
            state.durableContextFacets.worktreeId == removedWorktreeID ? state.id : nil
        }
        for paneID in affectedPaneIDs {
            guard
                let state = workspacePaneAtom.graphAtom.paneState(paneID),
                let revision = workspacePaneAtom.graphAtom.reservePaneAssociationRevision(paneID)
            else { continue }
            _ = workspacePaneAtom.graphAtom.applyPaneAssociationUpdate(
                paneID,
                cwd: state.durableContextFacets.cwd,
                resolution: .confidentNoMatch,
                revision: revision
            )
        }
        return affectedPaneIDs
    }

    @discardableResult
    package func reconcilePaneAssociationsForCurrentTopology(
        affectedWorktreeIDs: Set<UUID>
    ) -> [UUID] {
        guard !affectedWorktreeIDs.isEmpty else { return [] }
        let topologySnapshot = repositoryTopologyAtom.captureReadSnapshot()
        let reconciliationCandidates: [(paneID: UUID, cwd: URL?, resolution: PaneAssociationResolution)] =
            workspacePaneAtom.graphAtom.paneStateSnapshot().values.compactMap { state in
                let facets = state.durableContextFacets
                let resolvedContext = topologySnapshot.repoAndWorktree(containing: facets.cwd)
                let currentAssociationIsAffected = facets.worktreeId.map(affectedWorktreeIDs.contains) ?? false
                let resolvedAssociationIsAffected =
                    resolvedContext.map { affectedWorktreeIDs.contains($0.worktree.id) } ?? false
                guard currentAssociationIsAffected || resolvedAssociationIsAffected else { return nil }

                let resolution: PaneAssociationResolution
                if let resolvedContext {
                    resolution = .matched(
                        repoId: resolvedContext.repo.id,
                        worktreeId: resolvedContext.worktree.id
                    )
                } else {
                    resolution = .confidentNoMatch
                }
                return (state.id, facets.cwd, resolution)
            }
        var changedPaneIDs: [UUID] = []
        for (paneID, cwd, resolution) in reconciliationCandidates {
            guard let revision = workspacePaneAtom.graphAtom.reservePaneAssociationRevision(paneID) else {
                continue
            }
            let updateResult = workspacePaneAtom.graphAtom.applyPaneAssociationUpdate(
                paneID,
                cwd: cwd,
                resolution: resolution,
                revision: revision
            )
            if updateResult == .applied {
                changedPaneIDs.append(paneID)
            }
        }
        return changedPaneIDs
    }

    package func snapshotForClose(tabId: UUID) -> TabCloseSnapshot? {
        let tabs = workspaceTab.tabs
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let tab = tabs[tabIndex]
        var allPanes: [Pane] = []
        var seenPaneIds = Set<UUID>()
        for paneId in tab.allPaneIds {
            guard let layoutPane = workspacePaneAtom.pane(paneId) else { continue }
            if seenPaneIds.insert(layoutPane.id).inserted {
                allPanes.append(layoutPane)
            }
            if let drawer = layoutPane.drawer {
                for drawerPane in workspacePaneAtom.snapshotPanes(with: drawer.paneIds)
                where seenPaneIds.insert(drawerPane.id).inserted {
                    allPanes.append(drawerPane)
                }
            }
        }
        return TabCloseSnapshot(tab: tab, panes: allPanes, tabIndex: tabIndex)
    }

    package func snapshotForPaneClose(paneId: UUID, inTab tabId: UUID) -> PaneCloseSnapshot? {
        guard let closedPane = workspacePaneAtom.pane(paneId), let tab = workspaceTab.tab(tabId) else {
            return nil
        }

        let drawerChildPanes = closedPane.drawer.map { workspacePaneAtom.snapshotPanes(with: $0.paneIds) } ?? []
        let drawerViewsByArrangementId: [UUID: DrawerView]
        if let drawerId = closedPane.drawer?.drawerId {
            drawerViewsByArrangementId = Dictionary(
                uniqueKeysWithValues: tab.arrangements.compactMap { arrangement in
                    arrangement.drawerViews[drawerId].map { (arrangement.id, $0) }
                }
            )
        } else {
            drawerViewsByArrangementId = [:]
        }
        let anchorPaneId: UUID?
        let direction: Layout.SplitDirection

        if closedPane.isDrawerChild {
            anchorPaneId = closedPane.parentPaneId
            direction = .horizontal
        } else {
            anchorPaneId = tab.activePaneIds.first { $0 != paneId }
            direction = .horizontal
        }

        return PaneCloseSnapshot(
            pane: closedPane,
            drawerChildPanes: drawerChildPanes,
            drawerViewsByArrangementId: drawerViewsByArrangementId,
            tabId: tabId,
            anchorPaneId: anchorPaneId,
            direction: direction
        )
    }

    package func restoreFromSnapshot(_ snapshot: TabCloseSnapshot) {
        for pane in snapshot.panes {
            _ = workspacePaneAtom.insertRestoredPane(paneWithCurrentTopologyFacets(pane))
        }
        workspaceTabShellAtom.insertTabShell(
            TabShell(id: snapshot.tab.id, name: snapshot.tab.name, colorHex: snapshot.tab.colorHex),
            at: snapshot.tabIndex
        )
        workspaceTabArrangementAtom.insertState(
            Self.arrangementState(from: snapshot.tab),
            at: snapshot.tabIndex
        )
        for pane in snapshot.panes {
            workspacePaneAtom.setResidency(pane.residency, for: pane.id)
        }
        workspaceTabShellAtom.setActiveTab(snapshot.tab.id)
    }

    @discardableResult
    package func restoreFromPaneSnapshot(_ snapshot: PaneCloseSnapshot) -> RestorePaneResult {
        _ = workspacePaneAtom.insertRestoredPane(paneWithCurrentTopologyFacets(snapshot.pane))
        for child in snapshot.drawerChildPanes {
            _ = workspacePaneAtom.insertRestoredPane(paneWithCurrentTopologyFacets(child))
        }

        if snapshot.pane.isDrawerChild {
            if let parentId = snapshot.anchorPaneId {
                guard workspacePaneAtom.restoreDrawerPane(paneWithCurrentTopologyFacets(snapshot.pane), to: parentId)
                else {
                    _ = workspacePaneAtom.deletePaneAndOwnedDrawerChildren(snapshot.pane.id)
                    return .failedMissingDrawerParent(parentId)
                }
                return .restored
            }
            _ = workspacePaneAtom.deletePaneAndOwnedDrawerChildren(snapshot.pane.id)
            return .failedMissingDrawerParent(nil)
        } else if let anchor = snapshot.anchorPaneId {
            guard
                workspaceTabArrangementAtom.insertPane(
                    snapshot.pane.id,
                    inTab: snapshot.tabId,
                    at: anchor,
                    direction: snapshot.direction,
                    position: .after,
                    sizingMode: .halveTarget
                )
            else {
                _ = workspacePaneAtom.deletePaneAndOwnedDrawerChildren(snapshot.pane.id)
                return .failedLayoutInsertion(tabId: snapshot.tabId, anchorPaneId: anchor)
            }
            workspaceTabArrangementAtom.setActivePane(snapshot.pane.id, inTab: snapshot.tabId)
            if let drawerId = snapshot.pane.drawer?.drawerId, !snapshot.drawerChildPanes.isEmpty {
                workspaceTabArrangementAtom.restoreDrawerPaneViews(
                    drawerId: drawerId,
                    parentPaneId: snapshot.pane.id,
                    drawerPaneIds: snapshot.drawerChildPanes.map(\.id),
                    drawerViewsByArrangementId: snapshot.drawerViewsByArrangementId,
                    inTab: snapshot.tabId
                )
            }
            return .restored
        }
        _ = workspacePaneAtom.deletePaneAndOwnedDrawerChildren(snapshot.pane.id)
        return .failedLayoutInsertion(tabId: snapshot.tabId, anchorPaneId: snapshot.anchorPaneId)
    }

    private func paneWithCurrentTopologyFacets(_ pane: Pane) -> Pane {
        let facets = pane.metadata.facets
        guard facets.repoId != nil || facets.worktreeId != nil else { return pane }
        guard repositoryTopologyAtom.validatedAssociation(repoId: facets.repoId, worktreeId: facets.worktreeId) == nil
        else {
            return pane
        }
        var restored = pane
        restored.metadata.updateFacets(PaneContextFacets(cwd: facets.cwd))
        return restored
    }

    private static func arrangementState(from tab: Tab) -> TabArrangementState {
        TabArrangementState(
            tabId: tab.id,
            allPaneIds: tab.allPaneIds,
            arrangements: tab.arrangements,
            activeArrangementId: tab.activeArrangementId
        )
    }

    private func removeEmptyTabs() {
        let emptyTabIds = workspaceTabArrangementAtom.arrangementStates.compactMap { state -> UUID? in
            !TabArrangementRepairRules.hasLivePaneReferences(in: state.arrangements) ? state.tabId : nil
        }

        for tabId in emptyTabIds {
            workspaceTabShellAtom.removeTabShell(tabId)
            workspaceTabArrangementAtom.removeState(tabId)
        }
    }
}
