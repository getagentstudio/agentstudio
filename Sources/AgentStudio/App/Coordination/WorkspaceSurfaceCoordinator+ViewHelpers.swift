import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit

@MainActor
extension WorkspaceSurfaceCoordinator {
    func resolvedWorktreeContext(
        for targetPane: Pane?
    ) -> (repo: Repo, worktree: Worktree)? {
        if let resolved = store.repositoryTopologyAtom.validatedAssociation(
            repoId: targetPane?.repoId,
            worktreeId: targetPane?.worktreeId
        ) {
            return resolved
        }

        return store.repositoryTopologyAtom.repoAndWorktree(containing: targetPane?.metadata.facets.cwd)
    }

    func contextualBrowserMetadata(
        from pane: Pane,
        fallbackTitle: String
    ) -> (
        metadata: PaneMetadata,
        repo: Repo?,
        worktree: Worktree?
    ) {
        if let resolved = store.repositoryTopologyAtom.validatedAssociation(
            repoId: pane.repoId,
            worktreeId: pane.worktreeId
        ) {
            return (
                PaneMetadata(
                    contentType: .browser,
                    launchDirectory: resolved.worktree.path,
                    title: fallbackTitle,
                    facets: PaneContextFacets(
                        repoId: resolved.repo.id,
                        repoName: resolved.repo.name,
                        worktreeId: resolved.worktree.id,
                        worktreeName: resolved.worktree.name,
                        cwd: pane.metadata.cwd ?? resolved.worktree.path
                    )
                ),
                resolved.repo,
                resolved.worktree
            )
        }

        if let resolved = store.repositoryTopologyAtom.repoAndWorktree(containing: pane.metadata.cwd) {
            return (
                PaneMetadata(
                    contentType: .browser,
                    launchDirectory: resolved.worktree.path,
                    title: fallbackTitle,
                    facets: PaneContextFacets(
                        repoId: resolved.repo.id,
                        repoName: resolved.repo.name,
                        worktreeId: resolved.worktree.id,
                        worktreeName: resolved.worktree.name,
                        cwd: pane.metadata.cwd ?? resolved.worktree.path
                    )
                ),
                resolved.repo,
                resolved.worktree
            )
        }

        return (
            PaneMetadata(
                contentType: .browser,
                title: fallbackTitle
            ),
            nil,
            nil
        )
    }

    func executeInsertDrawerPane(
        parentPaneId: UUID,
        targetDrawerPaneId: UUID?,
        direction: SplitNewDirection,
        sizingMode: DropSizingMode,
        childPaneId: UUID? = nil,
        presentation: DrawerChildPresentation = .interactive
    ) async throws {
        guard let tabID = store.tabLayoutAtom.tabContaining(paneId: parentPaneId)?.id else {
            Self.logger.warning("Drawer creation rejected a parent without an owning tab")
            return
        }
        let fallbackCWD =
            store.paneAtom.pane(parentPaneId)?.worktreeId.flatMap(store.repositoryTopologyAtom.worktree)?.path
            ?? FileManager.default.homeDirectoryForCurrentUser
        let drawerPane = try await store.createTerminalPane(
            metadata: PaneMetadata(launchDirectory: fallbackCWD, title: "Drawer"),
            placement: .drawer(
                .init(
                    tabID: tabID, parentID: parentPaneId, anchorID: targetDrawerPaneId,
                    direction: direction, sizingMode: sizingMode,
                    childID: childPaneId, presentation: presentation)),
            nameForPane: { [self] in tabNameForPane($0) },
            willPublish: { [self] in prepareTerminalPaneSlot($0) })
        registerTerminalPlaceholderIfNeeded(for: drawerPane, mode: .preparing)
        traceTerminalLayoutInsertedAndViewCreateStarted(drawerPane)
        ensureTerminalPaneView(drawerPane)
        guard presentation == .interactive else { return }
        focusVisiblePaneHost(drawerPane.id)
    }

    /// The retired launch-window presentation flag is never consulted here:
    /// the actual creation gate is the per-pane `TerminalSurfaceCreationAuthority`
    /// resolved downstream inside `createViewForContent` (reached via
    /// `createViewForContentUsingCurrentGeometry` below), which refuses to
    /// create while the prepared lane still owns this pane.
    func ensureTerminalPaneView(_ pane: Pane) {
        // Layout restoration may mount the committed pane before its creating
        // command resumes. Preserve that instance instead of allocating a second
        // manager-owned renderer. Explicit repair tears down the host first.
        if let mountedTerminal = viewRegistry.terminalView(for: pane.id),
            mountedTerminal.surfaceId != nil
        {
            return
        }
        registerTerminalPlaceholderIfNeeded(for: pane, mode: .preparing)
        if createViewForContentUsingCurrentGeometry(pane: pane) == nil {
            RestoreTrace.log("ensureTerminalPaneView deferred pane=\(pane.id)")
            restoreViewsForActiveTabIfNeeded()
        }
    }

