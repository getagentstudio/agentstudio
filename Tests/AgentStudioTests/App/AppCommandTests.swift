import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCommandBar
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

private struct TerminalCommandPresentationExpectation {
    let command: AppCommand
    let shortcut: AppShortcut
    let label: String
    let helpText: String
}

@MainActor
final class MockAppCommandRouter: ShellCommandHandling {
    var handledCommands: [AppCommand] = []
    var handledTargets: [(AppCommand, UUID, SearchItemType)] = []
    var handledRequests: [AppCommandExecutionRequest] = []
    var appCommands: Set<AppCommand> = []
    var requestCommands: Set<AppCommand>?
    var requestCapabilityCommands: Set<AppCommand> = []
    var parameterlessCanExecuteResult: Bool?

    func canExecute(_ command: AppCommand) -> Bool {
        parameterlessCanExecuteResult ?? appCommands.contains(command)
    }

    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        _ = target
        _ = targetType
        return canExecute(command)
    }

    func canExecute(_ request: AppCommandExecutionRequest) -> Bool {
        requestCapabilityCommands.contains(request.command)
    }

    func execute(_ command: AppCommand) -> Bool {
        guard appCommands.contains(command) else { return false }
        handledCommands.append(command)
        return true
    }

    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        guard appCommands.contains(command) else { return false }
        handledTargets.append((command, target, targetType))
        return true
    }

    func execute(_ request: AppCommandExecutionRequest) -> AppCommandExecutionOutcome {
        guard (requestCommands ?? appCommands).contains(request.command) else { return .unsupportedCommand }
        handledRequests.append(request)
        return .applied
    }

    func showRepoCommandBar() {}

    func refreshWorktrees() {}

    func refocusActivePane() {}
}

// MARK: - AppCommand Tests

