import AgentStudioBridge
import AgentStudioCore
import Foundation
import os.log

/// What an action submitted on a pane agent's behalf reached.
enum WorkspaceScopedActionOutcome: Equatable, Sendable {
    case applied
    case rejected
    /// The own-pane re-check refused the action: a touched pane left the
    /// agent's own pane after authorization. Nothing was applied.
    case outsideOwnPane
}

/// Carries a scoped gesture's outcome out of the serialized gesture, whose
/// own result is only whether it applied.
@MainActor
private final class ScopedActionOutcomeRecord {
    var outcome = WorkspaceScopedActionOutcome.rejected
}

/// Executes validated PaneActions by delegating to `WorkspaceSurfaceCoordinator`.
/// This class remains the app-facing entry point and preserves historical action
/// API semantics while orchestration now lives in `WorkspaceSurfaceCoordinator`.
@MainActor
final class WorkspaceActionExecutor {
    typealias SwitchArrangementTransitions = WorkspaceSurfaceCoordinator.SwitchArrangementTransitions
    private static let logger = Logger(subsystem: "com.agentstudio", category: "WorkspaceActionExecutor")

    private let coordinator: WorkspaceSurfaceCoordinator
    private let store: WorkspaceStore
    private var submittedGestureTail: Task<Bool, Never>?
    private var submittedGestureGeneration: UInt64 = 0
    private var acceptsWorkspaceCommands = true

    init(coordinator: WorkspaceSurfaceCoordinator, store: WorkspaceStore) {
        self.coordinator = coordinator
        self.store = store
        coordinator.workspaceActionSubmission = { [weak self] action in
            // fire-and-forget: coordinator-originated action; stopAcceptingCommandsAndDrain awaits the tail
            _ = self?.submitAction(action)
        }
    }

    private var arrangementView: WorkspaceArrangementViewDerived {
        WorkspaceArrangementViewDerived(
            tabLayoutAtom: store.tabLayoutAtom,
            paneAtom: store.paneAtom,
            managementLayerAtom: atom(\.managementLayer)
        )
    }

    static func computeSwitchArrangementTransitions(
        previousVisiblePaneIds: Set<UUID>,
        previouslyMinimizedPaneIds: Set<UUID>,
        newVisiblePaneIds: Set<UUID>,
        newMinimizedPaneIds: Set<UUID>,
        retainedVisiblePaneIds: Set<UUID> = []
    ) -> SwitchArrangementTransitions {
        WorkspaceSurfaceCoordinator.computeSwitchArrangementTransitions(
            previousVisiblePaneIds: previousVisiblePaneIds,
            previouslyMinimizedPaneIds: previouslyMinimizedPaneIds,
            newVisiblePaneIds: newVisiblePaneIds,
            newMinimizedPaneIds: newMinimizedPaneIds,
            retainedVisiblePaneIds: retainedVisiblePaneIds
        )
    }

    var undoStack: [WorkspaceMutationCoordinator.CloseEntry] {
        coordinator.undoStack
    }

    // MARK: - High-Level Operations

    /// Open a terminal for a worktree. Creates pane + tab + view.
    /// Returns the pane if a new one was created, nil if already open.
    @discardableResult
    func openTerminal(for worktree: Worktree, in repo: Repo) async -> Pane? {
        var createdPane: Pane?
        _ = await submitGesture { [self] _ in
            do {
                createdPane = try await coordinator.openTerminal(for: worktree, in: repo)
                return true
            } catch {
                Self.logger.error("Terminal creation failed before publication")
                return false
            }
        }.value
        return createdPane
    }

    /// Open a new terminal for a worktree, always creating a fresh pane+tab
    /// (never navigates to an existing one).
    @discardableResult
    func openNewTerminal(for worktree: Worktree, in repo: Repo) async -> Pane? {
        var createdPane: Pane?
        _ = await submitGesture { [self] _ in
            do {
                createdPane = try await coordinator.openNewTerminal(for: worktree, in: repo)
                return true
            } catch {
                Self.logger.error("Terminal creation failed before publication")
                return false
            }
        }.value
        return createdPane
    }

    /// Open a new generic GitHub webview pane in a new tab.
    @discardableResult
    func openWebview(url: URL = URL(string: "https://github.com")!) -> Pane? {
        coordinator.openWebview(url: url)
    }

    func resolveBridgePaneCommand(worktreeId: UUID? = nil) -> BridgePaneCommandTarget? {
        coordinator.resolveBridgePaneCommand(worktreeId: worktreeId)
    }

    @discardableResult
    func requestBridgePaneSurface(_ surface: BridgeProductSurface, paneId: UUID) -> Bool {
        coordinator.requestBridgePaneSurface(surface, paneId: paneId)
    }

