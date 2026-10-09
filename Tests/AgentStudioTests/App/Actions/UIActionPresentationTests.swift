import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@MainActor
@Suite
struct UIActionPresentationTests {
    @Test
    func detachDrawerPaneCommandDefinition_hasStablePresentation() {
        let definition = AppCommand.detachDrawerPane.definition

        #expect(definition.label == "Detach Drawer Pane")
        #expect(definition.helpText == "Promote the selected drawer pane into the main layout")
        #expect(definition.icon == .system(.rectanglePortraitAndArrowRight))
    }

    @Test
    func controlToolTip_withShortcutAndNoOverride_usesLabelAndShortcut() {
        let toolTip = AppCommand.openPaneLocationInEditorMenu.definition.controlToolTip

        #expect(toolTip == "Open In Menu (⌘⌥⌃O)")
    }

    @Test
    func controlToolTip_withDisplayShortcutTrigger_usesLabelAndDisplayShortcut() {
        let toolTip = AppCommand.focusDrawerPaneUp.definition.controlToolTip

        #expect(toolTip == "Move Drawer Focus (⌥I)")
    }

    @Test
    func controlToolTip_withoutShortcutAndNoOverride_usesHelpText() {
        let definition = AppCommandSpec(
            command: .renameArrangement,
            label: "Rename Arrangement",
            icon: .system(.pencil),
            helpText: "Rename the current arrangement",
            surfacePolicy: .notPresented,
            targeting: .contextual
        )

        #expect(definition.controlToolTip == "Rename the current arrangement")
    }

    @Test
    func controlToolTip_withOverrideAndShortcut_usesOverrideAndShortcut() {
        let toolTip = AppCommand.openPaneLocationInEditorMenu.definition.controlToolTip(
            textOverride: "Open in Editor"
        )

        #expect(toolTip == "Open in Editor (⌘⌥⌃O)")
    }

    @Test
    func controlToolTip_withOverrideAndNoShortcut_usesOverrideOnly() {
        let definition = AppCommandSpec(
            command: .renameArrangement,
            label: "Rename Arrangement",
            icon: .system(.pencil),
            helpText: "Rename the current arrangement",
            surfacePolicy: .notPresented,
            targeting: .contextual
        )

        let toolTip = definition.controlToolTip(textOverride: "Rename")

        #expect(toolTip == "Rename")
    }

    @Test
    func controlToolTip_includeShortcutFalse_suppressesShortcut() {
        let toolTip = AppCommand.openPaneLocationInEditorMenu.definition.controlToolTip(
            textOverride: "Open in Editor",
            includeShortcut: false
        )

        #expect(toolTip == "Open in Editor")
    }

    @Test
    func controlToolTip_withShortcutOverride_usesOverrideShortcut() {
        let toolTip = AppCommand.toggleInboxNotificationSort.definition.controlToolTip(
            textOverride: "Sort inbox",
            shortcutTextOverride: ShortcutDisplayText(value: "⌥S")
        )

        #expect(toolTip == "Sort inbox (⌥S)")
    }

    @Test
    func actionSpecControlToolTip_withOverrideAndShortcut_usesCompactText() {
        let toolTip = LocalActionSpec.groupInboxNotifications.actionSpec.controlToolTip(
            textOverride: "Group",
            shortcutText: ShortcutDisplayText(value: "⌥G")
        )

        #expect(toolTip == "Group (⌥G)")
    }

    @Test("repo explorer organization roles use local-action display metadata")
    func repoExplorerOrganizationRolesUseLocalActionDisplayMetadata() {
        let group = LocalActionSpec.groupRepoExplorerWorktrees.actionSpec
        let subgroup = LocalActionSpec.subgroupRepoExplorerWorktrees.actionSpec

        #expect(group.label == "Group")
        #expect(group.helpText == "Choose how sidebar items are grouped")
        #expect(group.icon == .system(.square2Layers3d))
        #expect(LocalActionSpec.showRepoExplorerOrganization.actionSpec.icon == .system(.sliderHorizontal3))
        #expect(subgroup.icon == .system(.listBulletIndent))
        #expect(subgroup.label == "Subgroup")
        #expect(subgroup.helpText == "Choose how sidebar items are subgrouped")
    }

