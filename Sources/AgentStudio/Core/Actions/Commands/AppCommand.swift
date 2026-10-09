import Foundation

// MARK: - AppCommand
/// All available commands in the application.
/// Every action — keyboard shortcut, menu item, context menu, command bar, search result,
/// or management layer click — is backed by a command.
package enum AppCommand: String, CaseIterable {
    // Tab commands
    case closeTab
    case breakUpTab
    case renameTab
    case newTerminalInTab
    case newTab
    case undoCloseTab
    case selectTab
    case nextTab
    case prevTab
    case selectTab1, selectTab2, selectTab3, selectTab4, selectTab5
    case selectTab6, selectTab7, selectTab8, selectTab9
    // Pane commands
    case closePane
    case extractPaneToTab
    case movePaneToTab
    case focusPane
    case scrollToBottom
    case scrollPageUp
    case scrollPageDown
    case scrollSmallStepUp
    case scrollSmallStepDown
    case jumpToPreviousPrompt
    case jumpToNextPrompt
    case splitRight, splitLeft
    case equalizePanes
    case focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown
    case focusNextPane, focusPrevPane
    case focusPreviousPinnedPane, focusNextPinnedPane
    case focusPane1, focusPane2, focusPane3, focusPane4, focusPane5
    case focusPane6, focusPane7, focusPane8, focusPane9
    case zoomPane
    case minimizePane
    case expandPane
    // Arrangement commands
    case switchArrangement
    case previousArrangement
    case nextArrangement
    case cycleArrangement
    case saveArrangement
    case deleteArrangement
    case renameArrangement
    // Drawer commands
    case enterDrawer
    case focusDrawerPaneUp
    case focusDrawerPaneLeft
    case focusDrawerPaneDown
    case focusDrawerPaneRight
    case focusDrawerPane1, focusDrawerPane2, focusDrawerPane3, focusDrawerPane4, focusDrawerPane5
    case focusDrawerPane6, focusDrawerPane7, focusDrawerPane8, focusDrawerPane9
    case detachDrawerPane
    case addDrawerPane
    case toggleDrawer
    case moveZoomDrawerToTerminal
    case moveZoomDrawerToBridge
    case navigateDrawerPane
    case closeDrawerPane
    case openPaneLocationInBookmarkedEditor
    case openPaneLocationInFinder
    case openPaneLocationInEditorMenu
    case editPaneNote
    case copyCurrentPanePath
    case openPullRequest
    // Repo commands
    case watchFolder, updateRepositoryFacts, removeRepo
    case pinRepo, unpinRepo
    case pinPane, unpinPane
    case openWorktree
    case openWorktreeInPane
    case newWorktree
    case newWorktreeFromDefault
    case newWorktreeFromBranch
    case forkWorktree
    // Management layer
    case toggleManagementLayer
    case managementLayerFocusLeft
    case managementLayerFocusRight
    case managementLayerEnterDrawer
    case managementLayerExitDrawer
    case managementLayerOpenDrawer
    case managementLayerCreateTerminal
    case managementLayerCreateBrowser
    case managementLayerExit
    // Workspace commands
    case toggleSidebar
    case focusSidebar
    case showInboxNotifications
    case toggleInboxNotificationSort
    case clearReadInboxNotifications
    case clearAllInboxNotifications
    case showPaneInboxNotifications
    case clearPaneInboxNotifications
    case showReposSidebar
    case showPanesSidebar
    case setReposGroupingRepo
    case setReposGroupingActivity
    case setReposSortFieldName
    case setReposSortFieldActivity
    case setPanesSortFieldName
    case setPanesSortFieldActivity
    case toggleReposSortDirection
    case togglePanesSortDirection
    case toggleReposShowsPinned
    case togglePanesShowsPinned
    case togglePanesShowsDrawers
    case setInboxGroupingTab
    case setInboxGroupingRepo
    case setInboxGroupingPane
    case setInboxGroupingNone
    case setInboxRowStateFilter
    case setInboxContentMode
    case newFloatingTerminal
    // Window commands
    case newWindow
    case closeWindow
    // Search/navigation
    case showCommandBarEverything
    case showCommandBarQuickOpen
    case showCommandBarCommands
    case showCommandBarPanes
    case showCommandBarRepos
    // Webview commands
    case openWebview
    case reloadBridgeWebView
    case showViewer
    case showBridgeReview
    case showBridgeFiles
    case openBridgeReviewInNewTab
    case openBridgeFilesInNewTab
    case signInGitHub
    case signInGoogle
    // Sidebar commands
    case filterSidebar
    case openNewTerminalInTab
}