    @discardableResult
    func reconcileZoomCompanion(
        sourcePaneId: UUID,
        owningTabId: UUID,
        viewerSurfaceRequest: @MainActor (BridgeProductSurface, UUID) -> Bool
    ) -> ZoomViewerPresentation {
        coordinator.reconcileZoomCompanion(
            sourcePaneId: sourcePaneId,
            owningTabId: owningTabId,
            viewerSurfaceRequest: viewerSurfaceRequest
        )
    }

    func refreshZoomCompanionActivities() {
        coordinator.refreshBridgePaneActivities()
    }

    func detachZoomSourceAfterExitIfHidden(
        sourcePaneId: UUID,
        tabId: UUID
    ) {
        guard !arrangementView.activeVisiblePaneIds(forTab: tabId).contains(sourcePaneId) else {
            return
        }
        coordinator.detachForViewSwitch(paneId: sourcePaneId)
    }

    func reattachZoomSourceForPresentationIfHidden(
        sourcePaneId: UUID,
        tabId: UUID
    ) {
        guard !arrangementView.activeVisiblePaneIds(forTab: tabId).contains(sourcePaneId) else {
            return
        }
        coordinator.reattachForViewSwitch(paneId: sourcePaneId)
    }

    /// Open an independent read-only Bridge review pane in a new tab.
    @discardableResult
    func openBridgeReviewInNewTab(worktreeId: UUID? = nil) -> Pane? {
        openBridgeReviewInNewTab(
            worktreeId: worktreeId,
            viewerOpenTelemetryAnchor: nil
        )
    }

    @discardableResult
    func openBridgeReviewInNewTab(
        worktreeId: UUID?,
        viewerOpenTelemetryAnchor: BridgeViewerOpenTelemetryAnchor?
    ) -> Pane? {
        coordinator.openBridgeReviewInNewTab(
            worktreeId: worktreeId,
            viewerOpenTelemetryAnchor: viewerOpenTelemetryAnchor
        )
    }

    /// Open an independent Bridge file-viewer pane in a new tab.
    @discardableResult
    func openBridgeFilesInNewTab(worktreeId: UUID? = nil) -> Pane? {
        openBridgeFilesInNewTab(
            worktreeId: worktreeId,
            viewerOpenTelemetryAnchor: nil
        )
    }

    @discardableResult
    func openBridgeFilesInNewTab(
        worktreeId: UUID?,
        viewerOpenTelemetryAnchor: BridgeViewerOpenTelemetryAnchor?
    ) -> Pane? {
        coordinator.openBridgeFilesInNewTab(
            worktreeId: worktreeId,
            viewerOpenTelemetryAnchor: viewerOpenTelemetryAnchor
        )
    }

    /// Undo the last close operation (tab or pane).
    @discardableResult
    func undoCloseTab() async -> Bool {
        await submitUndoClose().value
    }

    func submitUndoClose() -> Task<Bool, Never> {
        submitGesture { [self] _ in
            do { return try await coordinator.undoCloseTab() } catch {
                Self.logger.error("Undo failed before completion; ownership was preserved")
                return false
            }
        }
    }

    func restoreVisibleViewsForActiveTabIfNeeded(forceWhenBoundsExist: Bool = false) {
        coordinator.restoreViewsForActiveTabIfNeeded(forceWhenBoundsExist: forceWhenBoundsExist)
    }

    func clearPendingPaneRefocusRequestsAfterUserFocusChange() {
        coordinator.clearPendingPaneRefocusRequestsAfterUserFocusChange()
    }

    /// Forwards to the same reevaluation tail the canonical layout-changing
    /// actions call (SPEC R5 retry, R1 hidden hydration): the trusted
    /// container-layout callback in `PaneTabViewController` has no other path
    /// to the coordinator's `reevaluatePreparedTerminalGeometry()`.
    func reevaluatePreparedTerminalGeometry() {
        Task { [weak coordinator] in
            await coordinator?.reevaluatePreparedTerminalGeometry()
        }
    }

    func bindHeldPanePreviewState(_ state: HeldPanePreviewState) {
        coordinator.bindHeldPanePreviewState(state)
    }

    func prepareHeldPanePreview() {
        // fire-and-forget: preparation is synchronous; the deferred geometry reevaluation reports nothing
        _ = coordinator.beginHeldPanePreviewPreparation()
    }

    private func drawerParentByPaneId() -> [UUID: UUID] {
        Dictionary(
            uniqueKeysWithValues: store.paneAtom.paneSnapshot().values.compactMap { pane in
                guard let parentPaneId = pane.parentPaneId else { return nil }
                return (pane.id, parentPaneId)
            }
        )
    }

