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
            // A5 (advisor review 2026-10-01): `restorePhaseLatch` (SR6b) lives
            // on the native surface, not the pane, so tearing down and
            // rebuilding that surface silently drops an open restore phase --
            // nothing else ends it, since `TerminalActivityProjector`'s own
            // pane-keyed restore state intentionally survives surface
            // replacement and waits for this latch's input signal. Carry it
            // across the repair by hand: capture it from the surface about to
            // be torn down, and re-arm it on whatever surface replaces it.
            //
            // R2-2 (review round 2, Lead 2026-10-01): a failed replacement
            // below used to discard this local value outright -- the
            // projector's own phase survives the failure (by design), but
            // nothing was left to reinstall once a *later* repair finally
            // succeeded, so that surface's first real input did nothing and
            // activity stayed suppressed forever. Falling back to
            // `pendingRestorePhaseLatchesByPaneID` covers the case where an
            // earlier attempt already failed and no surface exists yet to
            // capture the generation from directly.
            let preservedRestorePhaseLatch =
                viewRegistry.terminalView(for: paneId)?.ghosttySurface?.restorePhaseLatch
                ?? pendingRestorePhaseLatchesByPaneID[paneId]
            // R3-1 (review round 3, Lead decision 2026-10-02): recorded
            // before teardown, not only on a later failure branch. Geometry
            // can come back unavailable here (`createViewForRepair` ->
            // `createViewForContentUsingCurrentGeometry` -> empty bounds ->
            // a preparing placeholder, `nil`) without this attempt counting
            // as the explicit failure case below -- `createViewForRepair`
            // still returns non-`nil` for a `TerminalStatusPlaceholderView`.
            // The eventual real mount, whether a later explicit repair or
            // ordinary visible/active-tab recovery's plain
            // `createViewForContent`, reads this pending entry at the one
            // shared successful-mount boundary (`createView`/
            // `createTopologyIndependentTerminalView`,
            // WorkspaceSurfaceCoordinator+ViewLifecycle.swift) and installs
            // it there -- recording it here, unconditionally, is what makes
            // that boundary able to find it regardless of which caller
            // eventually succeeds.
            if let preservedRestorePhaseLatch {
                pendingRestorePhaseLatchesByPaneID[paneId] = preservedRestorePhaseLatch
            }
            teardownView(for: paneId, shouldUnregisterRuntime: false)
            guard createViewForRepair(for: pane) != nil else {
                Self.logger.error("repair recreateSurface failed for pane \(paneId)")
                // R2-2: the generation stays pending through this failed
                // attempt (recorded above, before teardown) -- a later
                // repair that succeeds (recreateSurface again, or
                // createMissingView) still reinstalls it. The projector's
                // own phase is left untouched either way; this never
                // clears it and never re-runs cold classification.
                return
            }
            // `createViewForRepair` returns the bare content view (a
            // `TerminalPaneMountView` as `NSView`), not the `PaneHostView`
            // wrapper `mountedContent(as:)` is declared on
            // (`PaneHostView.swift:139`) -- that wrapper is a different
            // object, built and registered inside `registerHostedView`
            // (`WorkspaceSurfaceCoordinator+ViewLifecycle.swift:53-58`),
            // which every terminal creation path this repair can reach
            // (`createTopologyIndependentTerminalView`'s own success case,
            // confirmed by reading it directly) already calls before
            // returning. Re-apply through the same registry lookup the
            // capture above used, symmetric with it, instead of downcasting
            // this function's own return value.
            if let preservedRestorePhaseLatch {
                viewRegistry.terminalView(for: paneId)?.ghosttySurface?.restorePhaseLatch =
                    preservedRestorePhaseLatch
                // R2-2: reinstalled for real -- no longer pending.
                pendingRestorePhaseLatchesByPaneID.removeValue(forKey: paneId)
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
            // R2-2 (review round 2, Lead 2026-10-01): this path can also be
            // the one that finally succeeds after an earlier
            // `.recreateSurface` attempt failed and left a generation
            // pending -- reinstall it here too, the same way
            // `.recreateSurface`'s own success path does above.
            if let preservedRestorePhaseLatch = pendingRestorePhaseLatchesByPaneID[paneId] {
                viewRegistry.terminalView(for: paneId)?.ghosttySurface?.restorePhaseLatch =
                    preservedRestorePhaseLatch
                pendingRestorePhaseLatchesByPaneID.removeValue(forKey: paneId)
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
