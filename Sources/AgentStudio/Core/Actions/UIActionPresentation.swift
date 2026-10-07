import AgentStudioInfrastructure
import Foundation

package struct ActionSpec: Equatable, Sendable {
    package let label: String
    package let helpText: String
    package let icon: CommandIcon

    package init(label: String, helpText: String, icon: CommandIcon) {
        self.label = label
        self.helpText = helpText
        self.icon = icon
    }
}

extension ActionSpec {
    func controlTooltipSource(
        provenance: CommandDisplayProvenance,
        textOverride: String? = nil,
        shortcutText: ShortcutDisplayText? = nil
    ) -> ControlTooltipSource {
        .display(
            CommandDisplayDescriptor(
                provenance: provenance,
                label: label,
                helpText: helpText,
                compactTooltipText: textOverride,
                shortcutDisplayText: shortcutText
            ))
    }

    package func controlTooltipRenderValue(
        provenance: CommandDisplayProvenance,
        textOverride: String? = nil,
        shortcutText: ShortcutDisplayText? = nil
    ) -> ControlTooltipRenderValue {
        ControlTooltipResolver.resolve(
            controlTooltipSource(
                provenance: provenance,
                textOverride: textOverride,
                shortcutText: shortcutText
            ))
    }

    func controlToolTip(
        textOverride: String? = nil,
        shortcutText: ShortcutDisplayText? = nil
    ) -> String {
        controlTooltipRenderValue(
            provenance: .localAction(rawValue: label),
            textOverride: textOverride,
            shortcutText: shortcutText
        ).text
    }
}

extension KeyBinding {
    var displayText: ShortcutDisplayText {
        ShortcutDisplayText(value: displayString)
    }

    package var displayString: String {
        var keys: [String] = []
        if modifiers.contains(.command) { keys.append("⌘") }
        if modifiers.contains(.shift) { keys.append("⇧") }
        if modifiers.contains(.option) { keys.append("⌥") }
        if modifiers.contains(.control) { keys.append("⌃") }
        keys.append(displayKey)
        return keys.joined()
    }

    private var displayKey: String {
        key.count == 1 ? key.uppercased() : key
    }
}