    func restoreVisiblePaneIfNeeded(_ paneId: UUID, forceWhenBoundsExist: Bool = false) {
        let clock = ContinuousClock()
        let restoreStart = clock.now
        guard let activeTab = store.tabLayoutAtom.activeTab else { return }
        if !windowLifecycleStore.isLaunchLayoutSettled {
            let hasPreparingPlaceholder =
                viewRegistry.terminalStatusPlaceholderView(for: paneId)?.shouldRetryCreationWhenBoundsChange == true
            guard forceWhenBoundsExist || hasPreparingPlaceholder || windowLifecycleStore.isReadyForLaunchRestore else {
                RestoreTrace.log(
                    "restoreVisiblePaneIfNeeded skipped launchLayoutUnsettled pane=\(paneId) bounds=\(NSStringFromRect(windowLifecycleStore.terminalContainerBounds)) settled=\(windowLifecycleStore.isLaunchLayoutSettled)"
                )
                return
            }
        }

        let terminalContainerBounds = windowLifecycleStore.terminalContainerBounds
        guard !terminalContainerBounds.isEmpty else {
            RestoreTrace.log("restoreVisiblePaneIfNeeded skipped boundsUnavailable pane=\(paneId)")
            return
        }

        let runtimePaneId = PaneId(existingUUID: paneId)
        guard forceWhenBoundsExist || visibilityTierResolver.tier(for: runtimePaneId) == .p0Visible else {
            return
        }
        // The retired launch-window presentation flag is never consulted
        // here: `createViewForContent` below resolves the actual per-pane
        // creation gate (terminal authority, or the prepared nonterminal
        // lane's own custody).
        guard let pane = store.paneAtom.pane(paneId) else { return }
        guard store.tabLayoutAtom.tabContaining(paneId: pane.parentPaneId ?? pane.id)?.id == activeTab.id else {
            return
        }

        let hadPlaceholder = viewRegistry.terminalStatusPlaceholderView(for: paneId) != nil
        if let placeholder = viewRegistry.terminalStatusPlaceholderView(for: paneId) {
            guard forceWhenBoundsExist || placeholder.shouldRetryCreationWhenBoundsChange else { return }
        } else if viewRegistry.view(for: paneId) != nil {
            return
        }

        let resolvedPaneFramesByTabId = resolveInitialFramesByTabId(in: terminalContainerBounds)
        _ = createViewForContent(
            pane: pane,
            initialFrame: initialFrame(for: pane, resolvedPaneFramesByTabId: resolvedPaneFramesByTabId),
            treatAsRestoredSessionStart: true
        )
        performanceTraceRecorder?.recordDuration(
            .paneViewRestoreVisible,
            duration: restoreStart.duration(to: clock.now),
            attributes: [
                "agentstudio.performance.pane_view_restore.force_when_bounds_exist": .bool(forceWhenBoundsExist),
                "agentstudio.performance.pane_view_restore.had_placeholder": .bool(hadPlaceholder),
                "agentstudio.performance.pane_view_restore.pane.count": .int(store.paneAtom.graphAtom.paneIDs.count),
                "agentstudio.performance.pane_view_restore.tab.count": .int(store.tabLayoutAtom.tabs.count),
            ]
        )
    }

    func focusVisiblePaneHost(
        _ paneId: UUID,
        reason: PaneRefocusRequestTrigger.Reason = .explicit
    ) {
        if applyPaneRefocusIfReady(for: paneId, reason: reason) {
            pendingPaneRefocusReasonsByPaneId.removeValue(forKey: paneId)
        } else {
            pendingPaneRefocusReasonsByPaneId[paneId] = reason
        }
    }

    @discardableResult
    func clearFirstResponderToWindowContent(for paneId: UUID) -> Bool {
        let window = viewRegistry.view(for: paneId)?.window ?? NSApplication.shared.keyWindow
        guard let window, let contentView = window.contentView else { return false }
        pendingPaneRefocusReasonsByPaneId.removeValue(forKey: paneId)
        return window.makeFirstResponder(contentView)
    }

