import AgentStudioCore
import AppKit

@MainActor
extension WorkspaceSurfaceCoordinator {
    private static let defaultGitHubURL = URL(string: "https://github.com")!

    static func computeSwitchArrangementTransitions(
        previousVisiblePaneIds: Set<UUID>,
        previouslyMinimizedPaneIds: Set<UUID>,
        newVisiblePaneIds: Set<UUID>,
        newMinimizedPaneIds: Set<UUID>,
        retainedVisiblePaneIds: Set<UUID> = []
    ) -> WorkspaceSurfaceCoordinator.SwitchArrangementTransitions {
        let previouslyPresentedPaneIds =
            previousVisiblePaneIds
            .subtracting(previouslyMinimizedPaneIds)
            .union(retainedVisiblePaneIds)
        let newlyPresentedPaneIds =
            newVisiblePaneIds
            .subtracting(newMinimizedPaneIds)
            .union(retainedVisiblePaneIds)
        let hiddenPaneIds = previouslyPresentedPaneIds.subtracting(newlyPresentedPaneIds)
        let revealedPaneIds = newlyPresentedPaneIds.subtracting(previouslyPresentedPaneIds)
        return SwitchArrangementTransitions(
            hiddenPaneIds: hiddenPaneIds,
            paneIdsToReattach: revealedPaneIds
        )
    }

    /// Open a terminal for a worktree.
    @discardableResult
    func openTerminal(for worktree: Worktree, in repo: Repo) async throws -> Pane? {
        if let existingTab = store.tabLayoutAtom.tabs.first(where: { tab in
            tab.allPaneIds.contains { paneId in
                store.paneAtom.pane(paneId)?.worktreeId == worktree.id
            }
        }) {
            store.tabLayoutAtom.setActiveTab(existingTab.id)
            recordWorktreeOpened(worktree, in: repo)
            return nil
        }

        return try await createTerminalTab(for: worktree, in: repo)
    }

    /// Open a new terminal for a worktree, always creating a fresh pane+tab
    /// (never navigates to an existing one).
    @discardableResult
    func openNewTerminal(for worktree: Worktree, in repo: Repo) async throws -> Pane? {
        try await createTerminalTab(for: worktree, in: repo)
    }

    /// Open a worktree terminal as a split pane in the active tab.
    /// Falls back to opening a new tab when there is no active split target.
    @discardableResult
    func openWorktreeInPane(for worktree: Worktree, in repo: Repo) async throws -> Pane? {
        guard
            let activeTabId = store.tabLayoutAtom.activeTabId,
            let activeTab = store.tabLayoutAtom.tab(activeTabId),
            let targetPaneId = activeTab.activePaneId
        else {
            return try await openNewTerminal(for: worktree, in: repo)
        }

        guard activeTab.activeArrangement.layout.contains(targetPaneId) else { return nil }
        let pane = try await store.createTerminalPane(
            metadata: PaneMetadata(
                launchDirectory: worktree.path,
                title: worktree.name,
                facets: PaneContextFacets(
                    repoId: repo.id, repoName: repo.name, worktreeId: worktree.id,
                    worktreeName: worktree.name, cwd: worktree.path)),
            placement: .split(
                .init(
                    tabID: activeTabId, anchorID: targetPaneId, direction: .horizontal,
                    position: .after, sizingMode: .halveTarget)),
            nameForPane: { [self] in tabNameForPane($0) },
            willPublish: { [self] in prepareTerminalPaneSlot($0) })
        traceTerminalLayoutInsertedAndViewCreateStarted(pane)
        ensureTerminalPaneView(pane)
        recordWorktreeOpened(worktree, in: repo)

        Self.logger.info("Opened worktree '\(worktree.name)' in split pane")
        return pane
    }

