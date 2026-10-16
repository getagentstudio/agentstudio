import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCommandBar
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("Command spec contracts", .serialized)
struct CommandSpecContractTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("every shortcut maps to a command definition that declares that shortcut")
    func everyShortcutMapsToACommandDefinitionThatDeclaresThatShortcut() {
        for shortcut in AppShortcut.allCases {
            let command = shortcut.command
            let definition = command.definition

            if shortcut == .showInboxNotifications || shortcut == .showPaneInboxNotifications {
                #expect(definition.shortcut == nil)
            } else {
                #expect(
                    definition.shortcut == shortcut,
                    "\(shortcut.rawValue) maps to \(command.rawValue), but its AppCommandSpec declares \(String(describing: definition.shortcut))"
                )
            }
        }
    }

    @Test("every command has one valid explicit presentation policy")
    func everyCommandHasOneValidExplicitPresentationPolicy() {
        let definitions = AppCommand.allCases.map(\.definition)
        let commandRawValues = definitions.map(\.command.rawValue)

        #expect(definitions.count == AppCommand.allCases.count)
        #expect(Set(commandRawValues).count == AppCommand.allCases.count)
        #expect(Set(commandRawValues) == Set(AppCommand.allCases.map(\.rawValue)))

        for definition in definitions {
            #expect(
                definition.surfacePolicy.isValid,
                "\(definition.command.rawValue) has an invalid surface policy"
            )
            #expect(
                definition.targeting.isValid,
                "\(definition.command.rawValue) has an invalid targeting policy"
            )
        }
    }

    @Test("shortcut triggers are unique within each routing context")
    func shortcutTriggersAreUniqueWithinEachRoutingContext() {
        var seenShortcuts: [ShortcutRouteKey: AppShortcut] = [:]

        for shortcut in AppShortcut.allCases {
            let spec = shortcut.spec
            for context in spec.contexts {
                recordRoute(
                    ShortcutRouteKey(context: context, trigger: spec.trigger),
                    for: shortcut,
                    in: &seenShortcuts
                )
            }
            for (trigger, contexts) in spec.alternateTriggers {
                for context in contexts {
                    recordRoute(
                        ShortcutRouteKey(context: context, trigger: trigger),
                        for: shortcut,
                        in: &seenShortcuts
                    )
                }
            }
        }
    }

    @Test("command bar displays only exact global shortcut triggers")
    func commandBarDisplaysOnlyExactGlobalShortcutTriggers() {
        #expect(AppCommand.showReposSidebar.definition.commandBarShortcutTrigger == nil)
        #expect(AppCommand.showPanesSidebar.definition.commandBarShortcutTrigger == nil)
        #expect(AppCommand.showReposSidebar.definition.controlTooltipRenderValue().shortcutDisplayText == nil)
        #expect(AppCommand.showPanesSidebar.definition.controlTooltipRenderValue().shortcutDisplayText == nil)
        #expect(AppCommand.filterSidebar.definition.commandBarShortcutTrigger?.displayString == "⌘F")
        #expect(AppCommand.focusSidebar.definition.commandBarShortcutTrigger?.displayString == "⌘⇧S")
    }

    private func recordRoute(
        _ routeKey: ShortcutRouteKey,
        for shortcut: AppShortcut,
        in seenShortcuts: inout [ShortcutRouteKey: AppShortcut]
    ) {
        if let existingShortcut = seenShortcuts[routeKey] {
            Issue.record(
                """
                \(shortcut.rawValue) and \(existingShortcut.rawValue) both use \
                \(routeKey.trigger.displayDescription) in \(routeKey.context)
                """
            )
        } else {
            seenShortcuts[routeKey] = shortcut
        }
    }

    @Test("commands scope mirrors visible AppCommandSpec metadata")
    func commandsScopeMirrorsVisibleCommandSpecMetadata() throws {
        let store = makeCommandRichStore()
        let focusedPaneId = UUID()
        let focusedPane = WorkspaceFocusedPane(
            owner: .mainPane(paneId: focusedPaneId),
            activeMainPaneId: focusedPaneId,
            paneId: focusedPaneId,
            repoId: nil,
            worktreeId: nil,
            contentType: .terminal
        )
        let commandContext = CommandContext(
            activeTabId: UUID(),
            focusedPaneId: focusedPaneId,
            focusedContentType: .terminal,
            satisfiedRequirements: Set(CommandRequirement.allCases)
        )

        let dispatcher = CommandDispatcherFixtureConfiguration().makeDispatcher()
        let items = CommandBarDataSource.items(
            scope: .commands,
            store: store,
            repoCache: RepoCacheAtom(),
            dispatcher: dispatcher,
            focusedPane: focusedPane,
            commandContext: commandContext
        )
        let itemsByCommand = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.command.map { ($0, item) }
            })
        let expectedDefinitions = dispatcher.definitions.values.filter {
            $0.shouldPresent(
                AppCommandPresentationQuery(
                    surface: .commandBar,
                    subject: .contextual(commandContext)
                )
            )
        }

        #expect(itemsByCommand.count == expectedDefinitions.count)

        for definition in expectedDefinitions {
            let item = try #require(
                itemsByCommand[definition.command],
                "Missing command bar row for \(definition.command.rawValue)"
            )

            #expect(item.id == "cmd-\(definition.command.rawValue)")
            #expect(item.title == definition.label)
            #expect(item.icon == definition.icon)
            #expect(item.group == definition.commandBarGroupName)
            #expect(item.groupPriority == definition.commandBarGroupPriority)
            #expect(item.shortcutTrigger == definition.commandBarShortcutTrigger)
            #expect(item.command == definition.command)
        }
    }

    @Test("app command specs project typed tooltip descriptors")
    func appCommandSpecsProjectTypedTooltipDescriptors() {
        let definition = AppCommand.openPaneLocationInEditorMenu.definition

        let descriptor = definition.commandDisplayDescriptor(compactTooltipText: "Open in Editor")

        #expect(descriptor.provenance == .appCommand(rawValue: "openPaneLocationInEditorMenu"))
        #expect(descriptor.label == definition.label)
        #expect(descriptor.helpText == definition.helpText)
        #expect(descriptor.compactTooltipText == "Open in Editor")
        #expect(descriptor.shortcutDisplayText == ShortcutDisplayText(value: "⌘⌥⌃O"))
        #expect(
            ControlTooltipResolver.resolve(.display(descriptor))
                == definition.controlTooltipRenderValue(textOverride: "Open in Editor")
        )
        #expect(definition.controlToolTip(textOverride: "Open in Editor") == "Open in Editor (⌘⌥⌃O)")
    }

    @Test("Open PR is a pane-targeted toolbar command")
    func openPullRequestIsPaneTargetedToolbarCommand() {
        let definition = AppCommand.openPullRequest.definition

        #expect(definition.label == "Open PR")
        #expect(definition.icon == .octicon(.gitPullRequest))
        #expect(definition.helpText == "Open PR in Browser")
        #expect(
            definition.shouldPresent(
                AppCommandPresentationQuery(
                    surface: .toolbar(.pane),
                    subject: .targeted(.pane)
                )
            )
        )
        #expect(
            !definition.shouldPresent(
                AppCommandPresentationQuery(
                    surface: .commandBar,
                    subject: .targeted(.pane)
                )
            )
        )
    }

    @Test("Pane Zoom, Viewer, editor, chooser, and Copy Path expose the accepted O-family shortcuts")
    func paneZoomAndOFamilyCommandsExposeAcceptedShortcuts() {
        #expect(AppCommand.zoomPane.definition.shortcut?.trigger.displayString == "⌘⇧↵")
        #expect(AppCommand.showViewer.definition.shortcut?.trigger.displayString == "⌘O")
        #expect(
            AppCommand.openPaneLocationInBookmarkedEditor.definition.shortcut?.trigger.displayString
                == "⌘⌥O"
        )
        #expect(
            AppCommand.openPaneLocationInEditorMenu.definition.shortcut?.trigger.displayString
                == "⌘⌥⌃O"
        )
        #expect(AppCommand.copyCurrentPanePath.definition.shortcut?.trigger.displayString == "⌥O")
    }

    @Test("app command tooltip source preserves help-text fallback without shortcut")
    func appCommandTooltipSourcePreservesHelpTextFallbackWithoutShortcut() {
        let definition = AppCommandSpec(
            command: .renameArrangement,
            label: "Rename Arrangement",
            icon: .system(.pencil),
            helpText: "Rename the current arrangement",
            surfacePolicy: .exposed([.commandBar]),
            targeting: .targeted([.tab])
        )

        let renderValue = ControlTooltipResolver.resolve(definition.controlTooltipSource())

        #expect(renderValue.text == "Rename the current arrangement")
        #expect(renderValue.shortcutDisplayText == nil)
    }

    private func makeCommandRichStore() -> WorkspaceStore {
        let store = WorkspaceStore()
        let repo = store.addRepo(at: URL(filePath: "/tmp/command-spec-contracts"))
        let worktree = Worktree(
            repoId: repo.id,
            name: "feature-command-contracts",
            path: URL(filePath: "/tmp/command-spec-contracts/feature-command-contracts")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [worktree])

        let primaryPane = store.createPane(
            launchDirectory: worktree.path,
            title: "Primary",
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path),
        )
        let secondaryPane = store.createPane()
        var tab = Tab(paneId: primaryPane.id)
        tab.arrangements.append(
            PaneArrangement(
                name: "Review",
                isDefault: false,
                layout: tab.layout
            )
        )
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        store.insertPane(
            secondaryPane.id,
            inTab: tab.id,
            at: primaryPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        _ = store.addDrawerPane(to: primaryPane.id)

        return store
    }
}

private struct ShortcutRouteKey: Hashable {
    let context: ShortcutContext
    let trigger: ShortcutTrigger
}

extension ShortcutTrigger {
    fileprivate var displayDescription: String {
        let modifierPrefix =
            modifiers
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
            .joined(separator: "+")
        guard !modifierPrefix.isEmpty else { return key.displayString }
        return "\(modifierPrefix)+\(key.displayString)"
    }
}
