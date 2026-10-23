import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Exhaustiveness against real owners: every IPC-exposed AppCommand has a typed
/// routing case in the App shell or the workspace controller. An owner that
/// reports `.unsupportedCommand` for both means the command has no delivery
/// path at all, which is the failure this suite exists to catch.
@MainActor
@Suite("AgentStudio IPC command real owner coverage", .serialized)
struct AgentStudioIPCCommandRealOwnerCoverageTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    /// `newWindow` is the one command excluded from live owner execution: its
    /// owner creates a real AppKit window. Its routing case is proved by the
    /// recording-owner dispatch coverage suite instead.
    static let commandsExcludedFromLiveOwnerExecution: Set<AppCommand> = [.newWindow]

    @Test("every IPC-exposed AppCommand has a typed routing case in a real owner")
    func everyAppCommandHasARealOwnerRoutingCase() async throws {
        let windowId = UUIDv7.generate()
        let harness = makeHarness(workspaceWindowId: windowId)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let delegate = AppDelegate()
        delegate.atomStore = AtomRegistry()

        var unrouted: [String] = []
        for command in AppCommand.allCases where command.ipcSpec.exposure != .notExposed {
            guard !Self.commandsExcludedFromLiveOwnerExecution.contains(command) else { continue }
            for variant in command.ipcSpec.argumentVariants {
                let arguments = try Self.liveArguments(
                    for: variant, windowId: windowId, harness: harness)
                let request = AppCommandExecutionRequest(
                    command: command,
                    arguments: .typedIPC(arguments),
                    executionContext: .headlessIPC(admitsDebugTestingCommands: true)
                )
                let shellOutcome = delegate.executeTypedIPCShellCommand(command, arguments: arguments)
                if shellOutcome != .unsupportedCommand { continue }
                let workspaceOutcome = await harness.controller.executeHeadlessIPC(request)
                if workspaceOutcome == .unsupportedCommand {
                    unrouted.append("\(command.rawValue):\(variant.rawValue)")
                }
            }
        }

        #expect(unrouted.isEmpty, "Commands with no real owner routing case: \(unrouted)")
    }

    @Test("the App shell owns exactly its documented typed command families")
    func shellOwnsExactlyItsDocumentedFamilies() throws {
        let delegate = AppDelegate()
        delegate.atomStore = AtomRegistry()
        let windowId = UUIDv7.generate()

        var shellOwned: Set<AppCommand> = []
        for command in AppCommand.allCases where command.ipcSpec.exposure != .notExposed {
            guard !Self.commandsExcludedFromLiveOwnerExecution.contains(command) else {
                shellOwned.insert(command)
                continue
            }
            for variant in command.ipcSpec.argumentVariants {
                let arguments = try Self.shellProbeArguments(for: variant, windowId: windowId)
                if delegate.executeTypedIPCShellCommand(command, arguments: arguments)
                    != .unsupportedCommand
                {
                    shellOwned.insert(command)
                }
            }
        }

        #expect(shellOwned == Self.shellOwnedCommands)
    }

    /// The App shell's typed command families: window lifecycle, sidebar chrome
    /// and preferences, command-bar and authentication presentation, the
    /// watch-folder owner, repository fact refresh, worktree creation (typed IPC
    /// reports unavailable until a parameterized contract exists), and the dormant
    /// Inbox and retired Panes-organization surfaces.
    static let shellOwnedCommands: Set<AppCommand> = [
        .newWindow, .closeWindow,
        .toggleSidebar, .filterSidebar, .focusSidebar,
        .showReposSidebar, .showPanesSidebar,
        .setReposGroupingRepo, .setReposGroupingActivity,
        .setReposSortFieldName, .setReposSortFieldActivity,
        .toggleReposSortDirection, .toggleReposShowsPinned, .togglePanesShowsPinned,
        .togglePanesShowsDrawers,
        .setPanesSortFieldName, .setPanesSortFieldActivity, .togglePanesSortDirection,
        .showCommandBarEverything, .showCommandBarQuickOpen, .showCommandBarCommands,
        .showCommandBarPanes, .showCommandBarRepos,
        .signInGitHub, .signInGoogle,
        .watchFolder, .updateRepositoryFacts, .newWorktree, .newWorktreeFromDefault, .newWorktreeFromBranch,
        .forkWorktree,
        .showInboxNotifications, .toggleInboxNotificationSort,
        .clearReadInboxNotifications, .clearAllInboxNotifications,
        .showPaneInboxNotifications, .clearPaneInboxNotifications,
        .setInboxGroupingTab, .setInboxGroupingRepo, .setInboxGroupingPane,
        .setInboxGroupingNone, .setInboxRowStateFilter, .setInboxContentMode,
    ]

    // MARK: - Argument fixtures

    /// Arguments built from live harness identities where the owner needs them.
    /// Worktree, arrangement and repository identities stay synthetic on
    /// purpose: a missing target must reach the owner and be refused there, not
    /// disappear into a missing routing case.
    private static func liveArguments(
        for variant: IPCCommandArgumentVariant,
        windowId: UUID,
        harness: Harness
    ) throws -> IPCCommandArguments {
        let pane = harness.store.createPane()
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        let paneSelector = try IPCPaneSelector(rawValue: pane.id.uuidString)
        let secondPane = harness.store.createPane()
        let secondSelector = try IPCPaneSelector(rawValue: secondPane.id.uuidString)
        return arguments(
            for: variant,
            windowId: windowId,
            tabId: tab.id,
            paneSelector: paneSelector,
            secondaryPaneSelector: secondSelector,
            directoryPath: harness.tempDir.path
        )
    }

    private static func shellProbeArguments(
        for variant: IPCCommandArgumentVariant,
        windowId: UUID
    ) throws -> IPCCommandArguments {
        let paneSelector = try IPCPaneSelector(rawValue: UUIDv7.generate().uuidString)
        return arguments(
            for: variant,
            windowId: windowId,
            tabId: UUIDv7.generate(),
            paneSelector: paneSelector,
            secondaryPaneSelector: paneSelector,
            // A path that does not exist keeps the watch-folder owner from
            // starting a real scan while still proving it claims the command.
            directoryPath: "/nonexistent-agentstudio-probe"
        )
    }

    private static func arguments(
        for variant: IPCCommandArgumentVariant,
        windowId: UUID,
        tabId: UUID,
        paneSelector: IPCPaneSelector,
        secondaryPaneSelector: IPCPaneSelector,
        directoryPath: String
    ) -> IPCCommandArguments {
        if let layout = layoutArguments(
            for: variant, windowId: windowId, tabId: tabId, paneSelector: paneSelector,
            secondaryPaneSelector: secondaryPaneSelector)
        {
            return layout
        }
        return surfaceArguments(
            for: variant, windowId: windowId, paneSelector: paneSelector,
            secondaryPaneSelector: secondaryPaneSelector, directoryPath: directoryPath)
    }

    private static func layoutArguments(
        for variant: IPCCommandArgumentVariant,
        windowId: UUID,
        tabId: UUID,
        paneSelector: IPCPaneSelector,
        secondaryPaneSelector: IPCPaneSelector
    ) -> IPCCommandArguments? {
        switch variant {
        case .noArguments: .noArguments
        case .workspaceWindow: .workspaceWindow(.init(workspaceWindowId: windowId))
        case .tab: .tab(.init(workspaceWindowId: windowId, tabId: tabId))
        case .renamedTab: .renamedTab(.init(workspaceWindowId: windowId, tabId: tabId, name: "Probe"))
        case .newTab: .newTab(.init(workspaceWindowId: windowId, launchDirectory: nil))
        case .tabAnchor: .tabAnchor(.init(workspaceWindowId: windowId, anchorTabId: tabId))
        case .pane: .pane(.init(workspaceWindowId: windowId, paneSelector: paneSelector))
        case .sourcePane: .sourcePane(.init(workspaceWindowId: windowId, sourcePaneSelector: paneSelector))
        case .movePaneToTab:
            .movePaneToTab(
                .init(
                    workspaceWindowId: windowId, sourcePaneSelector: paneSelector, destinationTabId: tabId))
        case .arrangement:
            .arrangement(
                .init(workspaceWindowId: windowId, tabId: tabId, arrangementId: UUIDv7.generate()))
        case .newArrangement:
            .newArrangement(.init(workspaceWindowId: windowId, tabId: tabId, name: "Probe"))
        case .renamedArrangement:
            .renamedArrangement(
                .init(
                    workspaceWindowId: windowId, tabId: tabId, arrangementId: UUIDv7.generate(),
                    name: "Probe"))
        case .drawerParent:
            .drawerParent(.init(workspaceWindowId: windowId, parentPaneSelector: paneSelector))
        case .drawerSourcePane:
            .drawerSourcePane(
                .init(
                    workspaceWindowId: windowId, parentPaneSelector: paneSelector,
                    sourceDrawerPaneSelector: secondaryPaneSelector))
        case .drawerPane:
            .drawerPane(
                .init(
                    workspaceWindowId: windowId, parentPaneSelector: paneSelector,
                    drawerPaneSelector: secondaryPaneSelector))
        case .detachedDrawerPane:
            .detachedDrawerPane(
                .init(workspaceWindowId: windowId, drawerPaneSelector: secondaryPaneSelector))
        default: nil
        }
    }

    private static func surfaceArguments(
        for variant: IPCCommandArgumentVariant,
        windowId: UUID,
        paneSelector: IPCPaneSelector,
        secondaryPaneSelector: IPCPaneSelector,
        directoryPath: String
    ) -> IPCCommandArguments {
        switch variant {
        case .directory: .directory(.init(workspaceWindowId: windowId, directoryPath: directoryPath))
        case .repository: .repository(.init(repoId: UUIDv7.generate()))
        case .standalonePane: .standalonePane(.init(paneSelector: paneSelector))
        case .worktree: .worktree(.init(workspaceWindowId: windowId, worktreeId: UUIDv7.generate()))
        case .worktreeInPane:
            .worktreeInPane(
                .init(
                    workspaceWindowId: windowId, worktreeId: UUIDv7.generate(),
                    targetPaneSelector: paneSelector))
        case .terminalFromWorktree:
            .terminalFromWorktree(
                .init(
                    workspaceWindowId: windowId, worktreeId: UUIDv7.generate(), launchDirectory: nil,
                    title: nil))
        case .terminalFromPane:
            .terminalFromPane(
                .init(
                    workspaceWindowId: windowId, sourcePaneSelector: paneSelector, launchDirectory: nil,
                    title: nil))
        case .managementFromMainPane:
            .managementFromMainPane(.init(workspaceWindowId: windowId, mainPaneSelector: paneSelector))
        case .managementFromDrawerPane:
            .managementFromDrawerPane(
                .init(
                    workspaceWindowId: windowId, parentPaneSelector: paneSelector,
                    drawerPaneSelector: secondaryPaneSelector))
        case .floatingTerminal:
            .floatingTerminal(.init(workspaceWindowId: windowId, launchDirectory: nil, title: nil))
        default: .webview(.init(workspaceWindowId: windowId))
        }
    }
}