extension AppCommand {
    var isScopeAwareDrawerShortcut: Bool {
        switch self {
        case .enterDrawer, .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown, .focusDrawerPaneRight:
            return true
        default:
            return false
        }
    }
}

// MARK: - SearchItemType

/// Types of items that can be searched and targeted by commands.
package enum SearchItemType: String, CaseIterable, Hashable, Sendable {
    case repo
    case worktree
    case tab
    case pane
    case floatingTerminal
}

// MARK: - KeyBinding

/// A keyboard shortcut binding for a command.
package struct KeyBinding: Codable, Hashable, Sendable {
    package var key: String
    package var modifiers: Set<Modifier>

    package init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    package enum Modifier: String, Codable, Hashable, Sendable {
        case command
        case control
        case option
        case shift
    }
}

// MARK: - AppCommandSpec

package enum SidebarKeyboardCompletion: Equatable, Sendable {
    case preserveCommandFocus
    case returnToOrigin
}

/// Full command definition tying command identity, shortcut, display info, and context together.
package struct AppCommandSpec {
    package let command: AppCommand
    package let shortcut: AppShortcut?
    package let displayShortcutTrigger: ShortcutTrigger?
    package let label: String
    package let icon: CommandIcon
    package let helpText: String
    package let surfacePolicy: AppCommandSurfacePolicy
    package let targeting: AppCommandTargeting
    package let requiresManagementLayer: Bool
    package let visibleWhen: Set<CommandRequirement>
    package let commandBarGroupName: String
    package let commandBarGroupPriority: Int
    package let sidebarKeyboardCompletion: SidebarKeyboardCompletion

    package init(
        command: AppCommand,
        shortcut: AppShortcut? = nil,
        displayShortcutTrigger: ShortcutTrigger? = nil,
        label: String,
        icon: CommandIcon,
        helpText: String,
        surfacePolicy: AppCommandSurfacePolicy,
        targeting: AppCommandTargeting,
        requiresManagementLayer: Bool = false,
        visibleWhen: Set<CommandRequirement> = [],
        commandBarGroupName: String = "Commands",
        commandBarGroupPriority: Int = 8,
        sidebarKeyboardCompletion: SidebarKeyboardCompletion = .preserveCommandFocus
    ) {
        self.command = command
        self.shortcut = shortcut
        self.displayShortcutTrigger = displayShortcutTrigger
        self.label = label
        self.icon = icon
        self.helpText = helpText
        self.surfacePolicy = surfacePolicy
        self.targeting = targeting
        self.requiresManagementLayer = requiresManagementLayer
        self.visibleWhen = visibleWhen
        self.commandBarGroupName = commandBarGroupName
        self.commandBarGroupPriority = commandBarGroupPriority
        self.sidebarKeyboardCompletion = sidebarKeyboardCompletion
    }

    package var globalKeyBinding: KeyBinding? { shortcut?.displayKeyBinding(in: .global) }
    package var commandBarShortcutTrigger: ShortcutTrigger? {
        displayShortcutTrigger ?? shortcut?.spec.displayTrigger(in: .global)
    }
}

/// Feature-facing access to App-owned command execution.
@MainActor
package protocol AppCommandDispatching: AnyObject, Sendable {
    /// Returns whether an interactive execution owner accepted the command.
    @discardableResult func dispatch(_ command: AppCommand) -> Bool
    func dispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType)
    /// Keep keyboard-only interaction admission at the selected execution owner.
    func dispatchKeyboardShortcut(_ shortcut: AppShortcut)
    func dispatchExtractPaneToTab(tabId: UUID, paneId: UUID, targetTabInsertionIndex: Int?)
    func canDispatch(_ command: AppCommand) -> Bool
    func canDispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool
    func bridgePaneCommandTarget(worktreeId: UUID) -> BridgePaneCommandTarget?
    func dispatchMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID)
    /// Returns whether the shell creation owner accepted the typed creation request.
    @discardableResult func dispatchWorktreeCreation(_ request: WorktreeCreationRequest) -> Bool
}

extension AppCommandDispatching {
    /// Fail closed: a dispatcher opts into worktree creation explicitly; it never
    /// inherits a silent acceptance from this protocol.
    @discardableResult package func dispatchWorktreeCreation(_: WorktreeCreationRequest) -> Bool {
        false
    }
}