package enum LocalActionSpec {
    case goToMessagePane
    case showPaneAgentLine(AgentLineWork)
    case paneSessionStatus(AgentSessionStatus)
    case countInformationalPaneMessages
    case showPaneMessages
    case showPaneMessageDetails
    case answerPaneMessage
    case selectPaneMessageChoice(AskChoice)
    case dismissPaneMessage
    case dismissAllPaneNotices
    case markPaneMessageRead
    case openPaneMessageFile
    case openPaneMessagePullRequest
    case loadMorePaneMessages
    case loadMoreMessageSources
    case showAllPaneMessages
    case filterPaneMessages(AgentMessageAttentionType)

    case quickOpen
    case commandPalette
    case goToPane
    case createNewInTab
    case createNewInPane
    case openInEditorMenu
    case goToTerminal
    case openInCursor
    case openInVSCode
    case revealInFinder
    case copyPath
    case revealDataLocationInFinder
    case clearFilter
    case refreshWorktrees
    case chooseFolderToScan
    case openAllInTabs
    case extractPaneToNewTab
    case movePaneToTabMenu
    case openGitHubInNewTab
    case arrangements
    case addTerminalToTab
    case showArrangements
    case saveCurrentLayoutAsArrangement
    case showPane
    case hidePane
    case addDrawerTerminal
    case browserBack
    case browserForward
    case browserStop
    case browserReload
    case browserHome
    case browserAddFavorite
    case browserRemoveFavorite
    case emptyTerminal
    case openRepoWorktree
    case forkThisWorktree
    case renameArrangement
    case deleteArrangement
    case addFavorite
    case clearAllHistory
    case groupInboxNotifications
    case deleteInboxNotifications
    case showRepoExplorerOrganization
    case sortRepoExplorerItems
    case groupRepoExplorerWorktrees
    case subgroupRepoExplorerWorktrees
    case noRepoExplorerSubgroups
    case cancel
    case add
    case rename
    case openPaneLocationInFinder
    case openPaneLocationInBookmarkedEditor
    case openPaneLocationInEditorMenu
    case toggleDrawer(isExpanded: Bool)
    case addDrawerPane
    case previewPane

    package var actionSpec: ActionSpec {
        switch self {
        case .showPaneAgentLine(let work):
            return PaneContextLineActionSpecs.agentLine(work)
        case .paneSessionStatus(let status):
            return PaneContextLineActionSpecs.sessionStatus(status)
        case .goToMessagePane:
            return ActionSpec(label: "Go to pane", helpText: "Focus this message's pane", icon: .system(.terminal))
        case .showPaneMessageDetails:
            return ActionSpec(label: "Message details", helpText: "Show this message", icon: .system(.docText))
        case .countInformationalPaneMessages:
            return ActionSpec(
                label: "Count informational", helpText: "Include informational notices in the messages count",
                icon: .system(.docText))
        case .showPaneMessages:
            return ActionSpec(label: "Messages", helpText: "Show this pane's messages", icon: .system(.bell))
        case .selectPaneMessageChoice(let choice):
            return ActionSpec(label: choice.label, helpText: "Select \(choice.label)", icon: .system(.checkmarkCircle))
        case .answerPaneMessage:
            return ActionSpec(label: "Answer", helpText: "Answer this message", icon: .system(.checkmarkCircle))
        case .dismissPaneMessage:
            return ActionSpec(
                label: "Dismiss", helpText: "Dismiss this message; hand a blocking ask back to the provider",
                icon: .system(.xmarkCircle))
        case .dismissAllPaneNotices:
            return ActionSpec(
                label: "Dismiss all notices", helpText: "Dismiss this pane's notices", icon: .system(.trash))
        case .markPaneMessageRead:
            return ActionSpec(label: "Mark read", helpText: "Mark this notice read", icon: .system(.checkmarkCircle))
        case .openPaneMessageFile:
            return ActionSpec(label: "Open file", helpText: "Open this message's file", icon: .system(.docText))
        case .openPaneMessagePullRequest:
            return ActionSpec(
                label: "Open pull request", helpText: "Open this pull request", icon: .octicon(.gitPullRequest))
        case .loadMorePaneMessages:
            return ActionSpec(
                label: "More messages", helpText: "Load more messages from this pane", icon: .system(.chevronDown))
        case .loadMoreMessageSources:
            return ActionSpec(
                label: "More panes", helpText: "Load messages from more drawer panes", icon: .system(.chevronDown))
        case .showAllPaneMessages:
            return ActionSpec(label: "All", helpText: "Show all message types", icon: .system(.bell))
        case .filterPaneMessages(let type):
            switch type {
            case .needsApproval:
                return ActionSpec(
                    label: "Approvals", helpText: "Show messages needing approval", icon: .system(.personBadgeKey))
            case .needsReply:
                return ActionSpec(
                    label: "Replies", helpText: "Show messages needing a reply", icon: .system(.envelopeBadge))
            case .attention:
                return ActionSpec(label: "Attention", helpText: "Show attention messages", icon: .system(.bellBadge))
            case .informational:
                return ActionSpec(
                    label: "Information", helpText: "Show informational messages", icon: .system(.docText))
            }
        case .quickOpen:
            return ActionSpec(
                label: "Quick Open", helpText: "Show the quick-open palette", icon: .system(.magnifyingglass))
        case .forkThisWorktree:
            return ActionSpec(
                label: "Fork This Worktree",
                helpText: "Fork this worktree with its uncommitted, untracked, and ignored files",
                icon: .octicon(.repoForked))
        case .commandPalette:
            return ActionSpec(
                label: "Command Palette", helpText: "Show the command palette", icon: .system(.command))
        case .goToPane:
            return ActionSpec(label: "Go to Pane", helpText: "Show the pane picker", icon: .system(.terminal))
        case .createNewInTab:
            return ActionSpec(
                label: "Create New in Tab", helpText: "Choose what to create in a new tab",
                icon: .system(.plusRectangle))
        case .createNewInPane:
            return ActionSpec(
                label: "Create New in Pane", helpText: "Choose what to create in the current pane",
                icon: .system(.rectangleSplit2x1))
        case .openInEditorMenu:
            return ActionSpec(
                label: "Open in Editor", helpText: "Choose an editor to open this worktree",
                icon: .system(.ellipsisCircle))
        case .goToTerminal:
            return ActionSpec(
                label: "Go to Terminal", helpText: "Focus the existing terminal for this worktree",
                icon: .system(.terminal))
        case .openInCursor:
            return ActionSpec(
                label: "Cursor", helpText: "Open this worktree in Cursor", icon: .octicon(.codeSquare))
        case .openInVSCode:
            return ActionSpec(
                label: "VS Code", helpText: "Open this worktree in VS Code", icon: .octicon(.vscode))
        case .revealInFinder:
            return ActionSpec(
                label: "Reveal in Finder", helpText: "Reveal this path in Finder", icon: .system(.folder))
        case .copyPath:
            return ActionSpec(
                label: "Copy Path", helpText: "Copy this path to the clipboard", icon: .system(.documentOnDocument))
        case .revealDataLocationInFinder:
            return ActionSpec(
                label: "Reveal in Finder", helpText: "Reveal the AgentStudio data folder in Finder",
                icon: .system(.folder))
        case .clearFilter:
            return ActionSpec(
                label: "Clear Filter", helpText: "Clear filter", icon: .system(.xmarkCircleFill))
        case .refreshWorktrees:
            return ActionSpec(
                label: "Refresh Worktrees", helpText: "Refresh watched worktrees", icon: .system(.arrowClockwise))
        case .chooseFolderToScan:
            return ActionSpec(
                label: "Choose a Folder to Scan…", helpText: "Choose a folder to scan",
                icon: .system(.folderFillBadgePlus))
        case .openAllInTabs:
            return ActionSpec(
                label: "Open All In Tabs", helpText: "Open all recent worktrees in tabs",
                icon: .system(.rectangleStack))
        case .extractPaneToNewTab:
            return ActionSpec(
                label: "Extract Pane to New Tab", helpText: "Move the active pane into a new tab",
                icon: .system(.arrowUpRightSquare))
        case .movePaneToTabMenu:
            return ActionSpec(
                label: "Move Pane to Tab", helpText: "Move the active pane into another tab",
                icon: .system(.filemenuAndPointerArrow))
        case .openGitHubInNewTab:
            return ActionSpec(
                label: "Open GitHub in New Tab", helpText: "Open GitHub in a new tab", icon: .system(.globe))
        case .arrangements:
            return ActionSpec(
                label: "Arrangements", helpText: "Manage tab arrangements", icon: .system(.rectangle3GroupFill))
        case .addTerminalToTab:
            return ActionSpec(
                label: "Add Terminal to Tab",
                helpText: "Choose where to add a terminal in the tab",
                icon: .system(.terminal)
            )
        case .showArrangements:
            return ActionSpec(
                label: "Show Arrangements",
                helpText: "Show arrangements for the active tab",
                icon: Self.arrangements.actionSpec.icon
            )
        case .saveCurrentLayoutAsArrangement:
            return ActionSpec(
                label: "Save Current Layout as Arrangement", helpText: "Save current layout as arrangement",
                icon: .system(.plus))
        case .showPane:
            return ActionSpec(label: "Show Pane", helpText: "Show pane", icon: .system(.eye))
        case .hidePane:
            return ActionSpec(label: "Hide Pane", helpText: "Hide pane", icon: .system(.eyeSlash))
        case .addDrawerTerminal:
            return ActionSpec(
                label: "Add Drawer Terminal", helpText: "Add a drawer terminal", icon: .system(.plus))
        case .browserBack:
            return ActionSpec(label: "Back", helpText: "Back (⌘[)", icon: .system(.chevronLeft))
        case .browserForward:
            return ActionSpec(label: "Forward", helpText: "Forward (⌘])", icon: .system(.chevronRight))
        case .browserStop:
            return ActionSpec(label: "Stop Loading", helpText: "Stop loading", icon: .system(.xmark))
        case .browserReload:
            return ActionSpec(label: "Reload", helpText: "Reload (⌘R)", icon: .system(.arrowClockwise))
        case .browserHome:
            return ActionSpec(label: "New Tab Page", helpText: "New tab page", icon: .system(.house))
        case .browserAddFavorite:
            return ActionSpec(
                label: "Add to Favorites", helpText: "Add to favorites (⌘D)", icon: .system(.star))
        case .browserRemoveFavorite:
            return ActionSpec(
                label: "Remove from Favorites", helpText: "Remove from favorites (⌘D)", icon: .system(.starFill))
        case .emptyTerminal:
            return ActionSpec(
                label: "Empty Terminal", helpText: "Open a new empty terminal tab", icon: .system(.terminal))
        case .openRepoWorktree:
            return ActionSpec(
                label: "Open Worktree...", helpText: "Open a discovered worktree in a tab", icon: .system(.folder))
        case .renameArrangement:
            return ActionSpec(label: "Rename...", helpText: "Rename this arrangement", icon: .system(.pencil))
        case .deleteArrangement:
            return ActionSpec(label: "Delete", helpText: "Delete this arrangement", icon: .system(.trash))
        case .addFavorite:
            return ActionSpec(
                label: "Add Favorite", helpText: "Add a saved favorite URL", icon: .system(.plus))
        case .clearAllHistory:
            return ActionSpec(
                label: "Clear All History", helpText: "Clear all saved browser history", icon: .system(.trash))
        case .groupInboxNotifications:
            return ActionSpec(
                label: "Group Inbox Notifications",
                helpText: "Group inbox notifications",
                icon: .system(.squareStack3dUp)
            )
        case .deleteInboxNotifications:
            return ActionSpec(
                label: "Delete Inbox Notifications",
                helpText: "Open delete actions for inbox notifications",
                icon: .system(.deleteLeft)
            )
        case .sortRepoExplorerItems:
            return ActionSpec(
                label: "Sort", helpText: "Choose how sidebar items are sorted", icon: .system(.arrowUpArrowDown))
        case .showRepoExplorerOrganization:
            return ActionSpec(
                label: "Organization",
                helpText: "Choose how sidebar items are grouped",
                icon: .system(.sliderHorizontal3)
            )
        case .groupRepoExplorerWorktrees:
            return ActionSpec(
                label: "Group",
                helpText: "Choose how sidebar items are grouped",
                icon: .system(.square2Layers3d)
            )
        case .noRepoExplorerSubgroups:
            return ActionSpec(
                label: "No subgroups", helpText: "Subgrouping is unavailable for this grouping", icon: .system(.circle))
        case .subgroupRepoExplorerWorktrees:
            return ActionSpec(
                label: "Subgroup",
                helpText: "Choose how sidebar items are subgrouped",
                icon: .system(.listBulletIndent)
            )
        case .cancel:
            return ActionSpec(label: "Cancel", helpText: "Cancel this action", icon: .system(.xmarkCircle))
        case .add:
            return ActionSpec(label: "Add", helpText: "Add this item", icon: .system(.plusCircle))
        case .rename:
            return ActionSpec(label: "Rename", helpText: "Rename this item", icon: .system(.pencil))
        case .openPaneLocationInFinder:
            return ActionSpec(
                label: "Open pane location in Finder", helpText: "Open pane location in Finder",
                icon: .system(.finder))
        case .openPaneLocationInBookmarkedEditor:
            return ActionSpec(
                label: "Open pane location in bookmarked editor",
                helpText: "Open pane location in the bookmarked editor",
                icon: .octicon(.codeSquare))
        case .openPaneLocationInEditorMenu:
            return ActionSpec(
                label: "Open pane location in app menu",
                helpText: "Choose an app for this pane location",
                icon: .system(.chevronUpChevronDown)
            )
        case .toggleDrawer(let isExpanded):
            return ActionSpec(
                label: isExpanded ? "Collapse Drawer" : "Expand Drawer",
                helpText: isExpanded ? "Collapse drawer" : "Expand drawer",
                icon: .system(.rectangleBottomhalfFilled)
            )
        case .addDrawerPane:
            return ActionSpec(label: "Add Drawer Pane", helpText: "Add drawer pane", icon: .system(.plus))
        case .previewPane:
            return ActionSpec(
                label: "Preview Pane",
                helpText: "Preview the selected pane while holding Space",
                icon: .system(.eye)
            )
        }
    }
}
