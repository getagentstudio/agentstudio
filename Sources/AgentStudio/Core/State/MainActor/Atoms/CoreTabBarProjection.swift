import Foundation

package struct CoreTabBarProjectionRequest: Sendable {
    fileprivate let tabShells: [TabShell]
    fileprivate let activeTabId: UUID?
    fileprivate let tabGraphStates: [TabGraphState]
    fileprivate let activeArrangementIdsByTabId: [UUID: UUID]
    fileprivate let paneCursorsByArrangementId: [UUID: ArrangementPaneCursorState]
    fileprivate let drawerCursorsByKey: [ArrangementDrawerCursorKey: ArrangementDrawerCursorState]
    fileprivate let paneStates: [UUID: PaneGraphState]
    fileprivate let expandedDrawerId: UUID?
    fileprivate let topologySnapshot: RepositoryTopologyReadSnapshot
    fileprivate let repoEnrichmentSnapshot: [UUID: RepoEnrichment]
    fileprivate let worktreeEnrichmentSnapshot: [UUID: WorktreeEnrichment]
    fileprivate let zoomPresentationsByTabId: [UUID: ZoomPresentation]

    @MainActor
    package static func capture(
        store: WorkspaceStore,
        repoCache: RepoCacheAtom
    ) -> Self {
        Self(
            tabShells: store.tabShellAtom.tabShells,
            activeTabId: store.tabCursorAtom.activeTabId,
            tabGraphStates: store.tabGraphAtom.tabStates,
            activeArrangementIdsByTabId: store.arrangementCursorAtom.activeArrangementIdsByTabId,
            paneCursorsByArrangementId: store.arrangementCursorAtom.paneCursorsByArrangementId,
            drawerCursorsByKey: store.arrangementCursorAtom.drawerCursorsByKey,
            paneStates: store.paneGraphAtom.paneStateSnapshot(),
            expandedDrawerId: store.drawerCursorAtom.expandedDrawerId,
            topologySnapshot: store.repositoryTopologyAtom.captureReadSnapshot(),
            repoEnrichmentSnapshot: repoCache.repoEnrichmentSnapshot(),
            worktreeEnrichmentSnapshot: repoCache.worktreeEnrichmentSnapshot(),
            zoomPresentationsByTabId: store.panePresentationAtom.zoomPresentationsByTabId
        )
    }

    @MainActor
    package static func capture(
        tabId: UUID,
        store: WorkspaceStore,
        repoCache: RepoCacheAtom
    ) -> Self? {
        guard let tabShell = store.tabShellAtom.tabShell(tabId),
            let tabGraphState = store.tabGraphAtom.tabState(tabId)
        else {
            return nil
        }

        let arrangementIds = Set(tabGraphState.arrangements.map(\.id))
        let paneCursorsByArrangementId = Dictionary(
            uniqueKeysWithValues: arrangementIds.compactMap { arrangementId in
                store.arrangementCursorAtom.activePaneId(forArrangement: arrangementId).map {
                    (arrangementId, ArrangementPaneCursorState(activePaneId: $0))
                }
            }
        )
        var drawerCursorsByKey: [ArrangementDrawerCursorKey: ArrangementDrawerCursorState] = [:]
        for arrangement in tabGraphState.arrangements {
            for drawerId in arrangement.drawerViews.keys {
                guard
                    let activeChildId = store.arrangementCursorAtom.activeChildId(
                        forArrangement: arrangement.id,
                        drawerId: drawerId
                    )
                else { continue }
                drawerCursorsByKey[
                    ArrangementDrawerCursorKey(
                        arrangementId: arrangement.id,
                        drawerId: drawerId
                    )
                ] = ArrangementDrawerCursorState(activeChildId: activeChildId)
            }
        }
        let paneStates = Dictionary(
            uniqueKeysWithValues: tabGraphState.allPaneIds.compactMap { paneId in
                store.paneGraphAtom.paneState(paneId).map { (paneId, $0) }
            }
        )
        let topologySnapshot = store.repositoryTopologyAtom.captureReadSnapshot()
        let enrichmentSnapshots = captureEnrichmentSnapshots(
            paneStates: paneStates,
            topologySnapshot: topologySnapshot,
            repoCache: repoCache
        )

        return Self(
            tabShells: [tabShell],
            activeTabId: tabId,
            tabGraphStates: [tabGraphState],
            activeArrangementIdsByTabId: store.arrangementCursorAtom.activeArrangementId(forTab: tabId)
                .map { [tabId: $0] } ?? [:],
            paneCursorsByArrangementId: paneCursorsByArrangementId,
            drawerCursorsByKey: drawerCursorsByKey,
            paneStates: paneStates,
            expandedDrawerId: store.drawerCursorAtom.expandedDrawerId,
            topologySnapshot: topologySnapshot,
            repoEnrichmentSnapshot: enrichmentSnapshots.reposById,
            worktreeEnrichmentSnapshot: enrichmentSnapshots.worktreesById,
            zoomPresentationsByTabId: store.panePresentationAtom.zoomPresentation(forTab: tabId)
                .map { [tabId: $0] } ?? [:]
        )
    }

    @MainActor
    private static func captureEnrichmentSnapshots(
        paneStates: [UUID: PaneGraphState],
        topologySnapshot: RepositoryTopologyReadSnapshot,
        repoCache: RepoCacheAtom
    ) -> (reposById: [UUID: RepoEnrichment], worktreesById: [UUID: WorktreeEnrichment]) {
        var repoIds: Set<UUID> = []
        var worktreeIds: Set<UUID> = []

        for paneState in paneStates.values {
            guard
                let resolvedContext = topologySnapshot.validatedAssociation(
                    repoId: paneState.metadata.facets.repoId,
                    worktreeId: paneState.metadata.facets.worktreeId
                )
            else { continue }
            repoIds.insert(resolvedContext.repo.id)
            worktreeIds.insert(resolvedContext.worktree.id)
        }

        let reposById = Dictionary(
            uniqueKeysWithValues: repoIds.compactMap { repoId in
                repoCache.repoEnrichment(for: repoId).map { (repoId, $0) }
            }
        )
        let worktreesById = Dictionary(
            uniqueKeysWithValues: worktreeIds.compactMap { worktreeId in
                repoCache.worktreeEnrichment(for: worktreeId).map { (worktreeId, $0) }
            }
        )
        return (reposById, worktreesById)
    }

    package var paneIds: [UUID] {
        tabGraphStates.first?.allPaneIds ?? []
    }
}