    @Test("preview pane owns the transient Space hint presentation")
    func previewPaneOwnsTransientSpaceHintPresentation() {
        let preview = LocalActionSpec.previewPane.actionSpec

        #expect(preview.label == "Preview Pane")
        #expect(preview.helpText == "Preview the selected pane while holding Space")
        #expect(preview.icon == .system(.eye))
    }

    @Test
    func drawerFinderToolTip_usesOverrideWithShortcut() {
        let toolTip = AppCommand.openPaneLocationInFinder.definition.controlToolTip(
            textOverride: "Open in Finder"
        )

        #expect(toolTip == "Open in Finder (⌘⇧O)")
    }

    @Test
    func retiredPaneInboxToolTip_hasNoShortcut() {
        let toolTip = AppCommand.showPaneInboxNotifications.definition.controlToolTip(
            textOverride: "Open pane inbox"
        )

        #expect(toolTip == "Open pane inbox")
    }

    @Test
    func actionSpec_preservesTypedCommandIcons() {
        #expect(AppCommand.watchFolder.definition.icon == .system(.folderFillBadgePlus))
        #expect(AppCommand.watchFolder.definition.actionSpec.icon == .system(.folderFillBadgePlus))
    }

    @Test
    func refreshAndReloadUseClockwiseArrow() {
        #expect(LocalActionSpec.refreshWorktrees.actionSpec.icon == .system(.arrowClockwise))
        #expect(LocalActionSpec.browserReload.actionSpec.icon == .system(.arrowClockwise))
    }

    @Test
    func copyPathUsesDocumentOnDocumentEverywhere() {
        #expect(LocalActionSpec.copyPath.actionSpec.icon == .system(.documentOnDocument))
        #expect(AppCommand.copyCurrentPanePath.definition.icon == .system(.documentOnDocument))
    }

    @Test
    func worktreeTabActionsUseTerminalAndBridgeLabels() {
        #expect(LocalActionSpec.createNewInTab.actionSpec.label == "Create New in Tab")
        #expect(LocalActionSpec.createNewInPane.actionSpec.label == "Create New in Pane")
        #expect(LocalActionSpec.openInEditorMenu.actionSpec.label == "Open in Editor")
        #expect(AppCommand.openPullRequest.definition.actionSpec.label == "Open PR")
        #expect(AppCommand.openPullRequest.definition.actionSpec.helpText == "Open PR in Browser")
        #expect(AppCommand.openPullRequest.definition.actionSpec.icon == .octicon(.gitPullRequest))
        #expect(AppCommand.openWorktreeInPane.definition.actionSpec.label == "Open Worktree in Pane")
        #expect(AppCommand.openNewTerminalInTab.definition.actionSpec.label == "Open Terminal in New Tab")
        #expect(AppCommand.showViewer.definition.actionSpec.label == "Worktree Viewer")
        #expect(AppCommand.showBridgeReview.definition.actionSpec.label == "Review")
        #expect(AppCommand.showBridgeFiles.definition.actionSpec.label == "Files")
        #expect(AppCommand.openBridgeReviewInNewTab.definition.actionSpec.label == "Open Review in New Tab")
        #expect(AppCommand.openBridgeFilesInNewTab.definition.actionSpec.label == "Open Files in New Tab")
    }

    @Test
    func paneShowArrangementsPreservesPresentationWithoutChangingSharedArrangementMenus() {
        let paneAction = LocalActionSpec.showArrangements.actionSpec
        let sharedMenuAction = LocalActionSpec.arrangements.actionSpec

        #expect(paneAction.label == "Show Arrangements")
        #expect(paneAction.helpText == "Show arrangements for the active tab")
        #expect(paneAction.icon == .system(.rectangle3GroupFill))
        #expect(sharedMenuAction.label == "Arrangements")
        #expect(sharedMenuAction.helpText == "Manage tab arrangements")
        #expect(sharedMenuAction.icon == .system(.rectangle3GroupFill))
    }
}
