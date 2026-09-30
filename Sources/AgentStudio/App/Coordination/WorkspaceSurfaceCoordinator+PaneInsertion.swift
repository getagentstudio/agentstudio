import AgentStudioCore
import AppKit

@MainActor
extension WorkspaceSurfaceCoordinator {
    func executeInsertPane(
        source: PaneSource,
        targetTabId: UUID,
        targetPaneId: UUID,
        direction: SplitNewDirection,
        sizingMode: DropSizingMode
    ) async throws {
        let layoutDirection = bridgeDirection(direction)
        let position: Layout.Position = (direction == .left || direction == .up) ? .before : .after

        switch source {
        case .existingPane(let paneId, let sourceTabId):
            guard store.paneAtom.pane(paneId) != nil else {
                Self.logger.warning("insertPane existingPane: pane \(paneId) not found")
                return
            }
            guard let sourceTabBeforeMove = store.tabLayoutAtom.tab(sourceTabId) else {
                Self.logger.warning("insertPane existingPane: source tab \(sourceTabId) not found")
                return
            }
            let sourceTabIndexBeforeMove =
                store.tabLayoutAtom.tabs.firstIndex { $0.id == sourceTabId }
                ?? store.tabLayoutAtom.tabs.count
            let sourceTabWasActiveBeforeMove = store.tabLayoutAtom.activeTabId == sourceTabId
            guard store.tabLayoutAtom.tab(targetTabId) != nil else {
                Self.logger.warning("insertPane existingPane: target tab \(targetTabId) not found")
                return
            }
            guard
                store.tabLayoutAtom.tab(targetTabId)?.activeArrangement.layout.contains(targetPaneId) == true
            else {
                Self.logger.warning(
                    "insertPane existingPane: target pane \(targetPaneId) is not in the active arrangement for tab \(targetTabId)"
                )
                return
            }
            store.tabLayoutAtom.removePaneFromLayout(paneId, inTab: sourceTabId)
            if !store.tabLayoutAtom.insertPane(
                paneId, inTab: targetTabId, at: targetPaneId,
                direction: layoutDirection, position: position, sizingMode: sizingMode
            ) {
                Self.logger.error(
                    "insertPane existingPane: failed inserting pane \(paneId) into tab \(targetTabId)"
                )
                store.tabLayoutAtom.restoreTab(sourceTabBeforeMove, at: sourceTabIndexBeforeMove)
                if sourceTabWasActiveBeforeMove {
                    store.tabLayoutAtom.setActiveTab(sourceTabId)
                }
            }

        case .newTerminal, .newTerminalAtDirectory:
            try await executeInsertTerminalPane(
                source: source,
                targetTabId: targetTabId,
                targetPaneId: targetPaneId,
                layoutDirection: layoutDirection,
                position: position,
                sizingMode: sizingMode
            )

        case .newWebview(let state):
            executeInsertWebviewPane(
                state,
                targetTabId: targetTabId,
                targetPaneId: targetPaneId,
                direction: direction,
                sizingMode: sizingMode
            )
        }
    }

    private func executeInsertTerminalPane(
        source: PaneSource,
        targetTabId: UUID,
        targetPaneId: UUID,
        layoutDirection: Layout.SplitDirection,
        position: Layout.Position,
        sizingMode: DropSizingMode
    ) async throws {
        let targetPane = store.paneAtom.pane(targetPaneId)
        let explicitDirectory: URL?
        if case .newTerminalAtDirectory(let directory) = source {
            explicitDirectory = directory
        } else {
            explicitDirectory = nil
        }
        let resolvedContext: (repo: Repo, worktree: Worktree)?
        if let explicitDirectory {
            resolvedContext = store.repositoryTopologyAtom.repoAndWorktree(containing: explicitDirectory)
        } else {
            resolvedContext = resolvedWorktreeContext(for: targetPane)
        }
        let launchDirectory =
            explicitDirectory
            ?? targetPane?.metadata.cwd
            ?? targetPane?.metadata.launchDirectory
            ?? resolvedContext?.worktree.path
            ?? FileManager.default.homeDirectoryForCurrentUser
        let inheritedFacets = explicitDirectory == nil ? targetPane?.metadata.facets ?? .empty : .empty
        let resolvedFacets: PaneContextFacets
        if let resolved = resolvedContext {
            resolvedFacets = PaneContextFacets(
                repoId: resolved.repo.id, repoName: resolved.repo.name,
                worktreeId: resolved.worktree.id, worktreeName: resolved.worktree.name,
                cwd: launchDirectory)
        } else {
            resolvedFacets = PaneContextFacets(cwd: launchDirectory)
        }
        let pane = try await store.createTerminalPane(
            metadata: PaneMetadata(
                launchDirectory: launchDirectory, title: "Terminal",
                facets: inheritedFacets.fillingNilFields(from: resolvedFacets)),
            placement: .split(
                .init(
                    tabID: targetTabId, anchorID: targetPaneId, direction: layoutDirection,
                    position: position, sizingMode: sizingMode)),
            nameForPane: { [self] in tabNameForPane($0) },
            willPublish: { [self] in prepareTerminalPaneSlot($0) })
        registerTerminalPlaceholderIfNeeded(for: pane, mode: .preparing)
        traceTerminalLayoutInsertedAndViewCreateStarted(pane)
        ensureTerminalPaneView(pane)
    }