    private func drawerLayoutByParentPaneId() -> [UUID: DrawerGridLayout] {
        Dictionary(
            uniqueKeysWithValues: store.paneAtom.paneSnapshot().values.compactMap { pane in
                guard pane.drawer != nil, let drawerView = arrangementView.drawerView(forParent: pane.id) else {
                    return nil
                }
                return (pane.id, drawerView.layout)
            }
        )
    }

    /// Validate/canonicalize a WorkspaceActionCommand against current state, then execute it.
    @discardableResult
    func execute(_ action: WorkspaceActionCommand) async -> Bool {
        await submitAction(action).value
    }

    func submitAction(_ action: WorkspaceActionCommand) -> Task<Bool, Never> {
        submitGesture { execute in await execute(action) }
    }

    /// Runs a pane agent's action through the same serialized gesture queue,
    /// re-checking its own-pane assertion inside validation after every queued
    /// predecessor has finished.
    func execute(
        _ action: WorkspaceActionCommand,
        ownPaneAssertion: WorkspaceOwnPaneAssertion
    ) async -> WorkspaceScopedActionOutcome {
        await submitScopedAction(action, ownPaneAssertion: ownPaneAssertion).value
    }

    /// Enqueues synchronously, like `submit(_:)`: the assertion travels with
    /// the action and is evaluated only when the gesture runs.
    func submitScopedAction(
        _ action: WorkspaceActionCommand,
        ownPaneAssertion: WorkspaceOwnPaneAssertion
    ) -> Task<WorkspaceScopedActionOutcome, Never> {
        let recorded = ScopedActionOutcomeRecord()
        let gesture = submitGesture { [self] _ in
            recorded.outcome = await executeValidatedAction(action, ownPaneAssertion: ownPaneAssertion)
            return recorded.outcome == .applied
        }
        return Task { @MainActor in
            _ = await gesture.value
            return recorded.outcome
        }
    }

    /// One admitted user operation includes resolution and dependent effects, not just its first mutation.
    func submitGesture(
        _ operation: @escaping @MainActor (@MainActor (WorkspaceActionCommand) async -> Bool) async -> Bool
    ) -> Task<Bool, Never> {
        guard acceptsWorkspaceCommands else { return Task { false } }
        let predecessor = submittedGestureTail
        submittedGestureGeneration &+= 1
        let generation = submittedGestureGeneration
        let task = Task { @MainActor [self] in
            _ = await predecessor?.value
            let result = await operation { [self] action in
                await executeValidatedAction(action, ownPaneAssertion: nil) == .applied
            }
            if submittedGestureGeneration == generation { submittedGestureTail = nil }
            return result
        }
        submittedGestureTail = task
        return task
    }

    /// Shutdown waits for accepted work; callers must use their own submission for a command result.
    func stopAcceptingCommandsAndDrain() async {
        acceptsWorkspaceCommands = false
        _ = await submittedGestureTail?.value
    }

    private func executeValidatedAction(
        _ action: WorkspaceActionCommand,
        ownPaneAssertion: WorkspaceOwnPaneAssertion?
    ) async -> WorkspaceScopedActionOutcome {
        let tabLayout = store.tabLayoutAtom
        let repositoryTopology = store.repositoryTopologyAtom
        let snapshot = WorkspaceCommandResolver.snapshot(
            from: tabLayout.tabs,
            activeTabId: tabLayout.activeTabId,
            isManagementLayerActive: atom(\.managementLayer).isActive,
            zoomSourcePaneIdByTabId: store.panePresentationAtom.zoomPresentationsByTabId.mapValues(
                \.sourcePaneId
            ),
            knownRepoIds: Set(repositoryTopology.repos.map(\.id)),
            knownWorktreeIds: repositoryTopology.availableWorktreeIDs,
            knownPaneIds: store.paneAtom.graphAtom.paneIDs,
            drawerParentByPaneId: drawerParentByPaneId(),
            drawerLayoutByParentPaneId: drawerLayoutByParentPaneId(),
            visiblePaneIds: { [arrangementView] tab in
                arrangementView.activeVisiblePaneIds(forTab: tab.id)
            }
        )
        switch WorkspaceCommandValidator.validate(action, ownPaneAssertion: ownPaneAssertion, state: snapshot) {
        case .success(let validated):
            do {
                try await coordinator.execute(validated.action)
                return .applied
            } catch {
                Self.logger.error("Workspace action failed before completion")
                return .rejected
            }
        case .failure(let error):
            Self.logger.warning(
                "Action rejected: \(String(describing: action), privacy: .public) reason=\(String(describing: error), privacy: .public)"
            )
            if case .outsideOwnPane = error { return .outsideOwnPane }
            return .rejected
        }
    }

}
