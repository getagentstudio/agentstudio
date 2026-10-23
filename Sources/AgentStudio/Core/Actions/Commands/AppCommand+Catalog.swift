import Foundation

// MARK: - AppCommand Helpers

extension AppCommand {
    package var definition: AppCommandSpec {
        switch self {
        case .closeTab:
            return AppCommandSpec(
                command: self,
                shortcut: nil,
                label: "Close Tab",
                icon: .system(.xmark),
                helpText: "Close the active tab",
                surfacePolicy: .exposed([.commandBar, .mainMenu, .contextMenu, .inlineControl]),
                targeting: .contextualAndTargeted([.tab], preferredInvocation: .targetSelection),
                visibleWhen: [.hasActiveTab],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .breakUpTab:
            return AppCommandSpec(
                command: self,
                label: "Split Tab Into Individuals",
                icon: .system(.rectangleSplit3x1),
                helpText: "Split each visible pane in the active tab into its own tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .contextualAndTargeted([.tab], preferredInvocation: .contextual),
                visibleWhen: [.hasActiveTab, .hasMultiplePanes],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .renameTab:
            return AppCommandSpec(
                command: self,
                label: "Rename Tab...",
                icon: .system(.pencil),
                helpText: "Rename the current tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .contextualAndTargeted([.tab], preferredInvocation: .targetSelection),
                visibleWhen: [.hasActiveTab],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .newTerminalInTab:
            return AppCommandSpec(
                command: self,
                label: "Add Terminal to Tab",
                icon: .system(.terminal),
                helpText: "Add a new terminal to the active tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .contextualAndTargeted([.tab], preferredInvocation: .targetSelection),
                visibleWhen: [.hasActiveTab],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .newTab:
            return AppCommandSpec(
                command: self,
                label: "New Tab",
                icon: .system(.plusSquare),
                helpText: "Create a new terminal tab",
                surfacePolicy: .exposed([.commandBar, .mainMenu, .contextMenu, .toolbar(.app)]),
                targeting: .contextual,
                commandBarGroupName: "Window",
                commandBarGroupPriority: CommandBarGroupPriority.window
            )
        case .undoCloseTab:
            return AppCommandSpec(
                command: self,
                shortcut: .undoCloseTab,
                label: "Undo Close",
                icon: .system(.arrowUturnBackward),
                helpText: "Reopen the most recently closed pane or tab",
                surfacePolicy: .exposed([.commandBar, .mainMenu]),
                targeting: .contextual,
                commandBarGroupName: "Window",
                commandBarGroupPriority: CommandBarGroupPriority.window
            )
        case .selectTab:
            return AppCommandSpec(
                command: self,
                label: "Select Tab",
                icon: .system(.rectangleStack),
                helpText: "Select a specific tab",
                surfacePolicy: .notPresented,
                targeting: .targeted([.tab]),
                visibleWhen: [.hasActiveTab],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab,
            )
        case .nextTab:
            return AppCommandSpec(
                command: self,
                shortcut: .nextTab,
                label: "Next Tab",
                icon: .system(.chevronRight),
                helpText: "Move to the next tab",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                visibleWhen: [.hasActiveTab],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .prevTab:
            return AppCommandSpec(
                command: self,
                shortcut: .prevTab,
                label: "Previous Tab",
                icon: .system(.chevronLeft),
                helpText: "Move to the previous tab",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                visibleWhen: [.hasActiveTab],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .selectTab1:
            return menuTabSelectionDefinition(index: 1)
        case .selectTab2:
            return menuTabSelectionDefinition(index: 2)
        case .selectTab3:
            return menuTabSelectionDefinition(index: 3)
        case .selectTab4:
            return menuTabSelectionDefinition(index: 4)
        case .selectTab5:
            return menuTabSelectionDefinition(index: 5)
        case .selectTab6:
            return menuTabSelectionDefinition(index: 6)
        case .selectTab7:
            return menuTabSelectionDefinition(index: 7)
        case .selectTab8:
            return menuTabSelectionDefinition(index: 8)
        case .selectTab9:
            return menuTabSelectionDefinition(index: 9)
        case .closePane:
            return AppCommandSpec(
                command: self,
                label: "Close Pane",
                icon: .system(.xmarkSquare),
                helpText: "Close the active pane",
                surfacePolicy: .exposed([.commandBar, .contextMenu, .inlineControl]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .targetSelection),
                requiresManagementLayer: true,
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .extractPaneToTab:
            return AppCommandSpec(
                command: self,
                label: "Move Pane to New Tab",
                icon: .system(.arrowUpRightSquare),
                helpText: "Move the active pane into a new tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .targetSelection),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .movePaneToTab:
            return AppCommandSpec(
                command: self,
                label: "Move Pane to Existing Tab",
                icon: .system(.arrowLeftArrowRight),
                helpText: "Move the active pane into another existing tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu, .inlineControl]),
                targeting: .targeted([.pane, .tab]),
                requiresManagementLayer: true,
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .focusPane:
            return AppCommandSpec(
                command: self,
                label: "Focus Pane",
                icon: .system(.scope),
                helpText: "Focus a specific pane",
                surfacePolicy: .notPresented,
                targeting: .targeted([.pane, .floatingTerminal]),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane,
            )
        case .scrollToBottom:
            return AppCommandSpec(
                command: self,
                shortcut: .scrollToBottom,
                displayShortcutTrigger: AppShortcut.scrollToBottom.trigger,
                label: "Scroll to Bottom",
                icon: .system(.arrowDownToLine),
                helpText: "Scroll the active terminal pane to the bottom",
                surfacePolicy: .exposed([.commandBar, .inlineControl]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .paneIsTerminal],
                commandBarGroupName: "Terminal",
                commandBarGroupPriority: CommandBarGroupPriority.terminal
            )
        case .scrollPageUp:
            return AppCommandSpec(
                command: self,
                shortcut: .scrollPageUp,
                displayShortcutTrigger: AppShortcut.scrollPageUp.trigger,
                label: "Scroll Up 90%",
                icon: .system(.arrowUp),
                helpText: "Scroll the active terminal pane up by 90% of its viewport",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .paneIsTerminal],
                commandBarGroupName: "Terminal",
                commandBarGroupPriority: CommandBarGroupPriority.terminal
            )
        case .scrollPageDown:
            return AppCommandSpec(
                command: self,
                shortcut: .scrollPageDown,
                displayShortcutTrigger: AppShortcut.scrollPageDown.trigger,
                label: "Scroll Down 90%",
                icon: .system(.arrowDown),
                helpText: "Scroll the active terminal pane down by 90% of its viewport",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .paneIsTerminal],
                commandBarGroupName: "Terminal",
                commandBarGroupPriority: CommandBarGroupPriority.terminal
            )
        case .scrollSmallStepUp:
            return AppCommandSpec(
                command: self,
                shortcut: .scrollSmallStepUp,
                displayShortcutTrigger: AppShortcut.scrollSmallStepUp.trigger,
                label: "Scroll Up 33%",
                icon: .system(.arrowUp),
                helpText: "Scroll the active terminal pane up by 33% of its viewport",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .paneIsTerminal],
                commandBarGroupName: "Terminal",
                commandBarGroupPriority: CommandBarGroupPriority.terminal
            )
        case .scrollSmallStepDown:
            return AppCommandSpec(
                command: self,
                shortcut: .scrollSmallStepDown,
                displayShortcutTrigger: AppShortcut.scrollSmallStepDown.trigger,
                label: "Scroll Down 33%",
                icon: .system(.arrowDown),
                helpText: "Scroll the active terminal pane down by 33% of its viewport",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .paneIsTerminal],
                commandBarGroupName: "Terminal",
                commandBarGroupPriority: CommandBarGroupPriority.terminal
            )
        case .jumpToPreviousPrompt:
            return AppCommandSpec(
                command: self,
                shortcut: .jumpToPreviousPrompt,
                displayShortcutTrigger: AppShortcut.jumpToPreviousPrompt.trigger,
                label: "Previous Prompt",
                icon: .system(.arrowUp),
                helpText: "Jump to the previous shell prompt in terminal scrollback",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .paneIsTerminal],
                commandBarGroupName: "Terminal",
                commandBarGroupPriority: CommandBarGroupPriority.terminal
            )
        case .jumpToNextPrompt:
            return AppCommandSpec(
                command: self,
                shortcut: .jumpToNextPrompt,
                displayShortcutTrigger: AppShortcut.jumpToNextPrompt.trigger,
                label: "Next Prompt",
                icon: .system(.arrowDown),
                helpText: "Jump to the next shell prompt in terminal scrollback",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .paneIsTerminal],
                commandBarGroupName: "Terminal",
                commandBarGroupPriority: CommandBarGroupPriority.terminal
            )
        case .splitRight:
            return AppCommandSpec(
                command: self,
                label: "Split Right",
                icon: .system(.rectangleSplit1x2),
                helpText: "Split the active pane to the right",
                surfacePolicy: .exposed([.commandBar, .contextMenu, .inlineControl]),
                targeting: .contextualAndTargeted(
                    [.pane, .tab],
                    preferredInvocation: .contextual
                ),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .splitLeft:
            return AppCommandSpec(
                command: self,
                label: "Split Left",
                icon: .system(.rectangleSplit1x2),
                helpText: "Split the active pane to the left",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .contextualAndTargeted(
                    [.tab],
                    preferredInvocation: .contextual
                ),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .equalizePanes:
            return AppCommandSpec(
                command: self,
                label: "Equalize Panes",
                icon: .system(.equalSquare),
                helpText: "Reset all pane sizes in the active tab to equal widths",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .contextualAndTargeted(
                    [.tab],
                    preferredInvocation: .contextual
                ),
                visibleWhen: [.hasActiveTab, .hasMultiplePanes],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .focusPaneLeft:
            return focusDefinition(
                label: "Focus Pane Left",
                icon: .system(.arrowLeft),
                helpText: "Move focus to the pane on the left"
            )
        case .focusPaneRight:
            return focusDefinition(
                label: "Focus Pane Right",
                icon: .system(.arrowRight),
                helpText: "Move focus to the pane on the right"
            )
        case .focusPaneUp:
            return focusDefinition(
                label: "Focus Pane Up",
                icon: .system(.arrowUp),
                helpText: "Move focus to the pane above"
            )
        case .focusPaneDown:
            return focusDefinition(
                label: "Focus Pane Down",
                icon: .system(.arrowDown),
                helpText: "Move focus to the pane below"
            )
        case .focusPreviousPinnedPane, .focusNextPinnedPane:
            return AppCommandSpec(
                command: self,
                shortcut: self == .focusPreviousPinnedPane ? .focusPreviousPinnedPane : .focusNextPinnedPane,
                label: self == .focusPreviousPinnedPane ? "Previous Pinned Pane" : "Next Pinned Pane",
                icon: .system(self == .focusPreviousPinnedPane ? .arrowUp : .arrowDown),
                helpText: "Navigate pinned panes in sidebar order across the workspace",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Focus",
                commandBarGroupPriority: CommandBarGroupPriority.focus
            )
        case .focusNextPane:
            return focusDefinition(
                label: "Focus Next Pane",
                icon: .system(.arrowRightCircle),
                helpText: "Move focus to the next pane"
            )
        case .focusPrevPane:
            return focusDefinition(
                label: "Focus Previous Pane",
                icon: .system(.arrowLeftCircle),
                helpText: "Move focus to the previous pane"
            )
        case .focusPane1:
            return shortcutFocusPaneDefinition(index: 1)
        case .focusPane2:
            return shortcutFocusPaneDefinition(index: 2)
        case .focusPane3:
            return shortcutFocusPaneDefinition(index: 3)
        case .focusPane4:
            return shortcutFocusPaneDefinition(index: 4)
        case .focusPane5:
            return shortcutFocusPaneDefinition(index: 5)
        case .focusPane6:
            return shortcutFocusPaneDefinition(index: 6)
        case .focusPane7:
            return shortcutFocusPaneDefinition(index: 7)
        case .focusPane8:
            return shortcutFocusPaneDefinition(index: 8)
        case .focusPane9:
            return shortcutFocusPaneDefinition(index: 9)
        case .zoomPane:
            return AppCommandSpec(
                command: self,
                shortcut: .zoomPane,
                label: "Pane Zoom",
                icon: .system(.squareArrowTriangle4Outward),
                helpText: "Zoom the active pane",
                surfacePolicy: .exposed([
                    .contextMenu, .commandBar, .toolbar(.pane), .toolbar(.terminalZoom), .inlineControl,
                ]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.supportsTerminalZoom],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .minimizePane:
            return AppCommandSpec(
                command: self,
                label: "Minimize Pane",
                icon: .system(.minusCircle),
                helpText: "Minimize the active pane",
                surfacePolicy: .exposed([.commandBar, .inlineControl]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .expandPane:
            return AppCommandSpec(
                command: self,
                label: "Expand Pane",
                icon: .system(.arrowUpLeftAndArrowDownRight),
                helpText: "Expand a minimized pane back into the layout",
                surfacePolicy: .exposed([.commandBar, .contextMenu, .inlineControl]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .switchArrangement:
            return arrangementDefinition(
                shortcut: .showArrangementPanel,
                label: "Show Arrangements",
                icon: LocalActionSpec.arrangements.actionSpec.icon,
                helpText: "Show arrangements for the active tab",
                surfacePolicy: .exposed([
                    .commandBar,
                    .toolbar(.app),
                    .inlineControl,
                ]),
                targeting: .contextualAndTargeted(
                    [.tab],
                    preferredInvocation: .targetSelection
                )
            )
        case .previousArrangement:
            return AppCommandSpec(
                command: self,
                shortcut: .previousArrangement,
                label: "Previous Arrangement",
                icon: .system(.chevronLeft),
                helpText: "Switch the active tab to the previous arrangement",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.tab], preferredInvocation: .contextual),
                visibleWhen: [.hasActiveTab, .hasArrangements],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .nextArrangement:
            return AppCommandSpec(
                command: self,
                shortcut: .nextArrangement,
                label: "Next Arrangement",
                icon: .system(.chevronRight),
                helpText: "Switch the active tab to the next arrangement",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.tab], preferredInvocation: .contextual),
                visibleWhen: [.hasActiveTab, .hasArrangements],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .cycleArrangement:
            return AppCommandSpec(
                command: self,
                label: "Cycle Arrangement",
                icon: LocalActionSpec.arrangements.actionSpec.icon,
                helpText: "Switch to the next arrangement in the active tab",
                surfacePolicy: .notPresented,
                targeting: .contextual,
                visibleWhen: [.hasActiveTab, .hasArrangements],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab,
            )
        case .saveArrangement:
            return AppCommandSpec(
                command: self,
                label: "Save Arrangement As...",
                icon: LocalActionSpec.arrangements.actionSpec.icon,
                helpText: "Save the current tab layout as a named arrangement",
                surfacePolicy: .exposed([.commandBar, .contextMenu, .inlineControl]),
                targeting: .contextualAndTargeted([.tab], preferredInvocation: .contextual),
                visibleWhen: [.hasActiveTab],
                commandBarGroupName: "Tab",
                commandBarGroupPriority: CommandBarGroupPriority.tab
            )
        case .deleteArrangement:
            return arrangementDefinition(
                label: "Delete Arrangement",
                icon: LocalActionSpec.arrangements.actionSpec.icon,
                helpText: "Delete a saved arrangement from the active tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .targeted([.tab])
            )
        case .renameArrangement:
            return arrangementDefinition(
                label: "Rename Arrangement",
                icon: .system(.pencil),
                helpText: "Rename a saved arrangement in the active tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu, .inlineControl]),
                targeting: .targeted([.tab])
            )
        case .enterDrawer:
            return AppCommandSpec(
                command: self,
                label: "Enter Drawer",
                icon: .system(.rectangleBottomhalfFilled),
                helpText: "Open the active pane and focus its selected pane",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .focusDrawerPaneUp, .focusDrawerPaneLeft, .focusDrawerPaneDown, .focusDrawerPaneRight:
            let displayShortcutTrigger: ShortcutTrigger =
                switch self {
                case .focusDrawerPaneUp:
                    .init(key: .character(.i), modifiers: [.option])
                case .focusDrawerPaneLeft:
                    .init(key: .character(.j), modifiers: [.option])
                case .focusDrawerPaneDown:
                    .init(key: .character(.k), modifiers: [.option])
                case .focusDrawerPaneRight:
                    .init(key: .character(.l), modifiers: [.option])
                default:
                    .init(key: .character(.j), modifiers: [.option])
                }
            return AppCommandSpec(
                command: self,
                displayShortcutTrigger: displayShortcutTrigger,
                label: "Move Drawer Focus",
                icon: .system(.arrowUpLeftAndArrowDownRight),
                helpText: "Move selection within the active pane",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                visibleWhen: [.hasActivePane, .hasFocusedDrawerPane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .focusDrawerPane1:
            return shortcutFocusDrawerPaneDefinition(index: 1)
        case .focusDrawerPane2:
            return shortcutFocusDrawerPaneDefinition(index: 2)
        case .focusDrawerPane3:
            return shortcutFocusDrawerPaneDefinition(index: 3)
        case .focusDrawerPane4:
            return shortcutFocusDrawerPaneDefinition(index: 4)
        case .focusDrawerPane5:
            return shortcutFocusDrawerPaneDefinition(index: 5)
        case .focusDrawerPane6:
            return shortcutFocusDrawerPaneDefinition(index: 6)
        case .focusDrawerPane7:
            return shortcutFocusDrawerPaneDefinition(index: 7)
        case .focusDrawerPane8:
            return shortcutFocusDrawerPaneDefinition(index: 8)
        case .focusDrawerPane9:
            return shortcutFocusDrawerPaneDefinition(index: 9)
        case .detachDrawerPane:
            return AppCommandSpec(
                command: self,
                label: "Detach Drawer Pane",
                icon: .system(.rectanglePortraitAndArrowRight),
                helpText: "Promote the selected drawer pane into the main layout",
                surfacePolicy: .exposed([.inlineControl]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane, .hasFocusedDrawerPane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane,
            )
        case .addDrawerPane:
            return AppCommandSpec(
                command: self,
                shortcut: .addDrawerPane,
                label: "Add Drawer Pane",
                icon: LocalActionSpec.addDrawerPane.actionSpec.icon,
                helpText: "Add a drawer pane to the active pane",
                surfacePolicy: .exposed([.commandBar, .toolbar(.pane), .toolbar(.terminalZoom), .inlineControl]),
                targeting: .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .toggleDrawer:
            return AppCommandSpec(
                command: self,
                shortcut: .toggleDrawer,
                label: "Toggle Drawer",
                icon: .system(.rectangleBottomhalfFilled),
                helpText: "Expand or collapse the active pane drawer",
                surfacePolicy: .exposed([.commandBar, .toolbar(.pane), .toolbar(.terminalZoom)]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .moveZoomDrawerToTerminal:
            return AppCommandSpec(
                command: self,
                label: "Move Drawer to Terminal",
                icon: .system(.arrowLeft),
                helpText: "Place the Pane Zoom drawer over the terminal",
                surfacePolicy: .exposed([.commandBar, .inlineControl]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActiveTerminalZoom],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .moveZoomDrawerToBridge:
            return AppCommandSpec(
                command: self,
                label: "Move Drawer to Worktree Viewer",
                icon: .system(.arrowRight),
                helpText: "Place the Pane Zoom drawer over the Worktree Viewer",
                surfacePolicy: .exposed([.commandBar, .inlineControl]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActiveTerminalZoom],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .navigateDrawerPane:
            return AppCommandSpec(
                command: self,
                label: "Switch Drawer Pane",
                icon: .system(.arrowDownToLine),
                helpText: "Switch to a pane inside the active pane",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .targetSelection),
                visibleWhen: [.hasActivePane, .hasDrawerPanes],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .closeDrawerPane:
            return AppCommandSpec(
                command: self,
                label: "Close Drawer Pane",
                icon: .system(.xmarkRectanglePortrait),
                helpText: "Close a pane inside the active pane",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                visibleWhen: [.hasActivePane, .hasDrawerPanes],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .watchFolder:
            return AppCommandSpec(
                command: self,
                label: "Watch Folder",
                icon: .system(.folderFillBadgePlus),
                helpText: "Watch a folder and scan it for repositories",
                surfacePolicy: .exposed([.commandBar, .toolbar(.app), .inlineControl]),
                targeting: .contextual,
                commandBarGroupName: "Repo",
                commandBarGroupPriority: CommandBarGroupPriority.repo
            )
        case .updateRepositoryFacts:
            return repositoryFactUpdateDefinition()
        case .removeRepo:
            return AppCommandSpec(
                command: self,
                label: "Remove Repo",
                icon: .system(.folderBadgeMinus),
                helpText: "Remove a repository from the workspace",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .targeted([.repo]),
                commandBarGroupName: "Repo",
                commandBarGroupPriority: CommandBarGroupPriority.repo
            )
        case .pinRepo: return pinRepoDefinition()
        case .unpinRepo: return unpinRepoDefinition()
        case .pinPane: return pinPaneDefinition()
        case .unpinPane: return unpinPaneDefinition()
        case .openWorktree:
            return worktreeDefinition(
                label: "Open Worktree",
                icon: .system(.terminal),
                helpText: "Open a worktree in a tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu, .inlineControl])
            )
        case .openWorktreeInPane:
            return worktreeDefinition(
                label: "Open Worktree in Pane",
                icon: .system(.rectangleSplit2x1),
                helpText: "Open a worktree in a split pane",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targetTypes: [.worktree, .pane]
            )
        case .newWorktree: return newWorktreeDefinition()
        case .newWorktreeFromDefault: return newWorktreeFromDefaultDefinition()
        case .newWorktreeFromBranch: return newWorktreeFromBranchDefinition()
        case .forkWorktree: return forkWorktreeDefinition()
        case .openPaneLocationInBookmarkedEditor:
            return AppCommandSpec(
                command: self,
                shortcut: .openPaneLocationInBookmarkedEditor,
                label: "Open Pane Location in Bookmarked Editor",
                icon: .system(.chevronLeftForwardslashChevronRight),
                helpText: "Open the selected pane location in the bookmarked editor",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .openPaneLocationInFinder:
            return AppCommandSpec(
                command: self,
                shortcut: .openPaneLocationInFinder,
                label: "Open Pane Location in Finder",
                icon: LocalActionSpec.revealInFinder.actionSpec.icon,
                helpText: "Open the selected pane location in Finder",
                surfacePolicy: .exposed([.contextMenu, .commandBar, .toolbar(.pane), .toolbar(.terminalZoom)]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .openPaneLocationInEditorMenu:
            return AppCommandSpec(
                command: self,
                shortcut: .openPaneLocationInEditorMenu,
                label: "Open In Menu",
                icon: .system(.chevronLeftForwardslashChevronRight),
                helpText: "Open the editor chooser for the selected pane",
                surfacePolicy: .exposed([.contextMenu, .commandBar, .toolbar(.pane), .toolbar(.terminalZoom)]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .editPaneNote:
            return AppCommandSpec(
                command: self,
                shortcut: .editPaneNote,
                label: "Edit Pane Note",
                icon: .system(.pencil),
                helpText: "Set a note for the current pane",
                surfacePolicy: .exposed([.contextMenu, .commandBar, .toolbar(.pane), .toolbar(.terminalZoom)]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .copyCurrentPanePath:
            return AppCommandSpec(
                command: self,
                shortcut: .copyCurrentPanePath,
                label: "Copy Current Pane Path",
                icon: LocalActionSpec.copyPath.actionSpec.icon,
                helpText: "Copy the current pane path",
                surfacePolicy: .exposed([.contextMenu, .commandBar, .toolbar(.pane), .toolbar(.terminalZoom)]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.hasActivePane],
                commandBarGroupName: "Pane",
                commandBarGroupPriority: CommandBarGroupPriority.pane
            )
        case .openPullRequest:
            return AppCommandSpec(
                command: self,
                label: "Open PR",
                icon: .octicon(.gitPullRequest),
                helpText: "Open PR in Browser",
                surfacePolicy: .exposed([.toolbar(.pane), .toolbar(.terminalZoom)]),
                targeting: .targeted([.pane])
            )
        case .toggleManagementLayer: return toggleManagementLayerDefinition()
        case .managementLayerFocusLeft: return managementLayerFocusLeftDefinition()
        case .managementLayerFocusRight: return managementLayerFocusRightDefinition()
        case .managementLayerEnterDrawer: return managementLayerEnterDrawerDefinition()
        case .managementLayerExitDrawer: return managementLayerExitDrawerDefinition()
        case .managementLayerOpenDrawer: return managementLayerOpenDrawerDefinition()
        case .managementLayerCreateTerminal: return managementLayerCreateTerminalDefinition()
        case .managementLayerCreateBrowser: return managementLayerCreateBrowserDefinition()
        case .managementLayerExit: return managementLayerExitDefinition()
        case .toggleSidebar:
            return windowDefinition(
                shortcut: .toggleSidebar,
                label: "Toggle Sidebar",
                icon: .system(.sidebarLeft),
                helpText: "Show or hide the sidebar",
                surfacePolicy: .exposed([.commandBar, .toolbar(.app)]),
                targeting: .contextual
            )
        case .focusSidebar: return focusSidebarDefinition()
        case .showInboxNotifications: return showInboxNotificationsDefinition()
        case .toggleInboxNotificationSort: return toggleInboxNotificationSortDefinition()
        case .clearReadInboxNotifications: return clearReadInboxNotificationsDefinition()
        case .clearAllInboxNotifications: return clearAllInboxNotificationsDefinition()
        case .showPaneInboxNotifications: return showPaneInboxNotificationsDefinition()
        case .clearPaneInboxNotifications: return clearPaneInboxNotificationsDefinition()
        case .showReposSidebar: return showReposSidebarDefinition()
        case .showPanesSidebar: return showPanesSidebarDefinition()
        case .setReposGroupingRepo: return setReposGroupingRepoDefinition()
        case .setReposGroupingActivity: return setReposGroupingActivityDefinition()
        case .setPanesSortFieldName, .setPanesSortFieldActivity, .togglePanesSortDirection:
            return retiredPanesOrganizationDefinition()
        case .setReposSortFieldName: return setReposSortFieldNameDefinition()
        case .setReposSortFieldActivity: return setReposSortFieldActivityDefinition()
        case .toggleReposSortDirection: return toggleReposSortDirectionDefinition()
        case .toggleReposShowsPinned: return toggleReposShowsPinnedDefinition()
        case .togglePanesShowsPinned: return togglePanesShowsPinnedDefinition()
        case .togglePanesShowsDrawers: return togglePanesShowsDrawersDefinition()
        case .setInboxGroupingTab: return setInboxGroupingTabDefinition()
        case .setInboxGroupingRepo: return setInboxGroupingRepoDefinition()
        case .setInboxGroupingPane: return setInboxGroupingPaneDefinition()
        case .setInboxGroupingNone: return setInboxGroupingNoneDefinition()
        case .setInboxRowStateFilter: return setInboxRowStateFilterDefinition()
        case .setInboxContentMode: return setInboxContentModeDefinition()
        case .newFloatingTerminal:
            return windowDefinition(
                label: "New Floating Terminal",
                icon: .system(.terminalFill),
                helpText: "Open a new floating terminal",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targeting: .contextualAndTargeted(
                    [.tab],
                    preferredInvocation: .contextual
                )
            )
        case .newWindow:
            return windowDefinition(
                shortcut: .newWindow,
                label: "New Window",
                icon: .system(.macwindowBadgePlus),
                helpText: "Open a new application window",
                surfacePolicy: .exposed([.mainMenu]),
                targeting: .contextual
            )
        case .closeWindow:
            return windowDefinition(
                shortcut: nil,
                label: "Close Window",
                icon: .system(.xmarkRectangle),
                helpText: "Close the current application window",
                surfacePolicy: .exposed([.mainMenu]),
                targeting: .contextual
            )
        case .showCommandBarEverything:
            return commandBarNavigationDefinition(
                shortcut: .showCommandBarEverything,
                label: "Quick Find",
                icon: .system(.magnifyingglass),
                helpText: "Open quick find",
                surfacePolicy: .exposed([.commandBar, .mainMenu, .inlineControl])
            )
        case .showCommandBarQuickOpen:
            return commandBarNavigationDefinition(
                shortcut: .newTab,
                label: "Quick Open",
                icon: .system(.terminal),
                helpText: "Open a terminal at a repository or worktree",
                surfacePolicy: .exposed([.commandBar])
            )
        case .showCommandBarCommands:
            return commandBarNavigationDefinition(
                shortcut: .showCommandBarCommands,
                label: "Command Palette",
                icon: .system(.command),
                helpText: "Open the command palette",
                surfacePolicy: .exposed([.commandBar, .mainMenu])
            )
        case .showCommandBarPanes:
            return commandBarNavigationDefinition(
                shortcut: .showCommandBarPanes,
                label: "Go to Pane",
                icon: .system(.terminal),
                helpText: "Open the pane picker",
                surfacePolicy: .exposed([.commandBar, .mainMenu])
            )
        case .showCommandBarRepos:
            return commandBarNavigationDefinition(
                label: "Repositories",
                icon: .system(.folder),
                helpText: "Open the repository navigator",
                surfacePolicy: .exposed([.commandBar, .mainMenu, .contextMenu, .inlineControl])
            )
        case .openWebview:
            return openWebviewDefinition()
        case .reloadBridgeWebView:
            return bridgeWebViewReloadDefinition()
        case .showViewer:
            return AppCommandSpec(
                command: self,
                shortcut: .showViewer,
                label: "Worktree Viewer",
                icon: .system(.textPageBadgeMagnifyingglass),
                helpText: "Show or hide the Worktree Viewer in Pane Zoom",
                surfacePolicy: .exposed([.commandBar, .toolbar(.terminalZoom)]),
                targeting: .contextualAndTargeted([.pane], preferredInvocation: .contextual),
                visibleWhen: [.supportsTerminalZoom],
                commandBarGroupName: "Worktree Viewer",
                commandBarGroupPriority: CommandBarGroupPriority.worktreeViewer
            )
        case .showBridgeReview:
            return bridgeDefinition(
                label: "Review",
                icon: .system(.rectangleSplit2x1),
                helpText: "Open the read-only review in a tab"
            )
        case .showBridgeFiles:
            return bridgeDefinition(
                label: "Files",
                icon: .system(.folder),
                helpText: "Open the worktree file viewer in a tab"
            )
        case .openBridgeReviewInNewTab:
            return bridgeDefinition(
                label: "Open Review in New Tab",
                icon: .system(.rectangleSplit2x1),
                helpText: "Open an independent read-only review in a new tab"
            )
        case .openBridgeFilesInNewTab:
            return bridgeDefinition(
                label: "Open Files in New Tab",
                icon: .system(.folder),
                helpText: "Open an independent worktree file viewer in a new tab"
            )
        case .copyAgentSetupPrompt:
            return AppCommandSpec(
                command: self,
                label: "Copy Agent Setup Prompt",
                icon: .system(.documentOnDocument),
                helpText: "Copy a prompt for an agent to set up Agent Studio provider hooks",
                surfacePolicy: .exposed([.commandBar]),
                targeting: .contextual,
                commandBarGroupName: "Agent",
                commandBarGroupPriority: CommandBarGroupPriority.miscellaneous)
        case .signInGitHub:
            return authenticationDefinition(providerName: "GitHub")
        case .signInGoogle:
            return authenticationDefinition(providerName: "Google")
        case .filterSidebar:
            return windowDefinition(
                shortcut: .filterSidebar,
                label: "Filter Sidebar",
                icon: .system(.magnifyingglass),
                helpText: "Filter items in the sidebar",
                surfacePolicy: .exposed([.commandBar, .mainMenu]),
                targeting: .contextual
            )
        case .openNewTerminalInTab:
            return worktreeDefinition(
                label: "Open Terminal in New Tab",
                icon: .system(.terminalFill),
                helpText: "Open a worktree in a fresh terminal tab",
                surfacePolicy: .exposed([.commandBar, .contextMenu]),
                targetTypes: [.worktree, .pane]
            )
        }
    }
}