    func handlePaneHostAttachedToWindow(_ paneId: UUID) {
        guard let parkedReason = pendingPaneRefocusReasonsByPaneId[paneId] else { return }
        let replayReason: PaneRefocusRequestTrigger.Reason =
            parkedReason == .restoreTail ? .parkedRestoreReplay : parkedReason
        if applyPaneRefocusIfReady(for: paneId, reason: replayReason) {
            pendingPaneRefocusReasonsByPaneId.removeValue(forKey: paneId)
        }
    }

    @discardableResult
    func focusPaneHostIfReady(_ paneId: UUID) -> Bool {
        applyPaneRefocusIfReady(for: paneId, reason: .explicit)
    }

    func clearPendingPaneRefocusRequestsAfterUserFocusChange() {
        let restoreParkedPaneIds = pendingPaneRefocusReasonsByPaneId.compactMap { paneId, reason in
            reason == .restoreTail || reason == .parkedRestoreReplay ? paneId : nil
        }
        guard !restoreParkedPaneIds.isEmpty else { return }
        for paneId in restoreParkedPaneIds {
            pendingPaneRefocusReasonsByPaneId.removeValue(forKey: paneId)
        }
        performanceTraceRecorder?.recordFocusResponderChange(reason: .parkedCleared)
    }

    @discardableResult
    private func applyPaneRefocusIfReady(
        for paneId: UUID,
        reason: PaneRefocusRequestTrigger.Reason
    ) -> Bool {
        let paneKind = PaneFocusContext.PaneKind(content: store.paneAtom.pane(paneId)?.content)
        let targetPaneHost = viewRegistry.view(for: paneId)
        let window = targetPaneHost?.window
        let firstResponder = window?.firstResponder
        let responderIsHandoffEligibleInsideTargetPane =
            if let responderView = firstResponder as? NSView, let targetPaneHost {
                if responderView === targetPaneHost {
                    true
                } else if let terminalMount = targetPaneHost.mountedContent(as: TerminalPaneMountView.self) {
                    responderView === terminalMount
                        || terminalMount.currentPlaceholderView.map {
                            responderView === $0 || responderView.isDescendant(of: $0)
                        } == true
                } else {
                    false
                }
            } else {
                false
            }
        let currentResponderOwnership: PaneFocusContext.CurrentResponderOwnership =
            if window == nil || firstResponder == nil || firstResponder === window
                || firstResponder === window?.contentView || responderIsHandoffEligibleInsideTargetPane
            {
                .windowContentDefault
            } else {
                .userOwned
            }

        let decision = PaneFocusOrchestrator.decide(
            trigger: .refocusRequest(PaneRefocusRequestTrigger(reason: reason)),
            context: PaneFocusContext(
                activeTabId: store.tabLayoutAtom.activeTabId,
                activePaneId: paneId,
                activeDrawer: nil,
                targetPaneId: paneId,
                targetTabId: store.tabLayoutAtom.tabs.first { $0.paneIds.contains(paneId) }?.id,
                targetPaneKind: paneKind,
                targetPaneIsAlreadyActive: true,
                targetMountedContent: viewRegistry.view(for: paneId)?.mountedContentStateForPaneFocus ?? .unmounted,
                managementLayer: atom(\.managementLayer).isActive ? .active(scope: .mainRow) : .inactive,
                windowState: window?.isKeyWindow == true ? .key : .background,
                currentResponderOwnership: currentResponderOwnership
            )
        )

        guard case .refocusRequest(let refocusDecision) = decision else {
            Self.logger.error("pane refocus produced non-refocus decision for pane \(paneId)")
            return false
        }

        let didApply = makeRefocusOnlyPaneFocusExecutor().apply(.refocusRequest(refocusDecision))
        if didApply,
            let telemetryReason = focusResponderChangeReason(
                requestReason: reason,
                responderOwnership: currentResponderOwnership
            )
        {
            performanceTraceRecorder?.recordFocusResponderChange(
                reason: telemetryReason
            )
        }
        return didApply
    }

    private func focusResponderChangeReason(
        requestReason: PaneRefocusRequestTrigger.Reason,
        responderOwnership: PaneFocusContext.CurrentResponderOwnership
    ) -> AgentStudioFocusResponderChangeReason? {
        switch requestReason {
        case .restoreTail where responderOwnership == .userOwned:
            .restoreTailSkippedUserFocus
        case .restoreTail:
            .restoreTail
        case .parkedRestoreReplay:
            .parkedReplay
        case .explicit, .windowBecameKey, .managementLayerExited:
            nil
        }
    }

