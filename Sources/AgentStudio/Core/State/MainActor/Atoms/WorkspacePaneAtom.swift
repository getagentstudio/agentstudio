import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let workspacePaneLogger = Logger(subsystem: "com.agentstudio", category: "WorkspacePaneAtom")

package enum PaneCWDContextUpdateResult: Equatable {
    case applied
    case unchanged
    case deferredUncertain
    case staleRevision
    case paneMissing
}

package struct PaneAssociationRevision: Equatable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package enum PaneAssociationResolution: Equatable, Sendable {
    case matched(repoId: UUID, worktreeId: UUID)
    case confidentNoMatch
    case uncertain
}

@MainActor
@Observable
package final class WorkspacePaneAtom {
    package let graphAtom: WorkspacePaneGraphAtom
    let drawerCursorAtom: WorkspaceDrawerCursorAtom
    private let repositoryTopologyAtom: RepositoryTopologyAtom?
    private let repoEnrichmentCacheAtom: RepoEnrichmentCacheAtom?
    @ObservationIgnored private var associationOutcomeRecorder: ((PaneAssociationOutcome) -> Void)?

    package init(
        graphAtom: WorkspacePaneGraphAtom = WorkspacePaneGraphAtom(),
        drawerCursorAtom: WorkspaceDrawerCursorAtom = WorkspaceDrawerCursorAtom(),
        repositoryTopologyAtom: RepositoryTopologyAtom? = nil,
        repoEnrichmentCacheAtom: RepoEnrichmentCacheAtom? = nil
    ) {
        self.graphAtom = graphAtom
        self.drawerCursorAtom = drawerCursorAtom
        self.repositoryTopologyAtom = repositoryTopologyAtom
        self.repoEnrichmentCacheAtom = repoEnrichmentCacheAtom
    }

    private var derived: WorkspacePaneDerived {
        WorkspacePaneDerived(
            graphAtom: graphAtom,
            drawerCursorAtom: drawerCursorAtom,
            repositoryTopologyAtom: repositoryTopologyAtom,
            repoEnrichmentCacheAtom: repoEnrichmentCacheAtom
        )
    }

    package func setAssociationOutcomeRecorder(
        _ recorder: ((PaneAssociationOutcome) -> Void)?
    ) {
        associationOutcomeRecorder = recorder
    }

    package func pane(_ id: UUID) -> Pane? {
        guard let pane = derived.pane(id) else {
            workspacePaneLogger.warning("pane(\(id)): not found in store")
            return nil
        }
        return pane
    }

    package func paneSnapshot() -> [UUID: Pane] {
        derived.paneSnapshot()
    }

    package func panes(for worktreeId: UUID) -> [Pane] {
        paneSnapshot().values.filter { $0.worktreeId == worktreeId }
    }

    package func activeResidencyPaneIds(in orderedPaneIds: [UUID]) -> [UUID] {
        derived.activeResidencyPaneIds(in: orderedPaneIds)
    }

    package func activeResidencyPaneId(
        preferred preferredPaneId: UUID?,
        in orderedPaneIds: [UUID]
    ) -> UUID? {
        derived.activeResidencyPaneId(
            preferred: preferredPaneId,
            in: orderedPaneIds
        )
    }

    package func addPane(_ pane: Pane) {
        var admittedPane = pane
        admittedPane.metadata.updateFacets(
            admittedCreationFacets(
                pane.metadata.facets,
                fallbackCWD: pane.metadata.launchDirectory
            )
        )
        graphAtom.addPane(admittedPane)
        drawerCursorAtom.prune(validDrawerIds: graphAtom.drawerIds)
    }

    package func paneCount(for worktreeId: UUID) -> Int {
        derived.panes(for: worktreeId).count
    }

    package func isWorktreeActive(_ worktreeId: UUID) -> Bool {
        paneSnapshot().values.contains { $0.worktreeId == worktreeId && $0.residency == .active }
    }

    package func orphanedPanes(excluding layoutPaneIds: Set<UUID>) -> [Pane] {
        paneSnapshot().values.filter {
            guard !layoutPaneIds.contains($0.id) else { return false }
            guard !$0.isDrawerChild else { return false }
            return $0.residency == .backgrounded || $0.residency.isOrphaned
        }
    }

    @discardableResult
    package func createPane(
        launchDirectory: URL? = nil,
        title: String = "Terminal",
        provider: SessionProvider = .zmx,
        lifetime: SessionLifetime = .persistent,
        zmxSessionID: ZmxSessionID,
        residency: SessionResidency = .active,
        facets: PaneContextFacets = .empty
    ) -> Pane {
        let admittedFacets = admittedCreationFacets(facets, fallbackCWD: launchDirectory)
        let state = graphAtom.createPane(
            launchDirectory: launchDirectory,
            title: title,
            provider: provider,
            lifetime: lifetime,
            zmxSessionID: zmxSessionID,
            residency: residency,
            facets: admittedFacets
        )
        return pane(state.id)!
    }

    @discardableResult
    package func createPane(
        content: PaneContent,
        metadata: PaneMetadata,
        residency: SessionResidency = .active
    ) -> Pane? {
        var admittedMetadata = metadata
        admittedMetadata.updateFacets(
            admittedCreationFacets(metadata.facets, fallbackCWD: metadata.launchDirectory)
        )
        guard let state = graphAtom.createPane(content: content, metadata: admittedMetadata, residency: residency)
        else {
            return nil
        }
        return pane(state.id)
    }

    @discardableResult
    package func insertRestoredPane(_ pane: Pane) -> Bool {
        let didInsert = graphAtom.insertRestoredPane(pane)
        if didInsert {
            drawerCursorAtom.prune(validDrawerIds: graphAtom.drawerIds)
        }
        return didInsert
    }

    func insertCommittedTerminalPane(
        _ pane: Pane,
        associationOutcome: PaneAssociationOutcome,
        expandsDrawer: Bool = true
    ) {
        precondition(graphAtom.paneState(pane.id) == nil, "Committed new pane must have a fresh identity")
        if let parentID = pane.parentPaneId {
            precondition(
                restoreDrawerPane(pane, to: parentID, expandsDrawer: expandsDrawer),
                "Committed drawer parent must remain available")
        } else {
            precondition(insertRestoredPane(pane), "Committed new pane must publish")
        }
        associationOutcomeRecorder?(associationOutcome)
    }

    @discardableResult
    func deletePaneAndOwnedDrawerChildren(_ paneId: UUID) -> Bool {
        let didDelete = graphAtom.deletePaneAndOwnedDrawerChildren(paneId)
        if didDelete {
            drawerCursorAtom.prune(validDrawerIds: graphAtom.drawerIds)
        }
        return didDelete
    }

    package func updatePaneTitle(_ paneId: UUID, title: String) {
        graphAtom.updatePaneTitle(paneId, title: title)
    }

    func renamePane(_ paneId: UUID, title: String) {
        updatePaneTitle(paneId, title: title)
    }

    package func updatePaneCWD(_ paneId: UUID, cwd: URL?) {
        graphAtom.updatePaneCWD(paneId, cwd: cwd)
    }

    package func updatePaneNote(_ paneId: UUID, note: String?) {
        graphAtom.updatePaneNote(paneId, note: note)
    }

    package func updatePanePinned(_ paneId: UUID, isPinned: Bool) {
        graphAtom.updatePanePinned(paneId, isPinned: isPinned)
    }

    package func updatePaneCWDAndResolvedContext(
        _ paneId: UUID,
        cwd: URL?,
        resolvedContext: (repo: Repo, worktree: Worktree)?
    ) -> PaneCWDContextUpdateResult {
        guard let revision = graphAtom.reservePaneAssociationRevision(paneId) else {
            return .paneMissing
        }
        let resolution =
            resolvedContext.map {
                PaneAssociationResolution.matched(repoId: $0.repo.id, worktreeId: $0.worktree.id)
            } ?? .confidentNoMatch
        return graphAtom.applyPaneAssociationUpdate(
            paneId,
            cwd: cwd,
            resolution: resolution,
            revision: revision
        )
    }

    package func updatePaneWebviewState(_ paneId: UUID, state: WebviewState) {
        graphAtom.updatePaneWebviewState(paneId, state: state)
    }

    package func syncPaneWebviewState(_ paneId: UUID, state: WebviewState) {
        graphAtom.syncPaneWebviewState(paneId, state: state)
    }

    @discardableResult
    package func updateBridgePaneState(
        _ paneId: UUID,
        state: BridgePaneState
    ) -> BridgePaneStateMutationResult {
        graphAtom.updateBridgePaneState(paneId, state: state)
    }

    @discardableResult
    package func setInitialBridgeContributionTargetIfAbsent(
        _ paneId: UUID,
        target: WorkspaceReviewContributionTarget
    ) -> BridgePaneStateMutationResult {
        graphAtom.setInitialBridgeContributionTargetIfAbsent(paneId, target: target)
    }

    @discardableResult
    package func setBridgeContributionTarget(
        _ paneId: UUID,
        target: WorkspaceReviewContributionTarget
    ) -> BridgePaneStateMutationResult {
        graphAtom.setBridgeContributionTarget(paneId, target: target)
    }

    package func setResidency(_ residency: SessionResidency, for paneId: UUID) {
        graphAtom.setResidency(residency, for: paneId)
    }

    package func purgeOrphanedPane(_ paneId: UUID) {
        guard let pane = pane(paneId), pane.residency == .backgrounded || pane.residency.isOrphaned else {
            graphAtom.purgeOrphanedPane(paneId)
            return
        }
        if pane.drawer != nil {
            _ = graphAtom.deletePaneAndOwnedDrawerChildren(paneId)
        } else {
            graphAtom.purgeOrphanedPane(paneId)
        }
        drawerCursorAtom.prune(validDrawerIds: graphAtom.drawerIds)
    }

    @discardableResult
    package func addDrawerPane(
        to parentPaneId: UUID,
        parentFallbackCWD: URL?,
        zmxSessionID: ZmxSessionID
    ) -> Pane? {
        guard let metadata = inheritedDrawerMetadata(from: parentPaneId, parentFallbackCWD: parentFallbackCWD) else {
            workspacePaneLogger.warning("addDrawerPane: parent pane \(parentPaneId) not found")
            return nil
        }
        return addDrawerPane(
            to: parentPaneId,
            content: .terminal(
                TerminalState(
                    provider: .zmx,
                    lifetime: .persistent,
                    zmxSessionID: zmxSessionID
                )
            ),
            metadata: metadata
        )
    }

    @discardableResult
    package func addDrawerPane(
        to parentPaneId: UUID,
        content: PaneContent,
        metadata: PaneMetadata,
        childPaneId: UUID? = nil,
        expandsDrawer: Bool = true
    ) -> Pane? {
        var admittedMetadata = metadata
        admittedMetadata.updateFacets(
            admittedCreationFacets(metadata.facets, fallbackCWD: metadata.launchDirectory)
        )
        guard
            let drawerPane = graphAtom.addDrawerPane(
                to: parentPaneId,
                content: content,
                metadata: admittedMetadata,
                childPaneId: childPaneId
            )
        else {
            return nil
        }
        if expandsDrawer, let drawerId = graphAtom.paneState(parentPaneId)?.drawer?.drawerId {
            drawerCursorAtom.expandDrawer(drawerId: drawerId)
        }
        return pane(drawerPane.id)
    }

    @discardableResult
    package func insertDrawerPane(
        in parentPaneId: UUID,
        at targetDrawerPaneId: UUID,
        direction _: SplitNewDirection,
        sizingMode _: DropSizingMode,
        parentFallbackCWD: URL?,
        zmxSessionID: ZmxSessionID
    ) -> Pane? {
        guard let metadata = inheritedDrawerMetadata(from: parentPaneId, parentFallbackCWD: parentFallbackCWD) else {
            workspacePaneLogger.warning("insertDrawerPane: parent pane \(parentPaneId) not found")
            return nil
        }
        return insertDrawerPane(
            in: parentPaneId,
            at: targetDrawerPaneId,
            direction: .right,
            sizingMode: .halveTarget,
            content: .terminal(
                TerminalState(
                    provider: .zmx,
                    lifetime: .persistent,
                    zmxSessionID: zmxSessionID
                )
            ),
            metadata: metadata
        )
    }

    @discardableResult
    package func insertDrawerPane(
        in parentPaneId: UUID,
        at targetDrawerPaneId: UUID,
        direction _: SplitNewDirection,
        sizingMode _: DropSizingMode,
        content: PaneContent,
        metadata: PaneMetadata
    ) -> Pane? {
        var admittedMetadata = metadata
        admittedMetadata.updateFacets(
            admittedCreationFacets(metadata.facets, fallbackCWD: metadata.launchDirectory)
        )
        guard
            let drawerPane = graphAtom.insertDrawerPane(
                in: parentPaneId,
                at: targetDrawerPaneId,
                content: content,
                metadata: admittedMetadata
            )
        else { return nil }
        if let drawerId = graphAtom.paneState(parentPaneId)?.drawer?.drawerId {
            drawerCursorAtom.expandDrawer(drawerId: drawerId)
        }
        return pane(drawerPane.id)
    }

    package func removeDrawerPane(_ drawerPaneId: UUID, from parentPaneId: UUID) {
        graphAtom.removeDrawerPane(drawerPaneId, from: parentPaneId)
        drawerCursorAtom.prune(validDrawerIds: graphAtom.drawerIds)
    }

    @discardableResult
    package func detachDrawerPane(_ drawerPaneId: UUID, from parentPaneId: UUID) -> Pane? {
        guard let detached = graphAtom.detachDrawerPane(drawerPaneId, from: parentPaneId) else { return nil }
        drawerCursorAtom.prune(validDrawerIds: graphAtom.drawerIds)
        return pane(detached.id)
    }

    package func toggleDrawer(for paneId: UUID) {
        guard let drawerId = graphAtom.paneState(paneId)?.drawer?.drawerId else {
            workspacePaneLogger.warning("toggleDrawer: pane \(paneId) has no drawer")
            return
        }
        drawerCursorAtom.toggleDrawer(drawerId: drawerId)
    }

    package func collapseAllDrawers() {
        drawerCursorAtom.collapseAllDrawers()
    }

    package func isDrawerExpanded(for parentPaneID: UUID) -> Bool {
        guard let drawerID = graphAtom.paneStructuralFacts(parentPaneID)?.ownedDrawerID else { return false }
        return drawerCursorAtom.isExpanded(drawerId: drawerID)
    }

    package var expandedDrawerID: UUID? {
        drawerCursorAtom.expandedDrawerId
    }

    package func drawerPresentationPreference(forOwner ownerPaneId: UUID) -> DrawerPresentationPreference {
        drawerCursorAtom.presentationPreference(forOwner: ownerPaneId)
    }

    package func setDrawerNormalHeightRatio(_ ratio: Double, forOwner ownerPaneId: UUID) {
        let current = drawerCursorAtom.presentationPreference(forOwner: ownerPaneId)
        drawerCursorAtom.setPresentationPreference(current.replacingNormalHeightRatio(ratio), forOwner: ownerPaneId)
    }

    package func setDrawerZoomSide(_ side: DrawerZoomSide, forOwner ownerPaneId: UUID) {
        let current = drawerCursorAtom.presentationPreference(forOwner: ownerPaneId)
        drawerCursorAtom.setPresentationPreference(current.replacingZoomSide(side), forOwner: ownerPaneId)
    }

    func snapshotPanes(with ids: [UUID]) -> [Pane] {
        ids.compactMap { pane($0) }
    }

    @discardableResult
    package func restoreDrawerPane(_ drawerPane: Pane, to parentPaneId: UUID, expandsDrawer: Bool = true) -> Bool {
        let didRestore = graphAtom.restoreDrawerPane(drawerPane, to: parentPaneId)
        if didRestore {
            drawerCursorAtom.prune(validDrawerIds: graphAtom.drawerIds)
        }
        if didRestore, expandsDrawer, let drawerId = graphAtom.paneState(parentPaneId)?.drawer?.drawerId {
            drawerCursorAtom.expandDrawer(drawerId: drawerId)
        }
        return didRestore
    }

    private func inheritedDrawerMetadata(from parentPaneId: UUID, parentFallbackCWD: URL?) -> PaneMetadata? {
        guard
            let parentPane = pane(parentPaneId),
            let parentPaneState = graphAtom.paneState(parentPaneId)
        else { return nil }

        let durableFacets = parentPaneState.durableContextFacets

        let inheritedCWD =
            durableFacets.cwd
            ?? parentPane.metadata.launchDirectory
            ?? parentFallbackCWD

        let inheritedFacets = durableFacets.fillingNilFields(
            from: PaneContextFacets(cwd: inheritedCWD)
        )

        return PaneMetadata(
            launchDirectory: inheritedCWD,
            title: "Drawer",
            facets: inheritedFacets
        )
    }

    private func admittedCreationFacets(
        _ proposedFacets: PaneContextFacets,
        fallbackCWD: URL?
    ) -> PaneContextFacets {
        var admittedFacets = proposedFacets
        let associationIsComplete = proposedFacets.repoId != nil && proposedFacets.worktreeId != nil
        guard let repositoryTopologyAtom else {
            if !associationIsComplete {
                admittedFacets.repoId = nil
                admittedFacets.worktreeId = nil
            }
            associationOutcomeRecorder?(associationIsComplete ? .stampedKnown : .freeNil)
            return admittedFacets
        }

        if let repoId = proposedFacets.repoId,
            let worktreeId = proposedFacets.worktreeId,
            repositoryTopologyAtom.repo(repoId) != nil,
            repositoryTopologyAtom.worktree(worktreeId)?.repoId == repoId
        {
            associationOutcomeRecorder?(.stampedKnown)
            return admittedFacets
        }

        let resolvedContext = repositoryTopologyAtom.repoAndWorktree(
            containing: proposedFacets.cwd ?? fallbackCWD
        )
        admittedFacets.repoId = resolvedContext?.repo.id
        admittedFacets.worktreeId = resolvedContext?.worktree.id
        associationOutcomeRecorder?(resolvedContext == nil ? .freeNil : .resolvedChanged)
        return admittedFacets
    }

}