    /// Open a new generic GitHub webview pane in a new tab.
    @discardableResult
    func openWebview(url: URL = defaultGitHubURL) -> Pane? {
        let state = WebviewState(url: url, showNavigation: true)
        let host = url.host() ?? "New Tab"
        guard
            let pane = store.paneAtom.createPane(
                content: .webview(state),
                metadata: PaneMetadata(title: host)
            )
        else {
            Self.logger.error("Webview pane admission failed")
            return nil
        }
        viewRegistry.ensureSlot(for: pane.id)

        guard createViewForContent(pane: pane) != nil else {
            Self.logger.error("Webview creation failed — rolling back pane \(pane.id)")
            store.mutationCoordinator.removePane(pane.id)
            // Safe immediate deletion: creation failed before the pane entered a rendered layout.
            viewRegistry.removeSlot(for: pane.id)
            return nil
        }

        let tab = Tab(paneId: pane.id, name: tabNameForPane(pane))
        store.tabLayoutAtom.appendTab(tab)
        store.tabLayoutAtom.setActiveTab(tab.id)

        Self.logger.info("Opened webview pane \(pane.id)")
        return pane
    }

    @discardableResult
    func openFloatingTerminal(launchDirectory: URL?, title: String?) async throws -> Pane? {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLaunchDirectory =
            launchDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let pane = try await store.createTerminalPane(
            metadata: PaneMetadata(
                launchDirectory: resolvedLaunchDirectory,
                title: (resolvedTitle?.isEmpty == false) ? resolvedTitle! : "Terminal",
                facets: PaneContextFacets(cwd: resolvedLaunchDirectory)),
            placement: .newTab,
            nameForPane: { [self] in tabNameForPane($0) },
            willPublish: { [self] in prepareTerminalPaneSlot($0) })
        traceTerminalLayoutInsertedAndViewCreateStarted(pane)
        ensureTerminalPaneView(pane)

        Self.logger.info("Opened floating terminal pane \(pane.id)")
        return pane
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Execute a resolved WorkspaceActionCommand.
    func execute(_ action: WorkspaceActionCommand) async throws {
        Self.logger.debug("Executing: \(String(describing: action))")
        let clock = ContinuousClock()
        let actionStart = clock.now
        traceTerminalCommandReceived(for: action)
        defer {
            performanceTraceRecorder?.recordDuration(
                .paneActionExecution,
                duration: actionStart.duration(to: clock.now),
                attributes: [
                    "agentstudio.performance.pane_action.name": .string(action.performanceTraceName),
                    "agentstudio.performance.pane_action.pane.count": .int(store.paneAtom.graphAtom.paneIDs.count),
                    "agentstudio.performance.pane_action.tab.count": .int(store.tabLayoutAtom.tabs.count),
                ]
            )
        }
        defer { clearUnclaimedTerminalStartupOperation() }

        switch action {
        case .openWorktree(let worktreeId):
            guard
                let worktree = store.repositoryTopologyAtom.worktree(worktreeId),
                let repo = store.repositoryTopologyAtom.repo(containing: worktreeId)
            else {
                Self.logger.warning("openWorktree: worktree \(worktreeId) not found")
                return
            }
            _ = try await openTerminal(for: worktree, in: repo)

        case .openNewTerminalInTab(let worktreeId, let launchDirectory, let title):
            guard
                let worktree = store.repositoryTopologyAtom.worktree(worktreeId),
                let repo = store.repositoryTopologyAtom.repo(containing: worktreeId)
            else {
                Self.logger.warning("openNewTerminalInTab: worktree \(worktreeId) not found")
                return
            }
            _ = try await createTerminalTab(for: worktree, in: repo, cwdOverride: launchDirectory, titleOverride: title)

        case .openWorktreeInPane(let worktreeId):
            guard
                let worktree = store.repositoryTopologyAtom.worktree(worktreeId),
                let repo = store.repositoryTopologyAtom.repo(containing: worktreeId)
            else {
                Self.logger.warning("openWorktreeInPane: worktree \(worktreeId) not found")
                return
            }
            _ = try await openWorktreeInPane(for: worktree, in: repo)

        case .openFloatingTerminal(let launchDirectory, let title):
            _ = try await openFloatingTerminal(launchDirectory: launchDirectory, title: title)

        case .removeRepo(let repoId):
            removeRepoHandler(repoId)

        case .setRepoPinned(let repoId, let isPinned):
            await awaitTopologyMutationAdmission()
            store.mutationCoordinator.setRepoPinned(repoId, isPinned: isPinned)

        case .setPanePinned(let paneId, let isPinned):
            store.mutationCoordinator.setPanePinned(paneId, isPinned: isPinned)

        case .selectTab(let tabId):
            store.tabLayoutAtom.setActiveTab(tabId)
            restoreViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)

        case .closeTab(let tabId):
            try await executeCloseTab(tabId)

        case .breakUpTab(let tabId):
            executeBreakUpTab(tabId)

        case .renameTab(let tabId, let name):
            store.tabLayoutAtom.renameTab(tabId, name: name)

        case .closePane(let tabId, let paneId):
            try await executeClosePane(tabId: tabId, paneId: paneId)

        case .extractPaneToTab(let tabId, let paneId):
            let capturedZoomCompanions = captureZoomCompanions(
                forSourcePanes: [paneId]
            )
            if store.panePresentationAtom.zoomPresentation(forTab: tabId)?.sourcePaneId == paneId {
                store.panePresentationAtom.cancelZoom(inTab: tabId)
            }
            guard
                let newTab = store.tabLayoutAtom.extractPane(
                    paneId,
                    fromTab: tabId,
                    drawerPayload: drawerMovePayload(forParentPaneId: paneId, inTab: tabId)
                )
            else {
                Self.logger.warning("extractPaneToTab: failed to extract pane \(paneId) from tab \(tabId)")
                break
            }
            reassociateZoomCompanionsWithCurrentTabs(capturedZoomCompanions)
            guard let pane = store.paneAtom.pane(paneId) else {
                Self.logger.warning("extractPaneToTab: extracted pane \(paneId) missing after tab extraction")
                break
            }
            store.tabLayoutAtom.renameTab(newTab.id, name: tabNameForPane(pane))

        case .insertPaneRequest(let request):
            try await executeInsertPane(
                source: request.source,
                targetTabId: request.targetTabId,
                targetPaneId: request.targetPaneId,
                direction: request.direction,
                sizingMode: request.sizingMode
            )

        case .resizePane(let tabId, let splitId, let ratio):
            store.tabLayoutAtom.resizePane(tabId: tabId, splitId: splitId, ratio: ratio)
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .resizeVisiblePanePair(let tabId, let leftPaneId, let rightPaneId, let ratio):
            let canonicalPaneIds = store.tabLayoutAtom.tab(tabId)?.activeArrangement.layout.paneIds ?? []
            let residencyExcludedPaneIds = Set(canonicalPaneIds).subtracting(
                store.paneAtom.activeResidencyPaneIds(in: canonicalPaneIds)
            )
            store.tabLayoutAtom.resizeVisiblePanePair(
                tabId: tabId,
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId,
                ratio: ratio,
                residencyExcludedPaneIds: residencyExcludedPaneIds
            )
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .equalizePanes(let tabId):
            store.tabLayoutAtom.equalizePanes(tabId: tabId)
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .moveTab(let tabId, let delta):
            store.tabLayoutAtom.moveTabByDelta(tabId: tabId, delta: delta)

        case .reorderTab(let tabId, let insertionIndex):
            store.tabLayoutAtom.reorderTab(tabId, insertionIndex: insertionIndex)
            store.tabLayoutAtom.setActiveTab(tabId)

        case .minimizePane(let tabId, let paneId):
            if store.tabLayoutAtom.minimizePane(paneId, inTab: tabId) {
                detachForViewSwitch(paneId: paneId)
            }
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .expandPane(let tabId, let paneId):
            store.tabLayoutAtom.expandPane(paneId, inTab: tabId)
            restoreVisiblePaneIfNeeded(paneId, forceWhenBoundsExist: true)
            if viewRegistry.terminalView(for: paneId) != nil {
                reattachForViewSwitch(paneId: paneId)
            }
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .resizePaneByDelta(let tabId, let paneId, let direction, let amount):
            store.tabLayoutAtom.resizePaneByDelta(tabId: tabId, paneId: paneId, direction: direction, amount: amount)

        case .mergeTab(let sourceTabId, let targetTabId, let targetPaneId, let direction):
            executeMergeTab(
                sourceTabId: sourceTabId,
                targetTabId: targetTabId,
                targetPaneId: targetPaneId,
                direction: direction
            )

        case .movePaneAcrossTabs(let request):
            executeMovePaneAcrossTabs(request)

        case .createArrangement(let tabId, let name):
            if store.tabLayoutAtom.createArrangement(name: name, inTab: tabId) == nil {
                Self.logger.warning(
                    "createArrangement: failed to create arrangement '\(name)' in tab \(tabId)")
            }

        case .removeArrangement(let tabId, let arrangementId):
            store.tabLayoutAtom.removeArrangement(arrangementId, inTab: tabId)

        case .switchArrangement(let tabId, let arrangementId):
            guard let tab = store.tabLayoutAtom.tab(tabId) else {
                Self.logger.warning("Cannot switch arrangement: tab \(tabId) not found")
                break
            }
            guard tab.arrangements.contains(where: { $0.id == arrangementId }) else {
                Self.logger.warning(
                    "Cannot switch arrangement: arrangement \(arrangementId) not found in tab \(tabId)"
                )
                break
            }

            // Capture visibility/minimized state before mutating the active arrangement.
            // Transition calculations depend on before/after sets.
            let previousVisiblePaneIds = Set(arrangementView.activeVisiblePaneIds(forTab: tabId))
            let previouslyMinimizedPaneIds = tab.activeMinimizedPaneIds
            store.tabLayoutAtom.switchArrangement(to: arrangementId, inTab: tabId)
            guard let updatedTab = store.tabLayoutAtom.tab(tabId) else {
                Self.logger.warning("Cannot switch arrangement: tab \(tabId) missing after switch")
                break
            }
            let newVisiblePaneIds = Set(arrangementView.activeVisiblePaneIds(forTab: tabId))
            let newMinimizedPaneIds = updatedTab.activeMinimizedPaneIds

            let transitions = Self.computeSwitchArrangementTransitions(
                previousVisiblePaneIds: previousVisiblePaneIds,
                previouslyMinimizedPaneIds: previouslyMinimizedPaneIds,
                newVisiblePaneIds: newVisiblePaneIds,
                newMinimizedPaneIds: newMinimizedPaneIds,
                retainedVisiblePaneIds: store.panePresentationAtom
                    .zoomPresentation(forTab: tabId)
                    .map { [$0.sourcePaneId] } ?? []
            )

            // Detach hidden panes before reattaching newly visible panes to avoid
            // transient duplicate attachments and focus churn.
            for paneId in transitions.hiddenPaneIds {
                detachForViewSwitch(paneId: paneId)
            }

            for paneId in transitions.paneIdsToReattach {
                reattachForViewSwitch(paneId: paneId)
            }
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .renameArrangement(let tabId, let arrangementId, let name):
            store.tabLayoutAtom.renameArrangement(arrangementId, name: name, inTab: tabId)

        case .backgroundPane(let paneId):
            retireZoomCompanion(forSourcePane: paneId)
            store.mutationCoordinator.backgroundPane(paneId)

        case .reactivatePane(let paneId, let targetTabId, let targetPaneId, let direction):
            let layoutDirection = bridgeDirection(direction)
            let position: Layout.Position = (direction == .left || direction == .up) ? .before : .after
            let didReactivate = store.mutationCoordinator.reactivatePane(
                paneId,
                inTab: targetTabId,
                at: targetPaneId,
                direction: layoutDirection,
                position: position,
                sizingMode: .halveTarget
            )
            guard didReactivate else { break }
            restoreViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)

        case .purgeOrphanedPane(let paneId):
            try await executeDiscardBackgroundedPane(paneId: paneId)

        case .enterDrawer,
            .focusDrawerPaneUp,
            .focusDrawerPaneLeft,
            .focusDrawerPaneDown,
            .focusDrawerPaneRight:
            Self.logger.debug(
                "Drawer focus action reached WorkspaceSurfaceCoordinator after validation; handled by PaneTabViewController"
            )

        case .detachDrawerPane(let parentPaneId, let drawerPaneId):
            guard let tabId = store.tabLayoutAtom.tabContaining(paneId: parentPaneId)?.id else {
                Self.logger.warning("detachDrawerPane: parent pane \(parentPaneId) is not in a visible tab")
                break
            }
            guard
                store.tabLayoutAtom.tab(tabId)?.activeArrangement.layout.contains(parentPaneId) == true
            else {
                Self.logger.warning(
                    "detachDrawerPane: parent pane \(parentPaneId) is not in the active arrangement for tab \(tabId)"
                )
                break
            }
            let drawerId = store.paneAtom.pane(parentPaneId)?.drawer?.drawerId

            guard let detachedPane = store.paneAtom.detachDrawerPane(drawerPaneId, from: parentPaneId) else {
                Self.logger.warning("detachDrawerPane: failed releasing drawer pane \(drawerPaneId)")
                break
            }
            if let drawerId {
                store.tabArrangementAtom.removeDrawerPaneView(
                    drawerId: drawerId, drawerPaneId: drawerPaneId, inTab: tabId)
            }

            guard
                store.tabLayoutAtom.insertPane(
                    drawerPaneId,
                    inTab: tabId,
                    at: parentPaneId,
                    direction: .horizontal,
                    position: .after,
                    sizingMode: .halveTarget
                )
            else {
                Self.logger.error("detachDrawerPane: failed inserting detached pane \(drawerPaneId) into tab \(tabId)")
                if store.paneAtom.restoreDrawerPane(detachedPane, to: parentPaneId), let drawerId {
                    store.tabArrangementAtom.addDrawerPaneView(
                        drawerId: drawerId,
                        parentPaneId: parentPaneId,
                        drawerPaneId: drawerPaneId,
                        inTab: tabId
                    )
                }
                break
            }
            store.tabLayoutAtom.setActivePane(drawerPaneId, inTab: tabId)
            restoreViewsForActiveTabIfNeeded()
            reattachForViewSwitch(paneId: drawerPaneId)
            focusVisiblePaneHost(drawerPaneId)

        case .addDrawerPane(let parentPaneId):
            try await executeInsertDrawerPane(
                parentPaneId: parentPaneId, targetDrawerPaneId: nil, direction: .right, sizingMode: .halveTarget)

        case .addWebviewDrawerPane(let parentPaneId, let state):
            executeAddWebviewDrawerPane(parentPaneId: parentPaneId, state: state)

        case .addDrawerChildInBackground(let parentPaneId, let childPaneId, .terminal):
            try await executeInsertDrawerPane(
                parentPaneId: parentPaneId, targetDrawerPaneId: nil, direction: .right, sizingMode: .halveTarget,
                childPaneId: childPaneId, presentation: .background)

        case .addDrawerChildInBackground(let parentPaneId, let childPaneId, .webview(let state)):
            executeAddWebviewDrawerPane(
                parentPaneId: parentPaneId, state: state, childPaneId: childPaneId, presentation: .background)

        case .removeDrawerPane(let parentPaneId, let drawerPaneId):
            try await executeDiscardDrawerPane(parentPaneId: parentPaneId, drawerPaneId: drawerPaneId)

        case .toggleDrawer(let paneId):
            store.paneAtom.toggleDrawer(for: paneId)
            // Runs for both directions: a collapse can also change which
            // canonical geometry is safe for a still-deferred member.
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }
            guard let drawer = store.paneAtom.pane(paneId)?.drawer, drawer.isExpanded else {
                focusVisiblePaneHost(paneId)
                break
            }
            let visibleDrawerPaneIds = arrangementView.drawerVisiblePaneIds(forParent: paneId)
            for drawerPaneId in visibleDrawerPaneIds {
                reattachForViewSwitch(paneId: drawerPaneId)
            }
            if let activeDrawerPaneId =
                arrangementView.drawerView(forParent: paneId)?.activeChildId
                ?? visibleDrawerPaneIds.first
                ?? drawer.paneIds.first
            {
                focusVisiblePaneHost(activeDrawerPaneId)
            } else {
                focusVisiblePaneHost(paneId)
            }
        case .setActiveDrawerPane(let parentPaneId, let drawerPaneId):
            guard let drawerContext = drawerCommandContext(parentPaneId: parentPaneId, command: "setActiveDrawerPane")
            else { break }
            store.tabArrangementAtom.setActiveDrawerPane(
                drawerPaneId, drawerId: drawerContext.drawerId, inTab: drawerContext.tabId)
            reattachForViewSwitch(paneId: drawerPaneId)
            focusVisiblePaneHost(drawerPaneId)
        case .resizeDrawerPane(let parentPaneId, let splitId, let ratio):
            guard let drawerContext = drawerCommandContext(parentPaneId: parentPaneId, command: "resizeDrawerPane")
            else { break }
            store.tabArrangementAtom.resizeDrawerPane(
                drawerId: drawerContext.drawerId, tabId: drawerContext.tabId, splitId: splitId, ratio: ratio)
        case .resizeDrawerVisiblePanePair(let parentPaneId, let leftPaneId, let rightPaneId, let ratio):
            guard
                let drawerContext = drawerCommandContext(
                    parentPaneId: parentPaneId, command: "resizeDrawerVisiblePanePair")
            else { break }
            store.tabArrangementAtom.resizeDrawerVisiblePanePair(
                drawerId: drawerContext.drawerId,
                tabId: drawerContext.tabId,
                leftPaneId: leftPaneId,
                rightPaneId: rightPaneId,
                ratio: ratio
            )
        case .equalizeDrawerPanes(let parentPaneId):
            guard let drawerContext = drawerCommandContext(parentPaneId: parentPaneId, command: "equalizeDrawerPanes")
            else { break }
            store.tabArrangementAtom.equalizeDrawerPanes(drawerId: drawerContext.drawerId, tabId: drawerContext.tabId)
        case .minimizeDrawerPane(let parentPaneId, let drawerPaneId):
            guard let drawerContext = drawerCommandContext(parentPaneId: parentPaneId, command: "minimizeDrawerPane")
            else { break }
            guard
                store.tabArrangementAtom.minimizeDrawerPane(
                    drawerPaneId, drawerId: drawerContext.drawerId, tabId: drawerContext.tabId)
            else { break }
            detachForViewSwitch(paneId: drawerPaneId)