    private func executeInsertWebviewPane(
        _ state: WebviewState,
        targetTabId: UUID,
        targetPaneId: UUID,
        direction: SplitNewDirection,
        sizingMode: DropSizingMode
    ) {
        guard let targetPane = store.paneAtom.pane(targetPaneId) else {
            Self.logger.warning("insertPane newWebview: target pane \(targetPaneId) not found")
            return
        }
        let fallbackTitle = state.title.isEmpty ? (state.url.host() ?? "GitHub") : state.title
        let context = contextualBrowserMetadata(
            from: targetPane,
            fallbackTitle: fallbackTitle
        )
        guard
            let pane = store.paneAtom.createPane(
                content: .webview(state),
                metadata: context.metadata
            )
        else {
            Self.logger.error("insertPane newWebview: pane admission failed")
            return
        }
        viewRegistry.ensureSlot(for: pane.id)

        guard createViewForContent(pane: pane) != nil else {
            Self.logger.error("insertPane newWebview: view creation failed for pane \(pane.id)")
            store.mutationCoordinator.removePane(pane.id)
            viewRegistry.removeSlot(for: pane.id)
            return
        }

        let layoutDirection = bridgeDirection(direction)
        let position: Layout.Position = (direction == .left || direction == .up) ? .before : .after
        guard
            store.tabLayoutAtom.insertNewPane(
                pane.id,
                inTab: targetTabId,
                at: targetPaneId,
                direction: layoutDirection,
                position: position,
                sizingMode: sizingMode
            )
        else {
            Self.logger.error(
                "insertPane newWebview: failed inserting pane \(pane.id) into tab \(targetTabId)")
            teardownView(for: pane.id)
            store.mutationCoordinator.removePane(pane.id)
            viewRegistry.removeSlot(for: pane.id)
            return
        }
        store.tabLayoutAtom.setActivePane(pane.id, inTab: targetTabId)
    }

    func executeAddWebviewDrawerPane(
        parentPaneId: UUID,
        state: WebviewState,
        childPaneId: UUID? = nil,
        presentation: DrawerChildPresentation = .interactive
    ) {
        guard let parentPane = store.paneAtom.pane(parentPaneId) else {
            Self.logger.warning("addWebviewDrawerPane: parent pane \(parentPaneId) not found")
            return
        }

        let fallbackTitle = state.title.isEmpty ? (state.url.host() ?? "GitHub") : state.title
        let context = contextualBrowserMetadata(from: parentPane, fallbackTitle: fallbackTitle)
        guard
            let pane = store.paneAtom.addDrawerPane(
                to: parentPaneId,
                content: .webview(state),
                metadata: context.metadata,
                childPaneId: childPaneId,
                expandsDrawer: presentation == .interactive
            )
        else {
            Self.logger.warning("addWebviewDrawerPane: failed to create drawer pane for \(parentPaneId)")
            return
        }

        viewRegistry.ensureSlot(for: pane.id)
        guard createViewForContent(pane: pane) != nil else {
            Self.logger.error("addWebviewDrawerPane: view creation failed for pane \(pane.id)")
            store.paneAtom.removeDrawerPane(pane.id, from: parentPaneId)
            viewRegistry.removeSlot(for: pane.id)
            return
        }
        guard let tabId = store.tabLayoutAtom.tabContaining(paneId: parentPaneId)?.id,
            let drawerId = store.paneAtom.pane(parentPaneId)?.drawer?.drawerId
        else {
            Self.logger.error("addWebviewDrawerPane: drawer calibration failed for parent \(parentPaneId)")
            teardownView(for: pane.id)
            store.paneAtom.removeDrawerPane(pane.id, from: parentPaneId)
            viewRegistry.removeSlot(for: pane.id)
            return
        }
        store.tabArrangementAtom.addNewDrawerPaneView(
            drawerId: drawerId,
            parentPaneId: parentPaneId,
            drawerPaneId: pane.id,
            inTab: tabId,
            selectsInsertedChild: presentation == .interactive
        )

        guard presentation == .interactive else { return }
        focusVisiblePaneHost(pane.id)
    }
}