    private func makeRefocusOnlyPaneFocusExecutor() -> PaneFocusExecutor {
        // Refocus decisions never carry selection actions, so these no-op
        // closures are intentional and keep the coordinator path limited to
        // responder/runtime repair work only.
        PaneFocusExecutor(
            hostViewProvider: { [weak self] targetPaneId in
                self?.viewRegistry.view(for: targetPaneId)
            },
            hostViewsProvider: { [weak self] in
                guard let self else { return [] }
                return self.viewRegistry.registeredPaneIds.compactMap { self.viewRegistry.view(for: $0) }
            },
            selectTab: { _ in },
            selectPane: { _, _ in },
            selectDrawerPane: { _, _ in },
            selectEmptyDrawer: { _ in },
            syncRuntimeFocus: { [weak self] surfaceId in
                self?.surfaceManager.syncFocus(activeSurfaceId: surfaceId)
            }
        )
    }

    func executeMergeTab(
        sourceTabId: UUID,
        targetTabId: UUID,
        targetPaneId: UUID,
        direction: SplitNewDirection
    ) {
        let layoutDirection = bridgeDirection(direction)
        let position: Layout.Position = (direction == .left || direction == .up) ? .before : .after
        let sourcePaneIds = store.tabLayoutAtom.tab(sourceTabId)?.allPaneIds ?? []
        let capturedZoomCompanions = captureZoomCompanions(
            forSourcePanes: sourcePaneIds
        )
        store.panePresentationAtom.cancelZoom(inTab: sourceTabId)

        store.tabLayoutAtom.mergeTab(
            sourceId: sourceTabId,
            intoTarget: targetTabId,
            at: targetPaneId,
            direction: layoutDirection,
            position: position,
            drawerPayloadsByParentPaneId: drawerMovePayloadsByParentPaneId(inTab: sourceTabId)
        )
        reassociateZoomCompanionsWithCurrentTabs(capturedZoomCompanions)
    }

    func executeRepair(_ repairAction: RepairAction) {
        switch repairAction {
        case .recreateSurface(let paneId):
            guard let pane = store.paneAtom.pane(paneId) else {
                Self.logger.warning("repair \(String(describing: repairAction)): pane not in store")
                return
            }
            teardownView(for: paneId, shouldUnregisterRuntime: false)
            guard createViewForRepair(for: pane) != nil else {
                Self.logger.error("repair recreateSurface failed for pane \(paneId)")
                return
            }
            Self.logger.info("Repaired view for pane \(paneId)")

        case .createMissingView(let paneId):
            guard let pane = store.paneAtom.pane(paneId) else {
                Self.logger.warning("repair \(String(describing: repairAction)): pane not in store")
                return
            }
            if let existingView = viewRegistry.view(for: paneId),
                existingView.mountedContent(as: TerminalPaneMountView.self)?.currentPlaceholderView == nil
            {
                Self.logger.info("repair createMissingView: pane \(paneId) already has a view")
                return
            }
            guard createViewForRepair(for: pane) != nil else {
                Self.logger.error("repair createMissingView failed for pane \(paneId)")
                return
            }
            Self.logger.info("Created missing view for pane \(paneId)")

        case .reattachZmx, .markSessionFailed, .cleanupOrphan:
            Self.logger.warning("repair: \(String(describing: repairAction)) — not yet implemented")
        }
    }

    /// Recreate a pane view during repair while preserving geometry requirements for terminals.
    /// Terminal panes must use trusted current geometry; non-terminal panes can be recreated directly.
    func createViewForRepair(for pane: Pane) -> NSView? {
        if case .terminal = pane.content {
            return createViewForContentUsingCurrentGeometry(pane: pane)
        }
        return createViewForContent(pane: pane)
    }

    /// Teardown views for all drawer panes owned by a parent pane.
    func teardownDrawerPanes(for parentPaneId: UUID) {
        guard let pane = store.paneAtom.pane(parentPaneId),
            let drawer = pane.drawer
        else { return }
        for drawerPaneId in drawer.paneIds {
            teardownView(for: drawerPaneId)
        }
    }

    /// Bridge SplitNewDirection → Layout.SplitDirection.
    func bridgeDirection(_ direction: SplitNewDirection) -> Layout.SplitDirection {
        switch direction {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }
}