        case .expandDrawerPane(let parentPaneId, let drawerPaneId):
            guard let drawerContext = drawerCommandContext(parentPaneId: parentPaneId, command: "expandDrawerPane")
            else { break }
            store.tabArrangementAtom.expandDrawerPane(
                drawerPaneId, drawerId: drawerContext.drawerId, tabId: drawerContext.tabId)
            reattachForViewSwitch(paneId: drawerPaneId)

        case .insertDrawerPane(let parentPaneId, let targetDrawerPaneId, let direction, let sizingMode):
            try await executeInsertDrawerPane(
                parentPaneId: parentPaneId,
                targetDrawerPaneId: targetDrawerPaneId,
                direction: direction,
                sizingMode: sizingMode
            )

        case .setZoomSplitRatio(let tabId, let ratio):
            _ = store.panePresentationAtom.setZoomSplitRatio(ratio, inTab: tabId)
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .setDrawerNormalHeightRatio(let parentPaneId, let ratio):
            store.paneAtom.setDrawerNormalHeightRatio(ratio, forOwner: parentPaneId)
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .setDrawerZoomSide(let parentPaneId, let side):
            store.paneAtom.setDrawerZoomSide(side, forOwner: parentPaneId)
            Task { [weak self] in await self?.reevaluatePreparedTerminalGeometry() }