@MainActor
@Suite(.serialized)
final class AppCommandTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    // MARK: - AppCommand Enum

    @Test
    func test_appCommand_allCases_notEmpty() {
        // Assert
        #expect(!(AppCommand.allCases.isEmpty))
    }

    @Test
    func test_appCommand_rawValues_unique() {
        // Arrange
        let rawValues = AppCommand.allCases.map(\.rawValue)
        let uniqueValues = Set(rawValues)

        // Assert
        #expect(rawValues.count == uniqueValues.count)
    }

    @Test
    func launcherCommandsExposeInlineControlSurface() {
        #expect(
            AppCommand.showCommandBarEverything.definition.surfacePolicy
                .exposes(.inlineControl)
        )
        #expect(
            AppCommand.showCommandBarRepos.definition.surfacePolicy
                .exposes(.inlineControl)
        )
        #expect(
            AppCommand.watchFolder.definition.surfacePolicy
                .exposes(.inlineControl)
        )
    }

    // MARK: - SearchItemType

    @Test
    func test_searchItemType_allCases_containsExpectedTypes() {
        // Assert
        #expect(SearchItemType.allCases.contains(.repo))
        #expect(SearchItemType.allCases.contains(.worktree))
        #expect(SearchItemType.allCases.contains(.tab))
        #expect(SearchItemType.allCases.contains(.pane))
        #expect(SearchItemType.allCases.contains(.floatingTerminal))
    }

    // MARK: - KeyBinding

    @Test
    func test_keyBinding_codable_roundTrip() throws {
        // Arrange
        let binding = KeyBinding(key: "w", modifiers: [.command])

        // Act
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)

        // Assert
        #expect(decoded.key == "w")
        #expect(decoded.modifiers == [.command])
    }

    @Test
    func test_keyBinding_codable_multipleModifiers_roundTrip() throws {
        // Arrange
        let binding = KeyBinding(key: "O", modifiers: [.command, .shift])

        // Act
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)

        // Assert
        #expect(decoded.key == "O")
        #expect(decoded.modifiers.contains(.command))
        #expect(decoded.modifiers.contains(.shift))
    }

    @Test
    func test_keyBinding_hashable_sameBindings_equal() {
        // Arrange
        let b1 = KeyBinding(key: "w", modifiers: [.command])
        let b2 = KeyBinding(key: "w", modifiers: [.command])

        // Assert
        #expect(b1 == b2)
    }

    @Test
    func test_keyBinding_hashable_differentKeys_notEqual() {
        // Arrange
        let b1 = KeyBinding(key: "w", modifiers: [.command])
        let b2 = KeyBinding(key: "q", modifiers: [.command])

        // Assert
        #expect(b1 != b2)
    }

    // MARK: - AppCommandSpec

    @Test
    func test_commandDefinition_init_defaults() {
        // Act
        let def = AppCommandSpec(
            command: .closeTab,
            label: "Close Tab",
            icon: .system(.xmark),
            helpText: "Close the active tab",
            surfacePolicy: .exposed([.commandBar]),
            targeting: .contextual
        )

        // Assert
        #expect(def.command == AppCommand.closeTab)
        #expect(def.label == "Close Tab")
        #expect(def.helpText == "Close the active tab")
        #expect(def.globalKeyBinding == nil)
        #expect(def.icon == .system(.xmark))
        #expect(def.surfacePolicy == .exposed([.commandBar]))
        #expect(def.surfacePolicy.exposes(.commandBar))
        #expect(def.targeting == .contextual)
        #expect(!(def.requiresManagementLayer))
        #expect(def.visibleWhen.isEmpty)
        #expect(def.commandBarGroupName == "Commands")
        #expect(def.commandBarGroupPriority == 8)
    }

    @Test
    func test_commandDefinition_init_full() {
        // Act
        let def = AppCommandSpec(
            command: .newWindow,
            shortcut: .newWindow,
            label: "New Window",
            icon: .system(.xmark),
            helpText: "Open a new window",
            surfacePolicy: .exposed([.mainMenu]),
            targeting: .contextual,
            requiresManagementLayer: false
        )

        // Assert
        #expect(def.command == AppCommand.newWindow)
        #expect(def.globalKeyBinding != nil)
        #expect(def.icon == .system(.xmark))
        #expect(def.helpText == "Open a new window")
        #expect(def.surfacePolicy == .exposed([.mainMenu]))
        #expect(def.targeting == .contextual)
        #expect(!def.requiresManagementLayer)
    }

    @Test
    func test_zoomPane_presentsForSinglePaneTabsWithNarrowHeadlessIPC() {
        let zoomPane = AppCommand.zoomPane.definition
        let expandPane = AppCommand.expandPane.definition

        #expect(zoomPane.helpText == "Zoom the active pane")
        #expect(!zoomPane.visibleWhen.contains(.hasMultiplePanes))
        #expect(expandPane.icon == .system(.arrowUpLeftAndArrowDownRight))
        #expect(zoomPane.icon != expandPane.icon)
    }

    @Test
    func test_zoomPane_hardCutPreservesInputFocusCommandIdentities() {
        #expect(AppCommand.zoomPane.rawValue == "zoomPane")
        #expect(AppCommand(rawValue: "focus") == nil)
        #expect(AppCommand.focusPane.rawValue == "focusPane")
        #expect(AppCommand.focusPaneLeft.rawValue == "focusPaneLeft")
        #expect(AppCommand.focusPaneRight.rawValue == "focusPaneRight")
        #expect(AppCommand.focusPaneUp.rawValue == "focusPaneUp")
        #expect(AppCommand.focusPaneDown.rawValue == "focusPaneDown")
        #expect(AppCommand.focusNextPane.rawValue == "focusNextPane")
        #expect(AppCommand.focusPrevPane.rawValue == "focusPrevPane")
        #expect(AppCommand.focusDrawerPaneUp.rawValue == "focusDrawerPaneUp")
        #expect(AppCommand.focusDrawerPaneLeft.rawValue == "focusDrawerPaneLeft")
        #expect(AppCommand.focusDrawerPaneDown.rawValue == "focusDrawerPaneDown")
        #expect(AppCommand.focusDrawerPaneRight.rawValue == "focusDrawerPaneRight")
    }

    @Test
    func test_commandCatalog_exposesOneContextualZoomViewerCommand() throws {
        let viewerDefinitions = AppCommand.allCases
            .map(\.definition)
            .filter { $0.label == "Worktree Viewer" }

        let viewer = try #require(viewerDefinitions.first)
        #expect(viewerDefinitions.count == 1)
        #expect(viewer.command == .showViewer)
    }

    // MARK: - AppCommandDispatcher

    @MainActor

    @Test
    func test_dispatcher_definitions_registered() {
        let dispatcher = CommandDispatcherFixtureConfiguration().makeDispatcher()
        // Act

        // Assert
        #expect(dispatcher.definitions.count == AppCommand.allCases.count)
        #expect(dispatcher.definition(for: .closeTab).command == .closeTab)
        #expect(dispatcher.definition(for: .closePane).command == .closePane)
        #expect(dispatcher.definition(for: .watchFolder).command == .watchFolder)
        #expect(dispatcher.definition(for: .toggleSidebar).command == .toggleSidebar)
        #expect(dispatcher.definition(for: .focusSidebar).command == .focusSidebar)
    }

    @Test
    func test_toggleSidebar_isVisibleInCommandBarAndAppToolbar() {
        let definition = AppCommand.toggleSidebar.definition
        #expect(definition.surfacePolicy.exposes(.commandBar))
        #expect(definition.surfacePolicy == .exposed([.commandBar, .toolbar(.app)]))
        #expect(definition.targeting == .contextual)
    }

    @Test
    func test_dispatcher_allCommandsHaveHelpText() throws {

        for command in AppCommand.allCases {
            let definition = command.definition
            #expect(!definition.helpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @MainActor

    @Test
    func test_dispatcher_closeTab_hasNoKeyBinding() {
        // Act
        let def = AppCommand.closeTab.definition

        // Assert
        #expect(def.globalKeyBinding == nil)
    }

    @MainActor

    @Test
    func test_dispatcher_commands_forTab_includesExpected() {
        // Act
        let tabCommands = AppCommand.allCases.map(\.definition).filter { $0.targeting.supports(targetType: .tab) }

        // Assert
        let commandNames = tabCommands.map(\.command)
        #expect(commandNames.contains(.closeTab))
        #expect(commandNames.contains(.breakUpTab))
        #expect(commandNames.contains(.movePaneToTab))
        #expect(commandNames.contains(.equalizePanes))
        #expect(
            AppCommand.equalizePanes.definition.targeting
                == .contextualAndTargeted(
                    [.tab],
                    preferredInvocation: .contextual
                )
        )
    }

    @MainActor

    @Test
    func test_dispatcher_commands_forPane_includesExpected() {
        // Act
        let paneCommands = AppCommand.allCases.map(\.definition).filter { $0.targeting.supports(targetType: .pane) }

        // Assert
        let commandNames = paneCommands.map(\.command)
        #expect(commandNames.contains(.closePane))
        #expect(commandNames.contains(.extractPaneToTab))
        #expect(commandNames.contains(.movePaneToTab))
    }

    @MainActor

    @Test
    func test_arrangementShortcutDefinitions_useTabGroupAndShortcuts() {
        let show = AppCommand.switchArrangement.definition
        let previous = AppCommand.previousArrangement.definition
        let next = AppCommand.nextArrangement.definition

        #expect(show.command == .switchArrangement)
        #expect(show.shortcut == .showArrangementPanel)
        #expect(show.label == "Show Arrangements")
        #expect(show.commandBarGroupName == "Tab")

        #expect(previous.command == .previousArrangement)
        #expect(previous.shortcut == .previousArrangement)
        #expect(previous.label == "Previous Arrangement")
        #expect(previous.commandBarGroupName == "Tab")

        #expect(next.command == .nextArrangement)
        #expect(next.shortcut == .nextArrangement)
        #expect(next.label == "Next Arrangement")
        #expect(next.commandBarGroupName == "Tab")
    }

    @MainActor

    @Test
    func test_ordinalShortcutDefinitions_useCommandForTabsAndOptionForPanes() {
        let firstTab = AppCommand.selectTab1.definition
        let ninthTab = AppCommand.selectTab9.definition
        let firstPane = AppCommand.focusPane1.definition
        let ninthPane = AppCommand.focusPane9.definition

        #expect(firstTab.shortcut == .selectTab1)
        #expect(firstTab.globalKeyBinding?.key == "1")
        #expect(firstTab.globalKeyBinding?.modifiers == [.command])
        #expect(ninthTab.shortcut == .selectTab9)
        #expect(ninthTab.globalKeyBinding?.key == "9")
        #expect(ninthTab.globalKeyBinding?.modifiers == [.command])

        #expect(firstPane.shortcut == .focusPane1)
        #expect(firstPane.globalKeyBinding?.key == "1")
        #expect(firstPane.globalKeyBinding?.modifiers == [.option])
        #expect(ninthPane.shortcut == .focusPane9)
        #expect(ninthPane.globalKeyBinding?.key == "9")
        #expect(ninthPane.globalKeyBinding?.modifiers == [.option])
    }

    @MainActor

    @Test
    func test_terminalScrollAndPromptDefinitions_useTerminalGroupAndShortcuts() {
        let expectedDefinitions: [TerminalCommandPresentationExpectation] = [
            .init(
                command: .scrollPageUp,
                shortcut: .scrollPageUp,
                label: "Scroll Up 90%",
                helpText: "Scroll the active terminal pane up by 90% of its viewport"
            ),
            .init(
                command: .scrollPageDown,
                shortcut: .scrollPageDown,
                label: "Scroll Down 90%",
                helpText: "Scroll the active terminal pane down by 90% of its viewport"
            ),
            .init(
                command: .scrollSmallStepUp,
                shortcut: .scrollSmallStepUp,
                label: "Scroll Up 33%",
                helpText: "Scroll the active terminal pane up by 33% of its viewport"
            ),
            .init(
                command: .scrollSmallStepDown,
                shortcut: .scrollSmallStepDown,
                label: "Scroll Down 33%",
                helpText: "Scroll the active terminal pane down by 33% of its viewport"
            ),
            .init(
                command: .scrollToBottom,
                shortcut: .scrollToBottom,
                label: "Scroll to Bottom",
                helpText: "Scroll the active terminal pane to the bottom"
            ),
            .init(
                command: .jumpToPreviousPrompt,
                shortcut: .jumpToPreviousPrompt,
                label: "Previous Prompt",
                helpText: "Jump to the previous shell prompt in terminal scrollback"
            ),
            .init(
                command: .jumpToNextPrompt,
                shortcut: .jumpToNextPrompt,
                label: "Next Prompt",
                helpText: "Jump to the next shell prompt in terminal scrollback"
            ),
        ]

        for expected in expectedDefinitions {
            let definition = expected.command.definition
            #expect(definition.command == expected.command)
            #expect(definition.shortcut == expected.shortcut)
            #expect(definition.label == expected.label)
            #expect(definition.helpText == expected.helpText)
            #expect(definition.commandBarShortcutTrigger == expected.shortcut.trigger)
            #expect(definition.commandBarGroupName == "Terminal")
            #expect(definition.visibleWhen == [.hasActivePane, .paneIsTerminal])
            #expect(
                definition.targeting
                    == .contextualAndTargeted([.pane, .floatingTerminal], preferredInvocation: .contextual)
            )
        }
    }

    @MainActor

    @Test
    func test_sidebarAndPaneInboxDefinitions_areRetiredWithoutShortcuts() {
        let retiredCommands: [AppCommand] = [
            .showInboxNotifications,
            .toggleInboxNotificationSort,
            .clearReadInboxNotifications,
            .clearAllInboxNotifications,
            .showPaneInboxNotifications,
            .clearPaneInboxNotifications,
            .setInboxGroupingTab,
            .setInboxGroupingRepo,
            .setInboxGroupingPane,
            .setInboxGroupingNone,
            .setInboxRowStateFilter,
            .setInboxContentMode,
        ]
        let reposSidebar = AppCommand.showReposSidebar.definition

        for command in retiredCommands {
            let definition = command.definition
            #expect(definition.shortcut == nil)
            #expect(definition.surfacePolicy == .notPresented)
            #expect(definition.targeting == .contextual)
        }
        #expect(reposSidebar.shortcut == .showReposSidebar)
        #expect(reposSidebar.surfacePolicy.exposes(.commandBar))
        #expect(reposSidebar.surfacePolicy.exposes(.inlineControl))
        #expect(reposSidebar.targeting == .contextual)
    }

    @MainActor

    @Test
    func test_dispatcher_commands_forRepo_includesExpected() {
        // Act
        let repoCommands = AppCommand.allCases.map(\.definition).filter { $0.targeting.supports(targetType: .repo) }

        // Assert
        let commandNames = repoCommands.map(\.command)
        #expect(commandNames.contains(.pinRepo))
        #expect(commandNames.contains(.unpinRepo))
        #expect(commandNames.contains(.removeRepo))
        #expect(!commandNames.contains(.openWorktree))
    }

    @MainActor

    @Test
    func test_dispatcher_dispatch_withoutHandler_doesNotCrash() async throws {
        // Arrange

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = nil
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                #expect(!dispatcher.dispatch(.closeTab))
            }
        )
    }

    @Test
    func test_dispatcher_dispatchRequest_routesNoArgumentSidebarCommandToAppRouter() async throws {

        let appRouter = MockAppCommandRouter()
        appRouter.requestCommands = [.setReposSortFieldActivity]
        appRouter.parameterlessCanExecuteResult = true
        let request = AppCommandExecutionRequest(
            command: .setReposSortFieldActivity
        )

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = nil
                configuration.shellOwner = appRouter
            },
            body: { dispatcher in
                let outcome = dispatcher.dispatch(request)

                #expect(outcome == .applied)
                #expect(appRouter.handledRequests == [request])
            }
        )
    }

    @MainActor

    @Test
    func test_dispatcher_canDispatch_withoutHandler_returnsFalse() async throws {
        // Arrange

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = nil
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                // Act
                let result = dispatcher.canDispatch(.closeTab)

                // Assert
                #expect(!(result))
            }
        )
    }

    @MainActor

    @Test
    func test_dispatcher_dispatch_callsHandler() async throws {
        // Arrange

        let handler = MockCommandHandler()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                // Act
                let accepted = dispatcher.dispatch(.closeTab)

                // Assert
                #expect(accepted)
                #expect(handler.executedCommands.count == 1)
                #expect(handler.executedCommands[0].0 == .closeTab)
                #expect(handler.executedCommands[0].1 == nil)  // no target
            }
        )
    }

    @MainActor

    @Test
    func test_dispatcher_dispatch_targeted_callsHandler() async throws {
        // Arrange

        let handler = MockCommandHandler()
        let targetId = UUID()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                // Act
                dispatcher.dispatch(.closeTab, target: targetId, targetType: .tab)

                // Assert
                #expect(handler.executedCommands.count == 1)
                #expect(handler.executedCommands[0].0 == .closeTab)
                #expect(handler.executedCommands[0].1 == targetId)
                #expect(handler.executedCommands[0].2 == .tab)
            }
        )
    }

    @MainActor
    @Test
    func test_dispatcher_dispatch_targeted_usesTargetedAvailability() async throws {

        let handler = MockCommandHandler()
        handler.canExecuteResult = false
        handler.targetedCanExecuteResult = true
        let targetId = UUID()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                dispatcher.dispatch(.closeTab, target: targetId, targetType: .tab)

                #expect(handler.executedCommands.count == 1)
                #expect(handler.executedCommands[0].0 == .closeTab)
                #expect(handler.executedCommands[0].1 == targetId)
                #expect(handler.executedCommands[0].2 == .tab)
            }
        )
    }

    @MainActor

    @Test
    func test_dispatcher_dispatch_routesAppCommandToAppRouterBeforeHandler() async throws {

        let handler = MockCommandHandler()
        let appRouter = MockAppCommandRouter()
        appRouter.appCommands = [.watchFolder]

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = appRouter
            },
            body: { dispatcher in
                let accepted = dispatcher.dispatch(.watchFolder)

                #expect(accepted)
                #expect(appRouter.handledCommands == [.watchFolder])
                #expect(handler.executedCommands.isEmpty)
            }
        )
    }

    @Test
    func test_addRepo_rawValue_isRemoved() {
        #expect(AppCommand(rawValue: "addRepo") == nil)
    }

    @MainActor

    @Test
    func test_dispatcher_dispatchTargeted_routesAppCommandToAppRouterBeforeHandler() async throws {

        let handler = MockCommandHandler()
        let appRouter = MockAppCommandRouter()
        appRouter.appCommands = [.removeRepo]
        let repoId = UUID()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = appRouter
            },
            body: { dispatcher in
                dispatcher.dispatch(.removeRepo, target: repoId, targetType: .repo)

                #expect(appRouter.handledTargets.count == 1)
                #expect(appRouter.handledTargets[0].0 == .removeRepo)
                #expect(appRouter.handledTargets[0].1 == repoId)
                #expect(appRouter.handledTargets[0].2 == .repo)
                #expect(handler.executedCommands.isEmpty)
            }
        )
    }

    @MainActor

    @Test
    func test_dispatcher_dispatchExtractPaneToTab_callsHandlerSurface() async throws {

        let handler = MockCommandHandler()

        let tabId = UUID()
        let paneId = UUID()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                dispatcher.dispatchExtractPaneToTab(
                    tabId: tabId,
                    paneId: paneId,
                    targetTabInsertionIndex: 2
                )

                #expect(handler.extractedPaneRequests.count == 1)
                #expect(handler.extractedPaneRequests[0].tabId == tabId)
                #expect(handler.extractedPaneRequests[0].paneId == paneId)
                #expect(handler.extractedPaneRequests[0].targetTabInsertionIndex == 2)
            }
        )
    }

    @MainActor

    @Test
    func test_dispatcher_dispatchMovePaneToTab_callsHandlerSurface() async throws {
        try await withAsyncTestCoreAtoms { _ in

            let handler = MockCommandHandler()
            atom(\.managementLayer).deactivate()

            let sourcePaneId = UUID()
            let sourceTabId = UUID()
            let targetTabId = UUID()

            try await withCommandDispatcherFixture(
                configure: { configuration in
                    configuration.workspaceOwner = handler
                    configuration.shellOwner = nil
                },
                body: { dispatcher in
                    atom(\.managementLayer).toggle()
                    defer { atom(\.managementLayer).deactivate() }

                    dispatcher.dispatchMovePaneToTab(
                        sourcePaneId: sourcePaneId,
                        sourceTabId: sourceTabId,
                        targetTabId: targetTabId
                    )

                    let request = try #require(handler.movePaneRequests.first)
                    #expect(handler.movePaneRequests.count == 1)
                    #expect(request.sourcePaneId == sourcePaneId)
                    #expect(request.sourceTabId == sourceTabId)
                    #expect(request.targetTabId == targetTabId)
                }
            )
        }
    }

    @MainActor

    @Test
    func test_dispatcher_dispatchMovePaneToTab_rechecksExactSourcePaneCapability() async throws {
        try await withAsyncTestCoreAtoms { _ in

            let handler = MockCommandHandler()
            handler.canExecuteResult = true
            handler.targetedCanExecuteResult = false
            atom(\.managementLayer).deactivate()

            try await withCommandDispatcherFixture(
                configure: { configuration in
                    configuration.workspaceOwner = handler
                    configuration.shellOwner = nil
                },
                body: { dispatcher in
                    atom(\.managementLayer).toggle()
                    defer { atom(\.managementLayer).deactivate() }

                    dispatcher.dispatchMovePaneToTab(
                        sourcePaneId: UUID(),
                        sourceTabId: UUID(),
                        targetTabId: UUID()
                    )

                    #expect(handler.movePaneRequests.isEmpty)
                }
            )
        }
    }

    @MainActor

    @Test
    func test_dispatcher_cannotDispatch_whenHandlerReturnsFalse() async throws {
        // Arrange

        let handler = MockCommandHandler()
        handler.canExecuteResult = false

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                // Act
                dispatcher.dispatch(.closeTab)

                // Assert — command should not have been executed
                #expect(handler.executedCommands.isEmpty)
            }
        )
    }

    @Test
    func dispatcherDoesNotAcceptRejectedShellSidebarCommandThroughWorkspaceFallback() async throws {

        let shell = MockAppCommandRouter()
        shell.parameterlessCanExecuteResult = true
        let harness = makePaneTabViewControllerCommandHarness(shellCommandOwner: shell)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        for command in [AppCommand.showReposSidebar, .showPanesSidebar, .filterSidebar, .toggleSidebar] {
            #expect(!harness.controller.canExecute(command))
        }

        #expect(!harness.commandDispatcher.dispatch(.showPanesSidebar))
        #expect(shell.handledCommands.isEmpty)

        await harness.coordinator.shutdown()
    }

    @MainActor

    @Test
    func test_dispatcher_movePaneToTab_requiresManagementLayer() {
        // Act
        let def = AppCommand.movePaneToTab.definition

        // Assert
        #expect(def.requiresManagementLayer)
        #expect(def.surfacePolicy == .exposed([.commandBar, .contextMenu, .inlineControl]))
        #expect(def.targeting == .targeted([.pane, .tab]))
    }

    @MainActor

    @Test
    func test_dispatcher_managementRequiredCommand_blockedWhenInactive() async throws {
        try await withAsyncTestCoreAtoms { _ in

            let handler = MockCommandHandler()
            atom(\.managementLayer).deactivate()

            try await withCommandDispatcherFixture(
                configure: { configuration in
                    configuration.workspaceOwner = handler
                    configuration.shellOwner = nil
                },
                body: { dispatcher in
                    defer { atom(\.managementLayer).deactivate() }

                    #expect(!dispatcher.canDispatch(.closePane))
                    #expect(!dispatcher.canDispatch(.movePaneToTab))
                }
            )
        }
    }

    @MainActor

    @Test
    func test_dispatcher_managementRequiredCommands_useAcceptedInvocationWhenActive() async throws {
        try await withAsyncTestCoreAtoms { _ in

            let handler = MockCommandHandler()
            let paneId = UUID()
            atom(\.managementLayer).deactivate()

            try await withCommandDispatcherFixture(
                configure: { configuration in
                    configuration.workspaceOwner = handler
                    configuration.shellOwner = nil
                },
                body: { dispatcher in
                    atom(\.managementLayer).toggle()
                    defer { atom(\.managementLayer).deactivate() }

                    #expect(dispatcher.canDispatch(.closePane))
                    #expect(!dispatcher.canDispatch(.movePaneToTab))
                    #expect(
                        dispatcher.canDispatch(
                            .movePaneToTab,
                            target: paneId,
                            targetType: .pane
                        )
                    )
                }
            )
        }
    }

}
