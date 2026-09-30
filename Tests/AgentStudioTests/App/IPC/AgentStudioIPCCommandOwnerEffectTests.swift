import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

/// Real-owner proof for typed `command.execute`: each owner family applies an
/// observable effect from explicit wire identities, and the reported boundary
/// matches what that owner actually reached.
@MainActor
@Suite("AgentStudio IPC command owner effects", .serialized)
struct AgentStudioIPCCommandOwnerEffectTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("pinPane applies through the awaited workspace action executor")
    func pinPaneAppliesThroughWorkspaceActionExecutor() async throws {
        let windowId = UUIDv7.generate()
        let harness = makeHarness(workspaceWindowId: windowId)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(title: "Pinned")
        harness.store.appendTab(Tab(paneId: pane.id))
        let (adapter, shellOwner) = makeAdapter(for: harness, windowId: windowId, channel: .stable)
        #expect(harness.store.paneAtom.graphAtom.paneState(pane.id)?.metadata.isPinned != true)

        let result = try await execute(
            adapter,
            command: .pinPane,
            arguments: .standalonePane(.init(paneSelector: try .init(rawValue: pane.id.uuidString))),
            harness: harness
        )
        withExtendedLifetime(shellOwner) {}

        #expect(result.variant == .applied)
        #expect(harness.store.paneAtom.graphAtom.paneState(pane.id)?.metadata.isPinned == true)
    }

    @Test("renameTab applies the explicit name through the workspace tab owner")
    func renameTabAppliesExplicitName() async throws {
        let windowId = UUIDv7.generate()
        let harness = makeHarness(workspaceWindowId: windowId)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane()
        let tab = Tab(paneId: pane.id, name: "Original")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let (adapter, shellOwner) = makeAdapter(for: harness, windowId: windowId, channel: .debug)

        let result = try await execute(
            adapter,
            command: .renameTab,
            arguments: .renamedTab(
                .init(workspaceWindowId: windowId, tabId: tab.id, name: "Renamed")),
            harness: harness
        )
        withExtendedLifetime(shellOwner) {}

        #expect(result.variant == .applied)
        #expect(harness.store.tab(tab.id)?.name == "Renamed")
        // The interactive path opens a rename popover; the typed path must not.
        #expect(harness.tabRenamePopoverState.presentedTabId == nil)
    }

    @Test("saveArrangement creates the explicitly named arrangement on the named tab")
    func saveArrangementCreatesNamedArrangement() async throws {
        let windowId = UUIDv7.generate()
        let harness = makeHarness(workspaceWindowId: windowId)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane()
        let tab = Tab(paneId: pane.id, name: "Work")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let (adapter, shellOwner) = makeAdapter(for: harness, windowId: windowId, channel: .debug)

        let result = try await execute(
            adapter,
            command: .saveArrangement,
            arguments: .newArrangement(
                .init(
                    workspaceWindowId: windowId,
                    tabId: tab.id,
                    name: "Review Layout"
                )),
            harness: harness
        )
        withExtendedLifetime(shellOwner) {}

        #expect(result.variant == .applied)
        #expect(harness.store.tab(tab.id)?.arrangements.contains { $0.name == "Review Layout" } == true)
    }

    @Test("an explicit-pane terminal shortcut awaits the runtime owner instead of reporting a scheduled bool")
    func terminalRuntimeCommandAwaitsRuntimeOwner() async throws {
        let windowId = UUIDv7.generate()
        let harness = makeHarness(workspaceWindowId: windowId)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(title: "Terminal")
        harness.store.appendTab(Tab(paneId: pane.id))
        let (adapter, shellOwner) = makeAdapter(for: harness, windowId: windowId, channel: .debug)

        let result = try await execute(
            adapter,
            command: .scrollToBottom,
            arguments: .pane(
                .init(
                    workspaceWindowId: windowId,
                    paneSelector: try .init(rawValue: pane.id.uuidString)
                )),
            harness: harness
        )
        withExtendedLifetime(shellOwner) {}

        // No runtime is attached in this harness, so the awaited runtime owner
        // reports unavailable. A scheduling bool would have claimed applied.
        #expect(result.variant == .unavailable)
        #expect(AppCommand.scrollToBottom.ipcSpec.resultVariants.contains(.unavailable))
    }

    @Test("a repos sidebar setting applies through the real App shell owner")
    func sidebarSettingAppliesThroughShellOwner() async throws {
        let delegate = AppDelegate()
        let registry = AtomRegistry()
        delegate.atomStore = registry
        registry.core.workspaceSidebarState.setSidebarSurface(.repos)
        let prefs = registry.repoExplorerSidebarPrefs
        prefs.setGroupingMode(.activity, for: .repos)

        let outcome = delegate.execute(
            AppCommandExecutionRequest(
                command: .setReposGroupingRepo,
                arguments: .typedIPC(.workspaceWindow(.init(workspaceWindowId: UUIDv7.generate()))),
                executionContext: .headlessIPC(admitsDebugTestingCommands: false)
            )
        )

        #expect(outcome == .applied)
        #expect(prefs.groupingMode(for: .repos) == .repo)
    }

    @Test("dormant Inbox commands report typed unavailable from the real App shell owner")
    func dormantInboxCommandsReportUnavailableFromShellOwner() {
        let delegate = AppDelegate()
        delegate.atomStore = AtomRegistry()

        let outcome = delegate.execute(
            AppCommandExecutionRequest(
                command: .showInboxNotifications,
                arguments: .typedIPC(.noArguments),
                executionContext: .headlessIPC(admitsDebugTestingCommands: true)
            )
        )

        #expect(outcome == .unavailable(.featureUnavailable))
        #expect(AppCommand.showInboxNotifications.ipcSpec.resultVariants == [.unavailable])
    }

    // MARK: - Harness plumbing

    /// The adapter holds its shell owner weakly, so the caller keeps the stub
    /// alive for the duration of the test.
    private func makeAdapter(
        for harness: Harness,
        windowId: UUID,
        channel: AgentStudioIPCChannel
    ) -> (adapter: AgentStudioIPCCommandAdapter, shellOwner: StubWorkspaceWindowShellOwner) {
        let shellOwner = StubWorkspaceWindowShellOwner(currentWindowId: windowId)
        return (
            AgentStudioIPCCommandAdapter(
                workspaceId: harness.store.identityAtom.workspaceId,
                channel: channel,
                targetAuthorizer: WorkspaceDurableTargetAuthorizationPort(workspaceStore: harness.store),
                shellCommandHandler: shellOwner
            ),
            shellOwner
        )
    }

    private func execute(
        _ adapter: AgentStudioIPCCommandAdapter,
        command: AppCommand,
        arguments: IPCCommandArguments,
        harness: Harness
    ) async throws -> IPCCommandExecutionResult {
        try await withIsolatedCommandDispatcher(
            configure: {
                AppCommandDispatcher.shared.handler = harness.controller
                AppCommandDispatcher.shared.appCommandRouter = nil
            },
            body: {
                try await adapter.executeCommand(
                    IPCCommandExecutionRequest(
                        commandId: .init(rawValue: command.rawValue),
                        correlationId: UUIDv7.generate(),
                        arguments: arguments
                    ), ownPaneAssertion: nil
                )
            }
        )
    }
}

/// Owns only the one current workspace window so the adapter's window check
/// reaches the real pane controller under test.
@MainActor
final class StubWorkspaceWindowShellOwner: ShellCommandHandling {
    private let currentWindowId: UUID

    init(currentWindowId: UUID) {
        self.currentWindowId = currentWindowId
    }

    func ownsWorkspaceWindow(_ workspaceWindowId: UUID) -> Bool {
        currentWindowId == workspaceWindowId
    }

    func canExecute(_: AppCommand) -> Bool { false }
    func canExecute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func execute(_: AppCommand) -> Bool { false }
    func execute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func execute(_: AppCommandExecutionRequest) -> AppCommandExecutionOutcome { .unsupportedCommand }
    func showRepoCommandBar() {}
    func refreshWorktrees() {}
    func refocusActivePane() {}
}
