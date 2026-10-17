import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import Foundation
import Observation
import SwiftUI

package typealias BridgeAttendanceSnapshot =
    @MainActor (UUID) -> UInt64?
package typealias LatestPaneMessageSnapshot =
    @MainActor (UUID) -> PaneActivityStatusFact?

enum RepoExplorerSidebarShortcutPresentation {
    static func display(for command: AppCommand, showsListKeyboardHints: Bool) -> ShortcutDisplayText? {
        guard showsListKeyboardHints else { return nil }
        return command.definition.shortcut?.spec.displayTrigger(in: .sidebarList)?.displayText
    }
}

/// Sidebar chrome and interaction wiring around the persistent native presentation host.
@MainActor
package struct RepoExplorerView: View {
    typealias SidebarProjection = RepoExplorerSidebarProjection

    let store: WorkspaceStore
    let octiconLoader: OcticonLoader
    let repoExplorerPrefs: RepoExplorerSidebarPrefsAtom
    let isProjectionDemanded: Bool
    let bridgeAttendanceSnapshot: BridgeAttendanceSnapshot
    let paneContextControl: RepoExplorerPaneContextControlFactory
    let latestPaneMessageSnapshot: LatestPaneMessageSnapshot
    let commandDispatcher: any AppCommandDispatching
    let commandPresentationDelta: RepoExplorerCommandPresentationDelta?
    let visibleSnapshotConsumerToken: UUID?
    let onRefocusActivePane: () -> Void
    let onSelectedPaneTargetChange:
        @MainActor (RepoExplorerSelectedPaneTarget?, RepoExplorerSelectedPaneTargetChangeOrigin) -> Void
    let onPreviewEligibilityLoss: @MainActor () -> Void
    let onPreviewCommit: @MainActor () -> Void
    let onSidebarVisibleWorktreesChanged: @MainActor @Sendable () -> Void
    let onVisibleWorktreeSnapshotChanged: @MainActor @Sendable (RepoExplorerVisibleWorktreeSnapshot) -> Void
    let onPerformanceProofReadback: @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    let installSystemTimeInvalidationHandler: (@escaping @MainActor @Sendable () -> Void) -> Void
    let removeSystemTimeInvalidationHandler: () -> Void
    let initialProjectionSequence: Int
    let onInitialProjectionApplied: @MainActor (Int) -> Void

    static let groupHeaderChromePolicy = SidebarRepoGroupHeader<EmptyView>.chromePolicy
    static let headerLayoutPolicy = SidebarHeaderLayout<EmptyView, EmptyView, EmptyView, EmptyView>.policy

    package init(
        store: WorkspaceStore,
        octiconLoader: OcticonLoader,
        repoExplorerPrefs: RepoExplorerSidebarPrefsAtom,
        isProjectionDemanded: Bool = true,
        bridgeAttendanceSnapshot: @escaping BridgeAttendanceSnapshot,
        commandDispatcher: any AppCommandDispatching,
        commandPresentationDelta: RepoExplorerCommandPresentationDelta? = nil,
        visibleSnapshotConsumerToken: UUID? = nil,
        onRefocusActivePane: @escaping () -> Void,
        onSelectedPaneTargetChange:
            @escaping @MainActor (
                RepoExplorerSelectedPaneTarget?, RepoExplorerSelectedPaneTargetChangeOrigin
            ) -> Void = { _, _ in },
        onPreviewEligibilityLoss: @escaping @MainActor () -> Void = {},
        onPreviewCommit: @escaping @MainActor () -> Void = {},
        onSidebarVisibleWorktreesChanged: @escaping @MainActor @Sendable () -> Void,
        onVisibleWorktreeSnapshotChanged:
            @escaping @MainActor @Sendable (RepoExplorerVisibleWorktreeSnapshot) -> Void = { _ in },
        onPerformanceProofReadback:
            @escaping @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void = { _ in },
        paneContextControl: @escaping RepoExplorerPaneContextControlFactory = { _, _ in nil },
        latestPaneMessageSnapshot: @escaping LatestPaneMessageSnapshot = { _ in nil },
        sessionStatusForPane: @escaping RepoExplorerSessionStatusReader = { _ in nil },
        contextDisplayForPane: @escaping RepoExplorerContextDisplayReader = { _ in nil },
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        recencyNow: @escaping @MainActor @Sendable () -> Date = Date.init,
        recencyDelay: AsyncDelay = .taskSleep,
        initialProjectionTrigger: String = AppPolicies.SidebarProjection.Trigger.startupDiagnostic.rawValue,
        initialProjectionSequence: Int = 0,
        installSystemTimeInvalidationHandler: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { _ in },
        removeSystemTimeInvalidationHandler: @escaping () -> Void = {},
        onInitialProjectionApplied: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        let resolvedInitialProjectionTrigger =
            AppPolicies.SidebarProjection.Trigger(rawValue: initialProjectionTrigger) ?? .startupDiagnostic
        self.store = store
        self.octiconLoader = octiconLoader
        self.repoExplorerPrefs = repoExplorerPrefs
        self.isProjectionDemanded = isProjectionDemanded
        self.bridgeAttendanceSnapshot = bridgeAttendanceSnapshot
        self.commandDispatcher = commandDispatcher
        self.commandPresentationDelta = commandPresentationDelta
        self.visibleSnapshotConsumerToken = visibleSnapshotConsumerToken
        self.onRefocusActivePane = onRefocusActivePane
        self.onSelectedPaneTargetChange = onSelectedPaneTargetChange
        self.onPreviewEligibilityLoss = onPreviewEligibilityLoss
        self.onPreviewCommit = onPreviewCommit
        self.onSidebarVisibleWorktreesChanged = onSidebarVisibleWorktreesChanged
        self.onVisibleWorktreeSnapshotChanged = onVisibleWorktreeSnapshotChanged
        self.onPerformanceProofReadback = onPerformanceProofReadback
        self.paneContextControl = paneContextControl
        self.latestPaneMessageSnapshot = latestPaneMessageSnapshot
        self.performanceTraceRecorder = performanceTraceRecorder
        _projectionAdapter = State(
            initialValue: RepoExplorerProjectionAdapter(
                inputCapture: RepoExplorerProjectionInputCapture(
                    store: store,
                    preferences: repoExplorerPrefs,
                    repoCache: atom(\.repoCache),
                    sidebarState: atom(\.workspaceSidebarState),
                    sidebarCache: atom(\.sidebarCache),
                    coreAtoms: CoreAtomScope.store,
                    bridgeAttendanceSnapshot: bridgeAttendanceSnapshot,
                    latestPaneMessageSnapshot: latestPaneMessageSnapshot,
                    sessionStatusForPane: sessionStatusForPane,
                    contextDisplayForPane: contextDisplayForPane
                ),
                performanceTraceRecorder: performanceTraceRecorder,
                recencyNow: recencyNow,
                recencyDelay: recencyDelay,
                initialProjectionTrigger: resolvedInitialProjectionTrigger
            )
        )
        self.installSystemTimeInvalidationHandler = installSystemTimeInvalidationHandler
        self.removeSystemTimeInvalidationHandler = removeSystemTimeInvalidationHandler
        self.initialProjectionSequence = initialProjectionSequence
        self.onInitialProjectionApplied = onInitialProjectionApplied
    }

    private var uiState: WorkspaceSidebarState {
        atom(\.workspaceSidebarState)
    }

    private var sidebarCache: SidebarCacheState {
        atom(\.sidebarCache)
    }

    @State var openOrganizationSelector: RepoExplorerOrganizationSelector?
    @State private var filterText = ""
    @State private var hasReportedInitialProjection = false
    @FocusState private var focusedField: RepoExplorerFocus?
    @State private var projectionAdapter: RepoExplorerProjectionAdapter
    @State private var keyboardInteraction = RepoExplorerKeyboardInteraction()

    var commandPresentationSnapshot: RepoExplorerCommandPresentationSnapshot {
        commandPresentationDelta?.snapshot ?? .empty
    }

    var showsListKeyboardHints: Bool {
        keyboardInteraction.isListKeyboardActive
    }

    func sidebarShortcutDisplay(for command: AppCommand) -> ShortcutDisplayText? {
        RepoExplorerSidebarShortcutPresentation.display(
            for: command,
            showsListKeyboardHints: showsListKeyboardHints
        )
    }

    package var body: some View {
        VStack(spacing: 0) {
            filterBar

            RepoExplorerPresentationHostView(
                projectionAdapter: projectionAdapter,
                octiconLoader: octiconLoader,
                commandPresentationDelta: commandPresentationDelta,
                visibleSnapshotConsumerToken: visibleSnapshotConsumerToken,
                interactions: tableInteractions,
                keyboardInteraction: keyboardInteraction,
                keyboardCallbacks: keyboardCallbacks,
                showsKeyboardHints: showsListKeyboardHints,
                onVisibleWorktreeSnapshotChange: updateSidebarVisibleWorktrees,
                observeCurrentVisibleTarget: onVisibleWorktreeSnapshotChanged
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.15), value: uiState.isFilterVisible)
        .task {
            installSystemTimeInvalidationHandler { [weak invalidatedAdapter = projectionAdapter] in
                invalidatedAdapter?.handleSystemTimeInvalidation()
            }
            filterText = uiState.filterText
            projectionAdapter.updateDemand(
                isVisible: isProjectionDemanded,
                query: uiState.filterText
            )
        }
        .onDisappear {
            removeSystemTimeInvalidationHandler()
            projectionAdapter.stop()
            clearSidebarVisibleWorktrees()
            keyboardInteraction.clearFocusReporting()
        }

        .onChange(of: filterText) { _, newValue in
            uiState.setFilterText(newValue)

            projectionAdapter.updateDemand(
                isVisible: isProjectionDemanded,
                query: filterText
            )
        }
        .onChange(of: projectionAdapter.publishedResult) { _, result in
            guard let result else { return }
            recordProjectionResult(result)
        }
        .onChange(of: isProjectionDemanded) { _, isDemanded in
            if !isDemanded {
                focusedField = nil
                keyboardInteraction.clearFocusReporting()
            }
            projectionAdapter.updateDemand(
                isVisible: isDemanded,
                query: filterText
            )
            recordPerformanceProofReadback()
        }
        .onChange(of: focusedField) { _, newValue in
            guard newValue == focusedField else { return }
            keyboardInteraction.filterFocusDidChange(isFocused: newValue == .filter)
            recordPerformanceProofReadback()
        }
    }

    private var filterBar: some View {
        SidebarHeaderLayout {
            HStack(spacing: AppStyles.General.Spacing.tight) {
                sidebarSurfaceSelector
                SidebarToolbarDivider()
                SidebarSearchField(
                    placeholder: "Filter...",
                    text: $filterText,
                    focusedField: $focusedField,
                    focusValue: .filter,
                    clearHelp: LocalActionSpec.clearFilter.actionSpec.helpText,
                    shortcutDisplay: sidebarShortcutDisplay(for: .filterSidebar),
                    onSubmit: focusListAfterFilter,
                    onExit: focusListAfterFilter,
                    onDownArrow: {
                        focusListAfterFilter()
                        return .handled
                    }
                )
            }
        } toolbarRow: {
            repoToolbarRow
        } statusRow: {
            EmptyView()
        }
    }

    private var tableInteractions: RepoExplorerTableInteractions {
        RepoExplorerTableInteractions(
            onCommandRequest: dispatchTableCommand,
            onToggleGroup: toggleGroupExpansion,
            onFocusPane: focusPane,
            paneContextControl: paneContextControl,
            onSetGroupExpanded: setGroupExpansion,
            onOpenPaneInEditor: { paneId, editorId in
                guard let directory = store.paneAtom.pane(paneId)?.metadata.cwd else { return }
                _ = ExternalWorkspaceOpener.openInEditor(id: editorId, path: directory)
            }
        )
    }

    private func dispatchTableCommand(_ request: RepoExplorerCommandPresentationRequest) {
        switch request.arguments {
        case .noArguments:
            if let target = request.target, let targetType = request.targetType {
                commandDispatcher.dispatch(request.command, target: target, targetType: targetType)
            } else {
                commandDispatcher.dispatch(request.command)
            }
        }
    }

    private func toggleGroupExpansion(_ groupID: String) {
        let key = SidebarGroupKey(groupID)
        setGroupExpansion(groupID, isExpanded: sidebarCache.collapsedGroups.contains(key))
    }

    private func setGroupExpansion(_ groupID: String, isExpanded: Bool) {
        guard projectionAdapter.publishedResult?.rowIndex.isFiltering != true else { return }
        sidebarCache.setGroupExpanded(SidebarGroupKey(groupID), isExpanded: isExpanded)
    }

    private func focusListAfterFilter() {
        keyboardInteraction.requestListFocus()
    }

    private var keyboardCallbacks: RepoExplorerKeyboardCallbacks {
        RepoExplorerKeyboardCallbacks(
            canInterpretListInput: {
                let coreAtoms = CoreAtomScope.store
                let context = KeyboardRoutingContext.current(
                    windowLifecycle: coreAtoms.windowLifecycle,
                    managementLayer: coreAtoms.managementLayer,
                    uiState: uiState,
                    commandBarSurface: coreAtoms.commandBarSurface,
                    transientKeyboardSurface: coreAtoms.transientKeyboardSurface
                )
                return isProjectionDemanded && openOrganizationSelector == nil && context.isStableSidebar
            },
            onSelectedPaneTargetChange: onSelectedPaneTargetChange,
            onPreviewEligibilityLoss: onPreviewEligibilityLoss,
            onPreviewCommit: onPreviewCommit,
            onFilterFocusRequest: { focusedField = .filter },
            onReturnFocusRequest: onRefocusActivePane,
            onSidebarFocusChange: { hasFocus in
                guard uiState.sidebarHasFocus != hasFocus else { return }
                uiState.setSidebarHasFocus(hasFocus)
            },
            onCommandRequest: { command in
                guard commandDispatcher.canDispatch(command) else { return false }
                return commandDispatcher.dispatch(command)
            }
        )
    }

    private func recordProjectionResult(_ result: RepoExplorerProjectionResult) {
        RepoExplorerPerformanceTelemetry.shared.record(
            stage: "mainactor_apply",
            outcome: "published"
        )
        recordPerformanceProofReadback()
        performanceTraceRecorder?.recordDuration(
            .sidebarProjection,
            duration: result.projectionDuration,
            attributes: sidebarProjectionTraceAttributes(
                for: projectionRequest(for: result),
                phase: "projection_worker",
                extra: [
                    "agentstudio.performance.sidebar.total_worker_elapsed_ms": .double(
                        AgentStudioPerformanceTraceRecorder.milliseconds(from: result.workerDuration)
                    ),
                    "agentstudio.performance.sidebar.group.count": .int(
                        result.projection.resolvedGroups.count
                    ),
                ]
            )
        )
        performanceTraceRecorder?.recordDuration(
            .sidebarRowIndex,
            duration: result.rowIndexDuration,
            attributes: sidebarProjectionTraceAttributes(
                for: projectionRequest(for: result),
                phase: "row_index",
                extra: [
                    "agentstudio.performance.sidebar.row_index_elapsed_ms": .double(
                        AgentStudioPerformanceTraceRecorder.milliseconds(from: result.rowIndexDuration)
                    )
                ]
            )
        )
        guard
            Self.shouldReportInitialProjection(
                hasReportedInitialProjection: hasReportedInitialProjection
            ), projectionAdapter.materializationHost?.isPresentationReady == true,
            projectionAdapter.acknowledgedMaterializationBaseline != nil
        else { return }
        hasReportedInitialProjection = true
        onInitialProjectionApplied(initialProjectionSequence)
    }

    private func recordPerformanceProofReadback() {
        guard
            let readback = projectionAdapter.performanceProofReadback(
                focusDisposition: focusedField == .filter ? .filterFocused : .notFocused
            )
        else { return }
        onPerformanceProofReadback(readback)
        performanceTraceRecorder?.record(
            .sidebarProjection,
            attributes: [
                "agentstudio.performance.sidebar.readback.semantic_generation": .int(
                    readback.semanticGeneration
                ),
                "agentstudio.performance.sidebar.readback.acknowledged_revision": .int(
                    Int(readback.acknowledgedRevision)
                ),
                "agentstudio.performance.sidebar.readback.visible_generation": .int(
                    Int(readback.visibleGeneration)
                ),
                "agentstudio.performance.sidebar.readback.represented_row_count": .int(
                    readback.representedRowCount
                ),
                "agentstudio.performance.sidebar.readback.materialization_fingerprint": .int(
                    Int(bitPattern: UInt(readback.materializationFingerprint))
                ),
                "agentstudio.performance.sidebar.readback.grouping_mode": .string(
                    readback.groupingMode.rawValue
                ),
                "agentstudio.performance.sidebar.readback.query_state": .string(
                    readback.queryIsEmpty ? "empty" : "non_empty"
                ),
                "agentstudio.performance.sidebar.readback.demand_state": .string(
                    readback.isDemanded ? "demanded" : "hidden"
                ),
                "agentstudio.performance.sidebar.readback.presentation_state": .string(
                    readback.presentationIsReady ? "ready" : "unavailable"
                ),
                "agentstudio.performance.sidebar.readback.focus_disposition": .string(
                    readback.focusDisposition.rawValue
                ),
                "agentstudio.performance.sidebar.readback.accessibility_disposition": .string(
                    readback.accessibilityDisposition.rawValue
                ),
            ]
        )
    }

    private func projectionRequest(
        for result: RepoExplorerProjectionResult
    ) -> RepoExplorerProjectionRequest {
        RepoExplorerProjectionRequest(
            generation: result.generation,
            snapshot: result.snapshot,
            collapsedGroupIds: result.collapsedGroupIds,
            isFiltering: result.isFiltering,
            trigger: result.trigger
        )
    }

    package static var sectionHeaderLeadingInset: CGFloat {
        AppStyles.Shell.Sidebar.listRowLeadingInset
    }

    static func checkoutIconKind(
        for worktree: Worktree,
        in repo: RepoPresentationItem
    ) -> RepoExplorerCheckoutIconKind {
        let isMainCheckout =
            worktree.isMainWorktree
            || worktree.path.standardizedFileURL.path == repo.repoPath.standardizedFileURL.path
        return isMainCheckout ? .mainCheckout : .gitWorktree
    }
}