package struct CoreTabBarProjectionItem: Equatable, Sendable, Identifiable {
    package let id: UUID
    package let title: String
    package let isSplit: Bool
    package let displayTitle: String
    package let activeArrangementName: String
    package let activeArrangementBadgeNumber: Int?
    package let arrangementCount: Int
    package let colorHex: String?
    package let activePaneCount: Int
    package let paneIds: [UUID]
    package let zoomMode: ArrangementPanelZoomMode?
    package let zoomSourcePaneOrdinal: Int?
    package let arrangements: [ArrangementInfo]
    package let minimizedCount: Int
}

package struct CoreTabBarProjection: Equatable, Sendable {
    package let items: [CoreTabBarProjectionItem]
    package let activeTabId: UUID?
}

package enum CoreTabBarProjector {
    package static func project(
        _ request: CoreTabBarProjectionRequest,
        cancellationCheck: () throws(CancellationError) -> Void = checkCancellation
    ) throws(CancellationError) -> CoreTabBarProjection {
        let panesById = try makePanesById(
            request: request,
            cancellationCheck: cancellationCheck
        )
        let graphStatesByTabId = try makeGraphStatesByTabId(
            request.tabGraphStates,
            cancellationCheck: cancellationCheck
        )

        var items: [CoreTabBarProjectionItem] = []
        items.reserveCapacity(request.tabShells.count)
        for shell in request.tabShells {
            try cancellationCheck()
            guard let graphState = graphStatesByTabId[shell.id] else { continue }
            let arrangementState = try arrangementState(
                graphState: graphState,
                request: request,
                cancellationCheck: cancellationCheck
            )
            let tab = WorkspaceTabLayoutDerived.assembleTab(
                shell: shell,
                arrangementState: arrangementState
            )
            items.append(
                try item(
                    for: tab,
                    request: request,
                    panesById: panesById,
                    cancellationCheck: cancellationCheck
                )
            )
        }

        try cancellationCheck()
        return CoreTabBarProjection(
            items: items,
            activeTabId: request.activeTabId ?? items.last?.id
        )
    }

    private static func checkCancellation() throws(CancellationError) {
        guard Task.isCancelled else { return }
        throw CancellationError()
    }

    private static func makeGraphStatesByTabId(
        _ graphStates: [TabGraphState],
        cancellationCheck: () throws(CancellationError) -> Void
    ) throws(CancellationError) -> [UUID: TabGraphState] {
        var graphStatesByTabId: [UUID: TabGraphState] = [:]
        graphStatesByTabId.reserveCapacity(graphStates.count)
        for graphState in graphStates {
            try cancellationCheck()
            graphStatesByTabId[graphState.tabId] = graphState
        }
        return graphStatesByTabId
    }

    private static func makePanesById(
        request: CoreTabBarProjectionRequest,
        cancellationCheck: () throws(CancellationError) -> Void
    ) throws(CancellationError) -> [UUID: Pane] {
        var panesById: [UUID: Pane] = [:]
        panesById.reserveCapacity(request.paneStates.count)
        for (paneId, paneState) in request.paneStates {
            try cancellationCheck()
            var pane = paneState.pane(
                isDrawerExpanded: paneState.drawer?.drawerId == request.expandedDrawerId
            )
            let resolvedContext = request.topologySnapshot.validatedAssociation(
                repoId: pane.metadata.facets.repoId,
                worktreeId: pane.metadata.facets.worktreeId
            )
            pane.metadata.updateFacets(
                WorkspacePaneDerived.displayFacets(
                    for: pane.metadata.facets,
                    resolvedContext: resolvedContext,
                    repoEnrichment: resolvedContext.flatMap {
                        request.repoEnrichmentSnapshot[$0.repo.id]
                    }
                )
            )
            panesById[paneId] = pane
        }
        return panesById
    }

    private static func arrangementState(
        graphState: TabGraphState,
        request: CoreTabBarProjectionRequest,
        cancellationCheck: () throws(CancellationError) -> Void
    ) throws(CancellationError) -> TabArrangementState {
        var arrangements: [PaneArrangement] = []
        arrangements.reserveCapacity(graphState.arrangements.count)
        for arrangementGraphState in graphState.arrangements {
            try cancellationCheck()
            var drawerViews: [UUID: DrawerView] = [:]
            drawerViews.reserveCapacity(arrangementGraphState.drawerViews.count)
            for (drawerId, drawerGraphState) in arrangementGraphState.drawerViews {
                try cancellationCheck()
                let cursorKey = ArrangementDrawerCursorKey(
                    arrangementId: arrangementGraphState.id,
                    drawerId: drawerId
                )
                var drawerView = DrawerView(
                    layout: drawerGraphState.layout,
                    activeChildId: request.drawerCursorsByKey[cursorKey]?.activeChildId,
                    minimizedPaneIds: drawerGraphState.minimizedPaneIds
                )
                drawerView.activeChildId = request.drawerCursorsByKey[cursorKey]?.activeChildId
                drawerViews[drawerId] = drawerView
            }

            var arrangement = PaneArrangement(
                id: arrangementGraphState.id,
                name: arrangementGraphState.name,
                isDefault: arrangementGraphState.isDefault,
                layout: arrangementGraphState.layout,
                minimizedPaneIds: arrangementGraphState.minimizedPaneIds,
                activePaneId: request.paneCursorsByArrangementId[arrangementGraphState.id]?.activePaneId,
                drawerViews: drawerViews
            )
            arrangement.activePaneId = request.paneCursorsByArrangementId[arrangementGraphState.id]?.activePaneId
            arrangements.append(arrangement)
        }

        let activeArrangementId =
            request.activeArrangementIdsByTabId[graphState.tabId]
            ?? arrangements.first(where: \.isDefault)?.id
            ?? arrangements.first?.id
            ?? graphState.tabId
        return TabArrangementState(
            tabId: graphState.tabId,
            allPaneIds: graphState.allPaneIds,
            arrangements: arrangements,
            activeArrangementId: activeArrangementId
        )
    }

    private static func item(
        for tab: Tab,
        request: CoreTabBarProjectionRequest,
        panesById: [UUID: Pane],
        cancellationCheck: () throws(CancellationError) -> Void
    ) throws(CancellationError) -> CoreTabBarProjectionItem {
        let displayTitle = try TabDisplayDerived.displayTitle(
            for: tab,
            cancellationCheck: cancellationCheck
        ) { paneId in
            guard let pane = panesById[paneId] else { return nil }
            let worktree = pane.worktreeId.flatMap { request.topologySnapshot.worktree($0) }
            return TabDisplayDerived.title(
                for: pane,
                worktree: worktree,
                enrichment: worktree.flatMap { request.worktreeEnrichmentSnapshot[$0.id] }
            )
        }

        var arrangementInfos: [ArrangementInfo] = []
        arrangementInfos.reserveCapacity(tab.arrangements.count)
        for arrangement in tab.arrangements {
            try cancellationCheck()
            arrangementInfos.append(
                ArrangementDerived.arrangementInfo(
                    for: arrangement,
                    activeArrangementId: tab.activeArrangementId
                )
            )
        }

        let zoomPresentation = request.zoomPresentationsByTabId[tab.id]
        let zoomMode: ArrangementPanelZoomMode?
        if let zoomPresentation {
            let sourceIdentity: ArrangementPanelZoomSourceIdentity?
            if let sourcePane = panesById[zoomPresentation.sourcePaneId] {
                let resolvedContext = try resolvedWorkspaceContext(
                    for: sourcePane,
                    topologySnapshot: request.topologySnapshot,
                    cancellationCheck: cancellationCheck
                ).context
                sourceIdentity = ArrangementDerived.zoomSourceIdentity(
                    for: sourcePane,
                    workspaceContext: ArrangementDerived.zoomSourceWorkspaceContext(
                        resolvedContext: resolvedContext,
                        worktreeEnrichment: resolvedContext.flatMap {
                            request.worktreeEnrichmentSnapshot[$0.worktree.id]
                        }
                    )
                )
            } else {
                sourceIdentity = nil
            }
            zoomMode = ArrangementDerived.zoomMode(
                presentation: zoomPresentation,
                sourceIdentity: sourceIdentity
            )
        } else {
            zoomMode = nil
        }
        return CoreTabBarProjectionItem(
            id: tab.id,
            title: displayTitle,
            isSplit: tab.isSplit,
            displayTitle: displayTitle,
            activeArrangementName: ArrangementDerived.activeArrangementDisplayName(for: tab.activeArrangement),
            activeArrangementBadgeNumber: zoomPresentation == nil
                ? ArrangementDerived.activeArrangementBadgeNumber(for: tab) : nil,
            arrangementCount: tab.arrangements.count,
            colorHex: tab.colorHex,
            activePaneCount: tab.activeArrangement.layout.panes.count,
            paneIds: tab.allPaneIds,
            zoomMode: zoomMode,
            zoomSourcePaneOrdinal: zoomPresentation.flatMap { presentation in
                PaneOrdinalMap(orderedPaneIds: tab.activeArrangement.layout.paneIds)
                    .ordinal(forPaneId: presentation.sourcePaneId)
            },
            arrangements: arrangementInfos,
            minimizedCount: tab.activeMinimizedPaneIds.count
        )
    }

    private static func resolvedWorkspaceContext(
        for pane: Pane,
        topologySnapshot: RepositoryTopologyReadSnapshot,
        cancellationCheck: () throws(CancellationError) -> Void
    ) throws(CancellationError) -> (
        context: (repo: Repo, worktree: Worktree)?,
        usesExplicitAssociation: Bool
    ) {
        let explicitRepoId = pane.repoId ?? pane.metadata.repoId
        let explicitWorktreeId = pane.worktreeId ?? pane.metadata.worktreeId
        try cancellationCheck()
        let context = topologySnapshot.validatedAssociation(
            repoId: explicitRepoId,
            worktreeId: explicitWorktreeId
        )
        return (context, context != nil)
    }
}
