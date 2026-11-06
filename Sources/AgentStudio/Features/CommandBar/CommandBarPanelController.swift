import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import AppKit
import Dispatch
import SwiftUI
import os.log

private let controllerLogger = Logger(subsystem: "com.agentstudio", category: "CommandBarPanelController")

// MARK: - CommandBarPanelController

/// Manages the command bar panel lifecycle: show, dismiss, animate, backdrop.
/// Owns the CommandBarState and wires it to the panel.
/// All methods must be called on the main thread (enforced by AppKit caller context).
@MainActor
package final class CommandBarPanelController {

    // MARK: - State

    package let state: CommandBarState

    // MARK: - Dependencies

    let store: WorkspaceStore
    private let octiconLoader: OcticonLoader
    let repoCache: RepoCacheAtom
    let dispatcher: any AppCommandDispatching
    private let targetedSpecResolver: CommandBarTargetedSpecResolver
    private let quickOpenDirectoryHandler: @MainActor @Sendable (URL, QuickOpenDirectoryPlacement) -> Void
    private let notificationInboxCommands: InboxNotificationCommands?
    private let commandBarSurface: CommandBarSurfaceAtom
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    let searchNowNanoseconds: @Sendable () -> UInt64
    private let interactionProbe: AgentStudioInteractionPerformanceProbe?
    private let animatePanelDismissal: Bool
    let worktreeForkEligibility: (any WorktreeForkEligibilityChecking)?
    let defaultStartPointResolver: (any WorktreeDefaultStartPointResolving)?
    let branchListing: (any WorktreeBranchListing)?
    var forkEligibilityQueriesBySourceWorktreeId: [UUID: InFlightForkEligibilityQuery] = [:]
    var defaultStartPointQueriesByRepositoryId: [UUID: InFlightDefaultStartPointQuery] = [:]
    var branchListingQueriesByRepositoryId: [UUID: InFlightBranchListingQuery] = [:]
    let resultSession: CommandBarResultSession
    let searchService: any SearchServicing
    var searchSequence: UInt64 = 0
    var pendingSearchTask: Task<Void, Never>?
    var pendingGenerationInstallTask: Task<Void, Never>?
    var scheduledInstallGeneration: SearchDocumentGeneration?
    var lastResubmittedGeneration: SearchDocumentGeneration?
    var currentSearchMeasurement: CommandBarSearchMeasurement?
    var lastAcknowledgedPublication: CommandBarPublicationIdentity?

    /// The open-in-current-tab capability every worktree level is first built with, read
    /// directly: an async answer must not rebuild the result snapshot or move the selection.
    var canOpenWorktreeInCurrentTab: Bool {
        resultSession.canOpenWorktreeInCurrentTab()
    }
    private var activationGenerationGate = CommandBarActivationGenerationGate()
    private var pendingOpenAcknowledgement: PendingOpenAcknowledgement?

    private struct PendingOpenAcknowledgement {
        let correlationId: UUID
        var inputFocusAcknowledged = false
        var initialResultsPublished = false
    }

    // MARK: - Panel

    private var panel: CommandBarPanel?
    private var backdropView: CommandBarBackdropView?

    /// The parent window the command bar is attached to.
    private weak var parentWindow: NSWindow?
    private var workspaceWindowId: UUID?

    package var isKeyWindow: Bool {
        panel?.isKeyWindow == true
    }

    // MARK: - Initialization

    package init(
        store: WorkspaceStore,
        octiconLoader: OcticonLoader,
        repoCache: RepoCacheAtom,
        dispatcher: any AppCommandDispatching,
        targetedSpecResolver: @escaping CommandBarTargetedSpecResolver =
            CommandBarCommandPresentation.catalogTargetedSpecResolver,
        quickOpenDirectoryHandler:
            @escaping @MainActor @Sendable (URL, QuickOpenDirectoryPlacement) -> Void,
        notificationInboxCommands: InboxNotificationCommands? = nil,
        commandBarSurface: CommandBarSurfaceAtom,
        searchService: any SearchServicing = SearchService(),
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        searchNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        interactionProbe: AgentStudioInteractionPerformanceProbe? = nil,
        animatePanelDismissal: Bool = true,
        recentsDefaults: UserDefaults = AppStorageIdentity.current.userDefaults,
        worktreeForkEligibility: (any WorktreeForkEligibilityChecking)? = nil,
        defaultStartPointResolver: (any WorktreeDefaultStartPointResolving)? = nil,
        branchListing: (any WorktreeBranchListing)? = nil
    ) {
        self.state = CommandBarState(defaults: recentsDefaults)
        self.store = store
        self.octiconLoader = octiconLoader
        self.repoCache = repoCache
        self.dispatcher = dispatcher
        self.targetedSpecResolver = targetedSpecResolver
        self.quickOpenDirectoryHandler = quickOpenDirectoryHandler
        self.notificationInboxCommands = notificationInboxCommands
        self.commandBarSurface = commandBarSurface
        self.searchService = searchService
        self.performanceTraceRecorder = performanceTraceRecorder
        self.searchNowNanoseconds = searchNowNanoseconds
        self.interactionProbe =
            interactionProbe
            ?? performanceTraceRecorder.map {
                AgentStudioInteractionPerformanceProbe(recorder: $0)
            }
        self.animatePanelDismissal = animatePanelDismissal
        self.worktreeForkEligibility = worktreeForkEligibility
        self.defaultStartPointResolver = defaultStartPointResolver
        self.branchListing = branchListing
        self.resultSession = CommandBarResultSession(
            store: store,
            repoCache: repoCache,
            dispatcher: dispatcher,
            notificationInboxCommands: notificationInboxCommands,
            performanceTraceRecorder: performanceTraceRecorder
        )
        state.loadRecents()
    }

    // MARK: - Show / Dismiss

    /// Show the command bar. If already visible with a different prefix, switch in-place.
    /// If already visible with the same prefix (or no prefix), preserve current state.
    package func show(parentWindow: NSWindow, workspaceWindowId: UUID? = nil) {
        show(mode: .defaultScope(.everything), parentWindow: parentWindow, workspaceWindowId: workspaceWindowId)
    }

    package func show(prefix: String, parentWindow: NSWindow, workspaceWindowId: UUID? = nil) {
        show(mode: .prefix(prefix), parentWindow: parentWindow, workspaceWindowId: workspaceWindowId)
    }

    package func show(defaultRootScope: CommandBarScope, parentWindow: NSWindow, workspaceWindowId: UUID? = nil) {
        show(mode: .defaultScope(defaultRootScope), parentWindow: parentWindow, workspaceWindowId: workspaceWindowId)
    }

    private func show(
        mode: CommandBarState.OpenMode,
        parentWindow: NSWindow,
        workspaceWindowId requestedWorkspaceWindowId: UUID?
    ) {
        let resolvedWorkspaceWindowId = requestedWorkspaceWindowId ?? workspaceWindowId
        if resolvedWorkspaceWindowId == nil {
            controllerLogger.warning(
                "Command bar shown without a workspace window id; keyboard surface routing disabled")
        }
        self.parentWindow = parentWindow
        workspaceWindowId = resolvedWorkspaceWindowId

        if state.isVisible {
            let isSameOpening: Bool =
                switch mode {
                case .prefix(let prefix):
                    normalizedPrefix(for: state.currentScope) == normalizedPrefix(for: prefix)
                case .defaultScope(let scope):
                    state.activePrefix == nil && state.currentScope == scope
                }

            if isSameOpening {
                publishCurrentSurface()
                movePanel(to: parentWindow)
                return
            } else {
                switch mode {
                case .prefix(let prefix):
                    state.switchPrefix(prefix)
                case .defaultScope:
                    state.show(defaultScope: defaultRootScope(for: mode))
                }
                resultSession.navigationChanged()
                state.appliedSearchResult = nil
                queryChanged(text: state.rawInput)
                publishCurrentSurface()
                movePanel(to: parentWindow)
                return
            }
        }

        let openCorrelationId = UUIDv7.generate()
        interactionProbe?.beginInteraction(.commandBarOpen, correlationId: openCorrelationId)
        pendingOpenAcknowledgement = PendingOpenAcknowledgement(correlationId: openCorrelationId)

        // Create panel and backdrop
        switch mode {
        case .prefix(let prefix):
            state.show(prefix: prefix)
        case .defaultScope(let defaultRootScope):
            state.show(defaultScope: defaultRootScope)
        }
        resultSession.navigationChanged()
        state.appliedSearchResult = nil
        queryChanged(text: state.rawInput)
        publishCurrentSurface()
        presentPanel(parentWindow: parentWindow)
    }

    /// Dismiss the command bar and clean up.
    package func dismiss() {
        dismiss(measureNonExecutingClose: true)
    }

    private func dismiss(measureNonExecutingClose: Bool) {
        guard state.isVisible else { return }

        if let acknowledgement = pendingOpenAcknowledgement {
            interactionProbe?.cancelInteraction(correlationId: acknowledgement.correlationId)
        }
        pendingOpenAcknowledgement = nil
        let closeCorrelationId: UUID? =
            if measureNonExecutingClose {
                UUIDv7.generate()
            } else {
                nil
            }
        if let closeCorrelationId {
            interactionProbe?.beginInteraction(.commandBarClose, correlationId: closeCorrelationId)
        }

        activationGenerationGate.invalidate()
        recordSupersededSearch(at: searchNowNanoseconds())
        searchSequence += 1
        pendingSearchTask?.cancel()
        pendingSearchTask = nil
        state.dismiss()
        state.appliedSearchResult = nil
        resultSession.navigationChanged()
        commandBarSurface.dismiss(workspaceWindowId: workspaceWindowId)
        dismissPanel { [weak self] in
            guard let self, let closeCorrelationId else { return }
            self.interactionProbe?.settleInteraction(correlationId: closeCorrelationId)
        }
        workspaceWindowId = nil
    }

    private func publishCurrentSurface() {
        guard let workspaceWindowId else { return }
        commandBarSurface.present(scope: state.currentScope, workspaceWindowId: workspaceWindowId)
    }

    // MARK: - Panel Presentation

    private func presentPanel(parentWindow: NSWindow) {
        let panel = CommandBarPanel()
        self.panel = panel

        // Wire Escape key through controller dismiss lifecycle
        panel.onDismiss = { [weak self] in
            self?.dismiss()
        }
        // The panel is the primary shortcut ingress because performKeyEquivalent
        // fires before menu handling while the command bar is key. The view/text
        // field also receives this closure as a fallback for selector-driven
        // NSTextField command paths like modified Enter.
        panel.onShortcutTrigger = { [weak self] trigger in
            guard let self else { return false }
            return self.handleShortcutTrigger(trigger)
        }

        // Set SwiftUI content
        let contentView = CommandBarView(
            state: state,
            octiconLoader: octiconLoader,
            resultSession: resultSession,
            onShortcutTrigger: { [weak self] trigger in
                self?.handleShortcutTrigger(trigger) ?? false
            },
            onExecuteItem: { [weak self] item, modifier in
                self?.executeItem(item, modifier: modifier)
            },
            onShowActions: { [weak self] item in
                self?.showActions(for: item)
            },
            onInitialResultsPublished: { [weak self] in
                self?.acknowledgeInitialResultsPublished()
            },
            onInputFocusAcknowledged: { [weak self] in
                self?.acknowledgeInputFocus()
            },
            onInputChanged: { [weak self] text, inputAtNanoseconds in
                self?.queryChanged(text: text, inputAtNanoseconds: inputAtNanoseconds)
            },
            onSearchContextChanged: { [weak self] in
                self?.searchContextChanged()
            },
            onResultPublished: { [weak self] sequence, generation in
                self?.acknowledgeResultPublished(sequence: sequence, generation: generation)
            }
        )
        panel.setContent(contentView)

        // Add as child window
        parentWindow.addChildWindow(panel, ordered: .above)

        // Position panel
        panel.positionRelativeTo(parentWindow: parentWindow)

        // Initial size — will be updated by content
        panel.updateHeight(parentWindow: parentWindow)

        // Show backdrop
        showBackdrop(on: parentWindow)

        // Animate in
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        })

        controllerLogger.debug("Command bar panel presented")
    }

    private func acknowledgeInitialResultsPublished() {
        pendingOpenAcknowledgement?.initialResultsPublished = true
        settleOpenIfAcknowledged()
    }

    private func acknowledgeInputFocus() {
        pendingOpenAcknowledgement?.inputFocusAcknowledged = true
        settleOpenIfAcknowledged()
    }

    private func settleOpenIfAcknowledged() {
        guard
            let acknowledgement = pendingOpenAcknowledgement,
            acknowledgement.initialResultsPublished,
            acknowledgement.inputFocusAcknowledged
        else { return }
        pendingOpenAcknowledgement = nil
        interactionProbe?.settleInteraction(correlationId: acknowledgement.correlationId)
    }

    private func movePanel(to parentWindow: NSWindow) {
        guard let panel else { return }

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
            backdropView?.removeFromSuperview()
            backdropView = nil
            showBackdrop(on: parentWindow)
        }

        panel.positionRelativeTo(parentWindow: parentWindow)
        panel.updateHeight(parentWindow: parentWindow)
        panel.makeKeyAndOrderFront(nil)
    }

    private func handleShortcutTrigger(_ trigger: ShortcutTrigger) -> Bool {
        let resultSnapshot = resultSession.snapshot(state: state)
        switch CommandBarShortcutRouter.route(
            trigger: trigger,
            selectedItem: resultSnapshot.selectedItem,
            displayedItems: resultSnapshot.displayedItems
        ) {
        case .dismiss:
            dismiss()
            return true
        case .showScope(let scope):
            guard let parentWindow else { return false }
            show(
                defaultRootScope: scope,
                parentWindow: parentWindow,
                workspaceWindowId: workspaceWindowId
            )
            return true
        case .showPrefix(let prefix):
            guard let parentWindow else { return false }
            if let prefix {
                show(prefix: prefix, parentWindow: parentWindow, workspaceWindowId: workspaceWindowId)
            } else {
                show(parentWindow: parentWindow, workspaceWindowId: workspaceWindowId)
            }
            return true
        case .executeRow(let item):
            executeItem(item)
            return true
        case .executeSelected(let modifier):
            guard let selectedItem = resultSnapshot.selectedItem else { return false }
            executeItem(selectedItem, modifier: modifier)
            return true
        case .unhandled:
            return false
        }
    }

    private func defaultRootScope(for mode: CommandBarState.OpenMode) -> CommandBarScope {
        switch mode {
        case .prefix:
            return .everything
        case .defaultScope(let scope):
            return scope
        }
    }

    func executeItem(_ item: CommandBarItem, modifier: EnterModifier = .plain) {
        guard item.isEnabled else { return }
        switch item.action {
        case .dispatch(let command):
            guard dispatcher.canDispatch(command) else { return }
            state.recordRecent(itemId: item.id)
            recordRecentCommandIfNeeded(command)
            dismiss(measureNonExecutingClose: false)
            dispatcher.dispatch(command)
        case .dispatchTargeted(let command, let target, let targetType):
            guard dispatcher.canDispatch(command, target: target, targetType: targetType) else {
                return
            }
            state.recordRecent(itemId: item.id)
            recordRecentCommandIfNeeded(command)
            dismiss(measureNonExecutingClose: false)
            dispatcher.dispatch(command, target: target, targetType: targetType)
        case .navigate(let level):
            state.pushLevel(level)
            searchContextChanged()
            requestCreationQueriesIfNeeded(for: level)
        case .navigateRepo(let repositoryID):
            guard
                let repository = store.repositoryTopologyAtom.repo(repositoryID),
                !store.repositoryTopologyAtom.isRepoUnavailable(repositoryID)
            else { return }
            state.pushLevel(
                CommandBarDataSource.buildRepoLevel(
                    repo: repository,
                    store: store,
                    repoCache: repoCache,
                    dispatcher: dispatcher
                )
            )
            searchContextChanged()
        case .custom(let closure):
            state.recordRecent(itemId: item.id)
            dismiss(measureNonExecutingClose: false)
            closure()
        case .worktreeAction(let presence):
            guard
                store.repositoryTopologyAtom.validatedAssociation(
                    repoId: presence.repoId, worktreeId: presence.worktreeId
                ) != nil
            else { return }
            let canOpenWorktreeInCurrentTab = resultSession.snapshot(state: state).canOpenWorktreeInCurrentTab
            executeResolvedWorktreeAction(
                resolution: CommandBarWorktreeActionResolver.resolve(
                    presence: presence,
                    modifier: modifier,
                    canOpenInCurrentTab: canOpenWorktreeInCurrentTab,
                    targetedSpecResolver: targetedSpecResolver
                ),
                presence: presence,
                itemId: item.id,
                canOpenInCurrentTab: canOpenWorktreeInCurrentTab
            )
        case .quickOpen(let target):
            executeQuickOpen(target, itemId: item.id, modifier: modifier)
        case .activateRecent(let activation):
            executeRecentActivation(activation, itemId: item.id)
        case .createWorktree(let draft):
            guard
                let request = CommandBarWorktreeCreationResolver.dispatchableRequest(
                    draft: draft, dispatcher: dispatcher)
            else {
                return
            }
            dismiss(measureNonExecutingClose: false)
            dispatcher.dispatchWorktreeCreation(request)
        }
    }

    func showActions(for item: CommandBarItem) {
        guard case .quickOpen(let target) = item.action else { return }
        showActions(for: target)
    }

    private func showActions(for target: CommandBarQuickOpenTarget) {
        switch target {
        case .repository(let repositoryStableKey):
            guard
                let repository = store.repositoryTopologyAtom.repo(stableKey: repositoryStableKey),
                !store.repositoryTopologyAtom.isRepoUnavailable(repository.id),
                CommandBarDataSource.quickOpenDefaultWorktree(for: repository) != nil
            else {
                return
            }
            state.pushLevel(
                CommandBarDataSource.buildRepoLevel(
                    repo: repository,
                    store: store,
                    repoCache: repoCache,
                    dispatcher: dispatcher
                )
            )
            searchContextChanged()
        case .worktree(let worktreeStableKey):
            guard
                let worktree = store.repositoryTopologyAtom.worktree(stableKey: worktreeStableKey),
                let repository = store.repositoryTopologyAtom.repo(containing: worktree.id),
                !store.repositoryTopologyAtom.isRepoUnavailable(repository.id),
                !store.repositoryTopologyAtom.isWorktreeUnavailable(worktree.id)
            else {
                return
            }
            let presence = CommandBarDataSource.buildWorktreePresence(
                worktree: worktree,
                repo: repository,
                store: store
            )
            state.pushLevel(
                CommandBarDataSource.buildWorktreeActionsLevel(
                    worktree: worktree,
                    presence: presence,
                    canOpenInCurrentTab: resultSession.snapshot(state: state).canOpenWorktreeInCurrentTab,
                    dispatcher: dispatcher,
                    repository: repository
                )
            )
            searchContextChanged()
            if let level = state.currentLevel { requestCreationQueriesIfNeeded(for: level) }
        case .directory:
            return
        }
    }

    private func executeQuickOpen(
        _ target: CommandBarQuickOpenTarget,
        itemId: String,
        modifier: EnterModifier
    ) {
        if case .directory(let directory) = target {
            executeQuickOpenDirectory(directory, modifier: modifier)
            return
        }
        guard let worktree = resolveQuickOpenWorktree(target) else { return }
        let canOpenInCurrentTab = resultSession.snapshot(state: state).canOpenWorktreeInCurrentTab
        let placement: CommandBarWorktreeTerminalPlacement
        switch modifier {
        case .plain:
            placement = .newTab
        case .command:
            placement = .newTab
        case .option:
            guard canOpenInCurrentTab else { return }
            placement = .currentTabPane
        }
        guard
            let commandSpec = CommandBarCommandPresentation.targetedWorktreeTerminalSpec(
                for: placement,
                targetedSpecResolver: targetedSpecResolver
            )
        else {
            showActions(for: target)
            return
        }
        guard dispatcher.canDispatch(commandSpec.command, target: worktree.id, targetType: .worktree) else {
            return
        }
        state.recordRecent(itemId: itemId)
        dismiss(measureNonExecutingClose: false)
        dispatcher.dispatch(commandSpec.command, target: worktree.id, targetType: .worktree)
    }

    private func executeQuickOpenDirectory(
        _ directory: URL,
        modifier: EnterModifier
    ) {
        let canOpenInCurrentTab = resultSession.snapshot(state: state).canOpenWorktreeInCurrentTab
        let placement: QuickOpenDirectoryPlacement
        switch modifier {
        case .plain:
            placement = canOpenInCurrentTab ? .currentTabPane : .newTab
        case .command:
            placement = .newTab
        case .option:
            guard canOpenInCurrentTab else { return }
            placement = .currentTabPane
        }

        dismiss(measureNonExecutingClose: false)
        quickOpenDirectoryHandler(
            directory.standardizedFileURL,
            placement
        )
    }

    private func resolveQuickOpenWorktree(_ target: CommandBarQuickOpenTarget) -> Worktree? {
        switch target {
        case .repository(let repositoryStableKey):
            guard
                let repository = store.repositoryTopologyAtom.repo(stableKey: repositoryStableKey),
                !store.repositoryTopologyAtom.isRepoUnavailable(repository.id)
            else {
                return nil
            }
            return store.repositoryTopologyAtom.activationWorktree(
                for: .repository(repositoryStableKey: repositoryStableKey))
        case .worktree(let worktreeStableKey):
            guard
                let worktree = store.repositoryTopologyAtom.worktree(stableKey: worktreeStableKey),
                let repository = store.repositoryTopologyAtom.repo(containing: worktree.id),
                !store.repositoryTopologyAtom.isRepoUnavailable(repository.id),
                !store.repositoryTopologyAtom.isWorktreeUnavailable(worktree.id)
            else {
                return nil
            }
            return worktree
        case .directory:
            return nil
        }
    }

    private func executeRecentActivation(
        _ activation: CommandBarRecentActivation,
        itemId: String
    ) {
        let activationGeneration = activationGenerationGate.begin(
            rootSessionGeneration: state.rootSessionGeneration,
            workspaceID: store.identityAtom.workspaceId
        )
        switch activation {
        case .repository(let repositoryStableKey):
            let recentEntity = ApplicationRecentEntity.repository(
                repositoryStableKey: repositoryStableKey
            )
            guard
                let repository = store.repositoryTopologyAtom.repo(stableKey: repositoryStableKey),
                !store.repositoryTopologyAtom.isRepoUnavailable(repository.id),
                !repository.worktrees.isEmpty
            else {
                guard isCurrentActivation(activationGeneration) else { return }
                rejectStaleApplicationActivation(recentEntity)
                return
            }
            guard isCurrentActivation(activationGeneration) else { return }
            state.pushLevel(
                CommandBarDataSource.buildRepoLevel(
                    repo: repository,
                    store: store,
                    repoCache: repoCache,
                    dispatcher: dispatcher
                )
            )
            searchContextChanged()
        case .worktree(let worktreeStableKey):
            let recentEntity = ApplicationRecentEntity.worktree(
                worktreeStableKey: worktreeStableKey
            )
            guard
                let worktree = store.repositoryTopologyAtom.activationWorktree(
                    for: recentEntity
                )
            else {
                guard isCurrentActivation(activationGeneration) else { return }
                rejectStaleApplicationActivation(recentEntity)
                return
            }
            guard isCurrentActivation(activationGeneration) else { return }
            guard let repository = store.repositoryTopologyAtom.repo(containing: worktree.id) else {
                rejectStaleApplicationActivation(recentEntity)
                return
            }
            let presence = CommandBarDataSource.buildWorktreePresence(
                worktree: worktree,
                repo: repository,
                store: store
            )
            state.pushLevel(
                CommandBarDataSource.buildWorktreeActionsLevel(
                    worktree: worktree,
                    presence: presence,
                    canOpenInCurrentTab: store.tabLayoutAtom.activeTabId != nil,
                    dispatcher: dispatcher,
                    repository: repository
                )
            )
            searchContextChanged()
            if let level = state.currentLevel { requestCreationQueriesIfNeeded(for: level) }
        case .pane(let paneID, let workspaceID):
            guard
                workspaceID == store.identityAtom.workspaceId,
                let pane = store.paneAtom.pane(paneID),
                WorkspacePaneRecencyEligibility.isEligibleForRecording(
                    pane: pane,
                    workspaceMatches: true,
                    tabs: store.tabLayoutAtom.tabs,
                    targetableTabID: store.tabLayoutAtom.tabContaining(paneId: paneID)?.id
                )
            else {
                guard isCurrentActivation(activationGeneration) else { return }
                rejectStalePaneActivation(paneID: paneID, workspaceID: workspaceID)
                return
            }
            guard isCurrentActivation(activationGeneration) else { return }
            let targetType = CommandBarDataSource.targetTypeForPane(pane)
            guard
                let focusPaneSpec = CommandBarCommandPresentation.targetedSpec(
                    for: .focusPane,
                    targetType: targetType
                ),
                dispatcher.canDispatch(focusPaneSpec.command, target: paneID, targetType: targetType)
            else {
                return
            }
            state.recordRecent(itemId: itemId)
            dismiss(measureNonExecutingClose: false)
            dispatcher.dispatch(focusPaneSpec.command, target: paneID, targetType: targetType)
        }
    }

    private func isCurrentActivation(
        _ activationGeneration: CommandBarActivationGeneration
    ) -> Bool {
        activationGenerationGate.accepts(
            activationGeneration,
            rootSessionGeneration: state.rootSessionGeneration,
            workspaceID: store.identityAtom.workspaceId
        )
    }

    private func rejectStaleApplicationActivation(_ entity: ApplicationRecentEntity) {
        if !store.repositoryTopologyAtom.containsCanonicalLocation(for: entity) {
            atom(\.applicationEntityRecency).remove(entity)
        }
        state.selectedIndex = 0
    }

    private func rejectStalePaneActivation(paneID: UUID, workspaceID: UUID) {
        let recencyAtom = atom(\.workspaceEntityRecency)
        if recencyAtom.workspaceID == workspaceID {
            recencyAtom.remove(.pane(paneID: paneID))
        }
        state.selectedIndex = 0
    }

    private func recordRecentCommandIfNeeded(_ command: AppCommand) {
        guard state.currentScope == .commands else { return }
        state.recordRecentCommand(command)
    }

    private func executeResolvedWorktreeAction(
        resolution: CommandBarWorktreeActionResolution,
        presence: WorktreePresence,
        itemId: String,
        canOpenInCurrentTab: Bool
    ) {
        switch resolution {
        case .dispatch(let command, let target, let targetType):
            guard dispatcher.canDispatch(command, target: target, targetType: targetType) else {
                return
            }
            state.recordRecent(itemId: itemId)
            dismiss(measureNonExecutingClose: false)
            dispatcher.dispatch(command, target: target, targetType: targetType)
        case .showActionsMenu:
            guard let worktree = store.repositoryTopologyAtom.worktree(presence.worktreeId),
                let repository = store.repositoryTopologyAtom.repo(containing: worktree.id)
            else { return }
            state.pushLevel(
                CommandBarDataSource.buildWorktreeActionsLevel(
                    worktree: worktree,
                    presence: presence,
                    canOpenInCurrentTab: canOpenInCurrentTab,
                    dispatcher: dispatcher,
                    repository: repository
                )
            )
            searchContextChanged()
            if let level = state.currentLevel { requestCreationQueriesIfNeeded(for: level) }
        }
    }

    private func dismissPanel(completion: @escaping @MainActor () -> Void) {
        guard let panel else {
            completion()
            return
        }

        // Animate out — capture panel locally to avoid actor-isolation issues in completion
        let panelToRemove = panel
        self.panel = nil

        let finishDismissal: @MainActor () -> Void = {
            panelToRemove.parent?.removeChildWindow(panelToRemove)
            panelToRemove.orderOut(nil)
            controllerLogger.debug("Command bar panel dismissed")
            completion()
        }

        if !animatePanelDismissal || !panelToRemove.isVisible || parentWindow?.isVisible != true {
            finishDismissal()
        } else {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.08
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panelToRemove.animator().alphaValue = 0
                },
                completionHandler: {
                    Task { @MainActor in
                        finishDismissal()
                    }
                })
        }

        // Remove backdrop
        hideBackdrop()

        // Return focus to parent window
        parentWindow?.makeKeyAndOrderFront(nil)
    }

    private func normalizedPrefix(for prefix: String?) -> String? {
        if let prefix, [">", "$", "#"].contains(prefix) {
            return prefix + " "
        }
        return prefix
    }

    private func normalizedPrefix(for scope: CommandBarScope) -> String? {
        switch scope {
        case .everything:
            return nil
        case .quickOpen:
            return nil
        case .commands:
            return "> "
        case .panes:
            return "$ "
        case .repos:
            return "# "
        case .inbox:
            return nil
        }
    }

    // MARK: - Backdrop

    private func showBackdrop(on window: NSWindow) {
        guard let contentView = window.contentView else { return }

        let backdrop = CommandBarBackdropView(onDismiss: { [weak self] in
            self?.dismiss()
        })
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.alphaValue = 0
        contentView.addSubview(backdrop, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        self.backdropView = backdrop

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdrop.animator().alphaValue = 1
        }
    }

    private func hideBackdrop() {
        guard let backdrop = backdropView else { return }

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.08
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                backdrop.animator().alphaValue = 0
            },
            completionHandler: {
                Task { @MainActor in
                    backdrop.removeFromSuperview()
                }
            })
        backdropView = nil
    }
}

// MARK: - CommandBarBackdropView

/// Semi-transparent overlay behind the command bar panel. Click to dismiss.
@MainActor
final class CommandBarBackdropView: NSView {
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CommandBarPanelController does not support NSCoder") }

    override func mouseDown(with event: NSEvent) {
        onDismiss()
    }

    // The backdrop lives in the parent window, but the command bar panel is
    // key while open. Without this, a click outside the panel would first
    // promote the parent window to key and swallow the event — requiring a
    // second click to actually dismiss.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
