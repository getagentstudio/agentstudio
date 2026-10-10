import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit
import Foundation

@MainActor
extension WorkspaceSurfaceCoordinator {
    func registerPreparedTerminalPlaceholders(
        for descriptor: TerminalActivationDescriptor
    ) {
        _ = registerTerminalPlaceholderIfNeeded(
            for: descriptor.pane,
            mode: .preparing
        )
    }

    @discardableResult
    /// Create a pane view using the current trusted terminal container bounds.
    /// Returns nil when bounds are unavailable or when pane-specific frame resolution fails.
    func createViewForContentUsingCurrentGeometry(
        pane: Pane,
        treatAsRestoredSessionStart: Bool = false
    ) -> NSView? {
        let terminalContainerBounds = windowLifecycleStore.terminalContainerBounds
        guard !terminalContainerBounds.isEmpty else {
            RestoreTrace.log(
                "createViewForContentUsingCurrentGeometry deferred pane=\(pane.id) reason=emptyBounds"
            )
            registerTerminalPlaceholderIfNeeded(for: pane, mode: .preparing)
            return nil
        }

        let resolvedPaneFramesByTabId = resolveInitialFramesByTabId(in: terminalContainerBounds)
        return createViewForContent(
            pane: pane,
            initialFrame: initialFrame(for: pane, resolvedPaneFramesByTabId: resolvedPaneFramesByTabId),
            treatAsRestoredSessionStart: treatAsRestoredSessionStart
        )
    }

    @discardableResult
    func registerTerminalPlaceholderIfNeeded(
        for pane: Pane,
        mode: TerminalStatusPlaceholderMode
    ) -> TerminalStatusPlaceholderView? {
        guard case .terminal = pane.content, pane.provider == .zmx, isCurrentTerminalPane(pane) else { return nil }

        let retryHandler: (UUID) -> Void = { [weak self] paneId in
            self?.submitWorkspaceAction(.repair(.createMissingView(paneId: paneId)))
        }
        let dismissHandler: (UUID) -> Void = { [weak self] paneId in
            self?.closePaneFromErrorOverlay(paneId)
        }

        if let terminalView = viewRegistry.terminalView(for: pane.id) {
            // A delayed creation caller must not cover a terminal that layout
            // restoration already mounted. Failure/deferred states remain explicit.
            if mode == .preparing, terminalView.surfaceId != nil { return nil }
            return terminalView.showPlaceholder(
                mode: mode,
                onRetryRequested: retryHandler,
                onDismissRequested: dismissHandler
            )
        }

        if let existingPlaceholder = viewRegistry.terminalStatusPlaceholderView(for: pane.id) {
            existingPlaceholder.configure(mode: mode)
            return existingPlaceholder
        }

        let terminalView = TerminalPaneMountView(
            surfaceOperations: terminalSurfaceOperations,
            paneId: pane.id,
            title: pane.metadata.title,
            performanceTraceRecorder: performanceTraceRecorder
        )
        terminalView.showPlaceholder(
            mode: mode,
            onRetryRequested: retryHandler,
            onDismissRequested: dismissHandler
        )
        registerHostedView(mountedView: terminalView, for: pane.id)
        return terminalView.currentPlaceholderView
    }

    func installClosePaneRequest(on terminalView: TerminalPaneMountView) {
        let paneId = terminalView.paneId
        terminalView.onClosePaneRequested = { [weak self] in
            self?.closePaneFromErrorOverlay(paneId)
        }
    }

    func closePaneFromErrorOverlay(_ paneId: UUID) {
        guard let tab = store.tabLayoutAtom.tabs.first(where: { $0.allPaneIds.contains(paneId) }) else {
            Self.logger.warning("closePaneFromErrorOverlay: pane \(paneId) has no owning tab")
            return
        }
        submitWorkspaceAction(.closePane(tabId: tab.id, paneId: paneId))
    }

    func activeTabHasMissingVisibleView(_ activeTab: Tab) -> Bool {
        let visiblePaneIds = TerminalRestoreScheduler.order(
            activeTab.allPaneIds.map { PaneId(existingUUID: $0) },
            resolver: visibilityTierResolver
        )
        .filter { visibilityTierResolver.tier(for: $0) == .p0Visible }
        .map(\.uuid)

        for paneId in visiblePaneIds {
            guard let pane = store.paneAtom.pane(paneId) else { continue }
            guard store.tabLayoutAtom.tabContaining(paneId: pane.parentPaneId ?? pane.id)?.id == activeTab.id else {
                continue
            }
            if let placeholder = viewRegistry.terminalStatusPlaceholderView(for: paneId) {
                if placeholder.shouldRetryCreationWhenBoundsChange {
                    return true
                }
                continue
            }
            if viewRegistry.view(for: paneId) == nil {
                return true
            }
        }
        return false
    }
}
