import Foundation

// MARK: - AppCommand Catalog Helpers

extension AppCommand {
    func retiredGlobalInboxDefinition() -> AppCommandSpec {
        retiredInboxDefinition(
            label: "Toggle Inbox",
            icon: .system(.bell),
            helpText: "The notification inbox is retired"
        )
    }

    func retiredInboxDefinition(
        label: String,
        icon: CommandIcon,
        helpText: String
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: .notPresented,
            targeting: .contextual,
            commandBarGroupName: "Inbox",
            commandBarGroupPriority: CommandBarGroupPriority.miscellaneous
        )
    }

    /// Ordered array of tab selection commands (⌘1 through ⌘9)
    package static let selectTabCommands: [AppCommand] = [
        .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
        .selectTab6, .selectTab7, .selectTab8, .selectTab9,
    ]

    package static let focusPaneCommands: [AppCommand] = [
        .focusPane1, .focusPane2, .focusPane3, .focusPane4, .focusPane5,
        .focusPane6, .focusPane7, .focusPane8, .focusPane9,
    ]

    package static let focusDrawerPaneCommands: [AppCommand] = [
        .focusDrawerPane1, .focusDrawerPane2, .focusDrawerPane3, .focusDrawerPane4, .focusDrawerPane5,
        .focusDrawerPane6, .focusDrawerPane7, .focusDrawerPane8, .focusDrawerPane9,
    ]

    func menuTabSelectionDefinition(index: Int) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            shortcut: Self.selectTabShortcut(index: index),
            label: "Select Tab \(index)",
            icon: .system(.rectangleStack),
            helpText: "Select tab \(index)",
            surfacePolicy: .exposed([.mainMenu]),
            targeting: .contextual,
            visibleWhen: [.hasActiveTab],
            commandBarGroupPriority: CommandBarGroupPriority.miscellaneous
        )
    }

    func shortcutFocusPaneDefinition(index: Int) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            shortcut: Self.focusPaneShortcut(index: index),
            label: "Focus Pane \(index)",
            icon: .system(.rectangleSplit2x1),
            helpText: "Focus pane \(index)",
            surfacePolicy: .notPresented,
            targeting: .contextual,
            visibleWhen: [.hasActiveTab],
            commandBarGroupName: "Focus",
            commandBarGroupPriority: CommandBarGroupPriority.focus
        )
    }

    func shortcutFocusDrawerPaneDefinition(index: Int) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Focus Drawer Pane \(index)",
            icon: .system(.rectangleBottomhalfInsetFilled),
            helpText: "Focus drawer pane \(index)",
            surfacePolicy: .notPresented,
            targeting: .contextual,
            visibleWhen: [.hasActivePane],
            commandBarGroupName: "Focus",
            commandBarGroupPriority: CommandBarGroupPriority.focus
        )
    }

    func focusDefinition(label: String, icon: CommandIcon, helpText: String) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: .exposed([.commandBar]),
            targeting: .contextual,
            visibleWhen: [.hasActiveTab, .hasMultiplePanes],
            commandBarGroupName: "Focus",
            commandBarGroupPriority: CommandBarGroupPriority.focus
        )
    }

    func worktreeDefinition(
        label: String,
        icon: CommandIcon,
        helpText: String,
        surfacePolicy: AppCommandSurfacePolicy,
        targetTypes: Set<SearchItemType> = [.worktree]
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: surfacePolicy,
            targeting: .targeted(targetTypes),
            commandBarGroupName: "Repo",
            commandBarGroupPriority: CommandBarGroupPriority.repo
        )
    }

    func repositoryFactUpdateDefinition() -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Refresh",
            icon: .system(.arrowClockwise),
            helpText: "Fetch latest remote references and refresh repository facts",
            surfacePolicy: .exposed([.inlineControl]),
            targeting: .targeted([.repo]),
            commandBarGroupName: "Repo",
            commandBarGroupPriority: CommandBarGroupPriority.repo
        )
    }

    func bridgeWebViewReloadDefinition() -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Reload Bridge",
            icon: .system(.arrowClockwise),
            helpText:
                "Reload the Bridge browser page and discard browser presentation state without refreshing worktree source data",
            surfacePolicy: .exposed([.commandBar, .bridgePage]),
            targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
            visibleWhen: [.hasActivePane, .paneIsBridge],
            commandBarGroupName: "Bridge",
            commandBarGroupPriority: CommandBarGroupPriority.bridge
        )
    }

    func openWebviewDefinition() -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Open New Webview Tab",
            icon: .system(.globe),
            helpText: "Open a new webview tab",
            surfacePolicy: .exposed([.commandBar, .mainMenu]),
            targeting: .contextual,
            commandBarGroupName: "Webview",
            commandBarGroupPriority: CommandBarGroupPriority.webview
        )
    }

    func sidebarSettingDefinition(
        label: String,
        icon: CommandIcon,
        helpText: String
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: .exposed([.commandBar, .inlineControl]),
            targeting: .contextual,
            commandBarGroupName: "Sidebar",
            commandBarGroupPriority: CommandBarGroupPriority.sidebar
        )
    }

    func sidebarScreenDefinition(
        shortcut: AppShortcut? = nil,
        label: String,
        icon: CommandIcon,
        helpText: String,
        sidebarKeyboardCompletion: SidebarKeyboardCompletion = .preserveCommandFocus
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            shortcut: shortcut,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: .exposed([.commandBar, .inlineControl, .toolbar(.app)]),
            targeting: .contextual,
            commandBarGroupName: "Sidebar",
            commandBarGroupPriority: CommandBarGroupPriority.sidebar,
            sidebarKeyboardCompletion: sidebarKeyboardCompletion
        )
    }

    func inboxGroupingDefinition(
        label: String,
        icon: CommandIcon,
        helpTarget: String
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Group Inbox by \(label)",
            icon: icon,
            helpText: "Group inbox notifications by \(helpTarget)",
            surfacePolicy: .exposed([.commandBar, .inlineControl]),
            targeting: .contextual,
            commandBarGroupName: "Inbox",
            commandBarGroupPriority: CommandBarGroupPriority.inbox
        )
    }

    func inboxRowStateFilterDefinition() -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Set Inbox Row Filter",
            icon: .system(.envelopeBadge),
            helpText: "Set whether the inbox shows all or unread notifications",
            surfacePolicy: .exposed([.inlineControl]),
            targeting: .contextual,
            commandBarGroupName: "Inbox",
            commandBarGroupPriority: CommandBarGroupPriority.inbox
        )
    }

    func inboxContentModeDefinition() -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Set Inbox Content Mode",
            icon: .system(.dotCircleViewfinder),
            helpText: "Set which notification content lane the inbox shows",
            surfacePolicy: .exposed([.inlineControl]),
            targeting: .contextual,
            commandBarGroupName: "Inbox",
            commandBarGroupPriority: CommandBarGroupPriority.inbox
        )
    }

    func sidebarPinDefinition(
        label: String,
        icon: SystemSymbol,
        helpText: String,
        targetType: SearchItemType
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: label,
            icon: .system(icon),
            helpText: helpText,
            surfacePolicy: .exposed(
                targetType == .pane
                    ? [.contextMenu, .toolbar(.pane), .toolbar(.terminalZoom)] : [.contextMenu, .inlineControl]),
            targeting: .targeted([targetType]),
            commandBarGroupName: "Sidebar",
            commandBarGroupPriority: CommandBarGroupPriority.sidebar
        )
    }

    func arrangementDefinition(
        shortcut: AppShortcut? = nil,
        label: String,
        icon: CommandIcon,
        helpText: String,
        surfacePolicy: AppCommandSurfacePolicy,
        targeting: AppCommandTargeting
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            shortcut: shortcut,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: surfacePolicy,
            targeting: targeting,
            visibleWhen: [.hasActiveTab, .hasArrangements],
            commandBarGroupName: "Tab",
            commandBarGroupPriority: CommandBarGroupPriority.tab
        )
    }

    func windowDefinition(
        shortcut: AppShortcut? = nil,
        label: String,
        icon: CommandIcon,
        helpText: String,
        surfacePolicy: AppCommandSurfacePolicy,
        targeting: AppCommandTargeting
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            shortcut: shortcut,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: surfacePolicy,
            targeting: targeting,
            commandBarGroupName: "Window",
            commandBarGroupPriority: CommandBarGroupPriority.window
        )
    }

    func inboxActionDefinition(
        label: String,
        icon: CommandIcon,
        helpText: String
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: .exposed([.commandBar, .inlineControl]),
            targeting: .contextual,
            commandBarGroupName: "Inbox",
            commandBarGroupPriority: CommandBarGroupPriority.inbox
        )
    }

    func paneInboxDefinition(
        shortcut: AppShortcut? = nil,
        label: String,
        icon: CommandIcon,
        helpText: String,
        surfacePolicy: AppCommandSurfacePolicy
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            shortcut: shortcut,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: surfacePolicy,
            targeting: .contextualAndTargeted(
                [.pane, .floatingTerminal],
                preferredInvocation: .contextual
            ),
            visibleWhen: [.hasActivePane],
            commandBarGroupName: "Pane",
            commandBarGroupPriority: CommandBarGroupPriority.pane
        )
    }

    func commandBarNavigationDefinition(
        shortcut: AppShortcut? = nil,
        label: String,
        icon: CommandIcon,
        helpText: String,
        surfacePolicy: AppCommandSurfacePolicy
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            shortcut: shortcut,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: surfacePolicy,
            targeting: .contextual,
            commandBarGroupName: "Commands",
            commandBarGroupPriority: CommandBarGroupPriority.miscellaneous
        )
    }

    func bridgeDefinition(
        label: String,
        icon: CommandIcon,
        helpText: String
    ) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: .exposed([.commandBar, .contextMenu]),
            targeting: .contextualAndTargeted(
                [.worktree],
                preferredInvocation: .contextual
            ),
            commandBarGroupName: "Bridge",
            commandBarGroupPriority: CommandBarGroupPriority.bridge
        )
    }

    func authenticationDefinition(providerName: String) -> AppCommandSpec {
        AppCommandSpec(
            command: self,
            label: "Sign in to \(providerName)",
            icon: .system(.personBadgeKey),
            helpText: "Start \(providerName) sign-in",
            surfacePolicy: .notPresented,
            targeting: .contextual,
            commandBarGroupName: "Auth",
            commandBarGroupPriority: CommandBarGroupPriority.auth
        )
    }

    func managementDefinition(shortcut: AppShortcut, label: String, icon: CommandIcon, helpText: String)
        -> AppCommandSpec
    {
        AppCommandSpec(
            command: self,
            shortcut: shortcut,
            label: label,
            icon: icon,
            helpText: helpText,
            surfacePolicy: .notPresented,
            targeting: .contextual,
            requiresManagementLayer: true
        )
    }
}
