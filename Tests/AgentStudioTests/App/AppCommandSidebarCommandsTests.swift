import AgentStudioProgrammaticControl
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSharedComponents

@MainActor
@Suite("AppCommand sidebar commands")
struct AppCommandSidebarCommandsTests {
    @Test("retired Panes grouping command identities are absent")
    func retiredPanesGroupingCommandsAreAbsent() {
        for identifier in [
            "setPanesGroupingRepo", "setPanesGroupingTab", "setPanesGroupingActivity",
            "setPanesSubgroupNone", "setPanesSubgroupActivity",
        ] {
            #expect(AppCommand(rawValue: identifier) == nil)
        }
    }

    @Test("focus sidebar is an interactive UI-presentation command")
    func focusSidebarIsInteractiveUIPresentationCommand() {
        let definition = AppCommand.focusSidebar.definition

        #expect(definition.label == "Focus Sidebar")
        #expect(definition.icon == .system(.keyboard))
        #expect(definition.shortcut == .focusSidebar)
        #expect(definition.surfacePolicy == .exposed([.commandBar, .inlineControl]))
        #expect(definition.targeting == .contextual)
    }

    @Test("sidebar settings expose compact surface-specific command specs")
    func sidebarSettingsExposeCompactSurfaceSpecificCommandSpecs() {
        let expectedCommands: [(AppCommand, String, CommandIcon)] = [
            (.showReposSidebar, "Repos", .octicon(.repo)),
            (.showPanesSidebar, "Panes", .system(.squareSplit2x1)),
            (.setReposGroupingRepo, "Repo", .octicon(.repo)),
            (.setReposGroupingActivity, "Activity", .system(.clock)),
            (.setReposSortFieldName, "Name", .system(.line3Horizontal)),
            (.setReposSortFieldActivity, "Activity", .system(.clock)),
            (.toggleReposSortDirection, "Direction", .system(.arrowUpArrowDown)),
            (.toggleReposShowsPinned, "Show Pinned", .system(.pin)),
            (.togglePanesShowsPinned, "Show Pinned", .system(.pin)),
            (.togglePanesShowsDrawers, "Show Drawers", .system(.rectangleBottomhalfFilled)),
        ]

        for (command, label, icon) in expectedCommands {
            let definition = command.definition
            #expect(definition.label == label)
            #expect(definition.icon == icon)
            #expect(definition.surfacePolicy.exposes(.inlineControl))
            #expect(definition.targeting == .contextual)
        }
    }

    @Test("drawer visibility is a scoped UI command with debug IPC classification")
    func drawerVisibilityCommandClassification() {
        let command = AppCommand.togglePanesShowsDrawers
        let definition = command.definition

        #expect(definition.shortcut == .togglePanesShowsDrawers)
        #expect(definition.icon == .system(.rectangleBottomhalfFilled))
        #expect(AppEntityIcon.drawer.symbolName == "rectangle.bottomhalf.filled")
        #expect(definition.helpText == "Show or hide drawer panes in the Panes sidebar")
        #expect(definition.surfacePolicy == .exposed([.commandBar, .inlineControl]))
        #expect(command.ipcSpec.exposure == .debugTesting)
        #expect(command.ipcSpec.argumentVariants == [.workspaceWindow])
        #expect(command.ipcSpec.resultVariants == [.applied])
    }

    @Test("sidebar command specs own keyboard completion after accepted dispatch")
    func sidebarCommandSpecsOwnKeyboardCompletion() {
        #expect(
            AppCommand.showReposSidebar.definition.sidebarKeyboardCompletion
                == .returnToOrigin
        )
        #expect(
            AppCommand.showPanesSidebar.definition.sidebarKeyboardCompletion
                == .returnToOrigin
        )
        #expect(
            AppCommand.filterSidebar.definition.sidebarKeyboardCompletion
                == .preserveCommandFocus
        )
    }

    @Test("fixed Panes organization has no interactive or IPC setting commands")
    func fixedPanesOrganizationHasNoSettingCommands() {
        for command in [
            AppCommand.setPanesSortFieldName, .setPanesSortFieldActivity, .togglePanesSortDirection,
        ] {
            let definition = command.definition
            #expect(definition.surfacePolicy == .notPresented)
        }
    }

    @Test("repository and pane pin commands keep independent durable targets")
    func repositoryAndPanePinCommandsKeepIndependentDurableTargets() {
        for command in [AppCommand.pinRepo, .unpinRepo] {
            let definition = command.definition
            #expect(definition.targeting == .targeted([.repo]))
        }
        for command in [AppCommand.pinPane, .unpinPane] {
            let definition = command.definition
            #expect(definition.targeting == .targeted([.pane]))
        }
    }

}