        case .moveDrawerPane(let parentPaneId, let drawerPaneId, let target, let sizingMode):
            guard let drawerContext = drawerCommandContext(parentPaneId: parentPaneId, command: "moveDrawerPane")
            else { break }
            store.tabArrangementAtom.moveDrawerPane(
                drawerPaneId,
                drawerId: drawerContext.drawerId,
                tabId: drawerContext.tabId,
                target: target,
                sizingMode: sizingMode
            )
            focusVisiblePaneHost(drawerPaneId)

        case .expireUndoEntry:
            Self.logger.warning(
                "expireUndoEntry: explicit per-pane expiry is currently unsupported; undo GC is handled by expireOldUndoEntries()"
            )

        case .repair(let repairAction):
            executeRepair(repairAction)
        }

    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    /// Common path: create pane + view + tab for a worktree.
    private func createTerminalTab(
        for worktree: Worktree,
        in repo: Repo,
        cwdOverride: URL? = nil,
        titleOverride: String? = nil
    ) async throws -> Pane? {
        let resolvedCwd = cwdOverride ?? worktree.path
        let resolvedTitle = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paneFacets = PaneContextFacets(
            repoId: repo.id,
            repoName: repo.name,
            worktreeId: worktree.id,
            worktreeName: worktree.name,
            cwd: resolvedCwd,
            parentFolder: repo.repoPath.deletingLastPathComponent().path
        )
        let pane = try await store.createTerminalPane(
            metadata: PaneMetadata(
                launchDirectory: resolvedCwd,
                title: (resolvedTitle?.isEmpty == false) ? resolvedTitle! : worktree.name,
                facets: paneFacets),
            placement: .newTab,
            nameForPane: { [self] in tabNameForPane($0) },
            willPublish: { [self] in prepareTerminalPaneSlot($0) })
        traceTerminalLayoutInsertedAndViewCreateStarted(pane)
        ensureTerminalPaneView(pane)
        recordWorktreeOpened(worktree, in: repo)

        Self.logger.info("Opened terminal for worktree: \(worktree.name)")
        return pane
    }

    func recordWorktreeOpened(_ worktree: Worktree, in repo: Repo) {
        do {
            try atom(\.applicationEntityRecency).recordOpened(
                repositoryStableKey: repo.stableKey,
                worktreeStableKey: worktree.stableKey,
                at: Date()
            )
        } catch {
            Self.logger.warning("Worktree recency recording rejected an invalid stable identity")
        }
    }

    private func executeCloseTab(_ tabId: UUID) async throws {
        try await executeDurableClose(tabID: tabId, paneID: nil)
    }

    private func executeBreakUpTab(_ tabId: UUID) {
        let sourcePaneIds = store.tabLayoutAtom.tab(tabId)?.allPaneIds ?? []
        let capturedZoomCompanions = captureZoomCompanions(
            forSourcePanes: sourcePaneIds
        )
        store.panePresentationAtom.cancelZoom(inTab: tabId)
        let newTabs = store.tabLayoutAtom.breakUpTab(
            tabId,
            drawerPayloadsByParentPaneId: drawerMovePayloadsByParentPaneId(inTab: tabId)
        )
        reassociateZoomCompanionsWithCurrentTabs(capturedZoomCompanions)
        for newTab in newTabs {
            guard let paneId = newTab.activePaneId else { continue }
            guard let pane = store.paneAtom.pane(paneId) else {
                Self.logger.warning("breakUpTab: pane \(paneId) missing while naming new tab \(newTab.id)")
                continue
            }
            store.tabLayoutAtom.renameTab(newTab.id, name: tabNameForPane(pane))
        }
    }

    private func executeClosePane(tabId: UUID, paneId: UUID) async throws {
        try await executeDurableClose(tabID: tabId, paneID: paneId)
    }

    private func drawerCommandContext(parentPaneId: UUID, command: String) -> (tabId: UUID, drawerId: UUID)? {
        guard let tabId = store.tabLayoutAtom.tabContaining(paneId: parentPaneId)?.id else {
            Self.logger.error("\(command): parent pane \(parentPaneId) has no owning tab")
            return nil
        }
        guard let drawerId = store.paneAtom.pane(parentPaneId)?.drawer?.drawerId else {
            Self.logger.error("\(command): parent pane \(parentPaneId) has no drawer")
            return nil
        }
        return (tabId, drawerId)
    }

}
