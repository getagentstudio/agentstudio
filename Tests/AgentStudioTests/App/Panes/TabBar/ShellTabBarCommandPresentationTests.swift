import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Shell tab-bar command presentation")
struct ShellTabBarCommandPresentationTests {
    @Test("new-tab context rows preserve local copy and execute through command presentations")
    func newTabContextRowsPreserveLocalCopyAndUseCommandPresentations() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Panes/TabBar/ShellTabBarControls.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("Button(LocalActionSpec.emptyTerminal.actionSpec.label)"))
        #expect(source.contains("emptyTerminalPresentation.perform()"))
        #expect(source.contains("Button(LocalActionSpec.openRepoWorktree.actionSpec.label)"))
        #expect(source.contains("repositoriesPresentation.perform()"))
        #expect(!source.contains("onAdd()"))
        #expect(!source.contains("onOpenRepoInTab"))
    }

    @Test("physical surface controls command presence")
    func physicalSurfaceControlsPresence() {
        let dispatcher = ShellPresentationDispatcher()

        #expect(
            ShellTabBarCommandPresentation(
                command: .newTab,
                surface: .contextMenu,
                commandContext: .empty,
                dispatcher: dispatcher
            ) != nil
        )
        #expect(
            ShellTabBarCommandPresentation(
                command: .newTab,
                surface: .inlineControl,
                commandContext: .empty,
                dispatcher: dispatcher
            ) == nil
        )
    }

    @Test("activation rechecks capability")
    func activationRechecksCapability() throws {
        let dispatcher = ShellPresentationDispatcher()
        dispatcher.enabledCommands = [.showCommandBarRepos]
        let presentation = try #require(
            ShellTabBarCommandPresentation(
                command: .showCommandBarRepos,
                surface: .contextMenu,
                commandContext: .empty,
                dispatcher: dispatcher
            )
        )
        #expect(presentation.isEnabled)

        dispatcher.enabledCommands = []
        presentation.perform()

        #expect(
            dispatcher.capabilityCommands == [
                .showCommandBarRepos,
                .showCommandBarRepos,
            ]
        )
        #expect(dispatcher.dispatchedCommands.isEmpty)
    }
}

@MainActor
private final class ShellPresentationDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    var enabledCommands: Set<AppCommand> = []
    private(set) var capabilityCommands: [AppCommand] = []
    private(set) var dispatchedCommands: [AppCommand] = []

    func dispatch(_ command: AppCommand) -> Bool {
        dispatchedCommands.append(command)
        return true
    }

    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}

    func canDispatch(_ command: AppCommand) -> Bool {
        capabilityCommands.append(command)
        return enabledCommands.contains(command)
    }

    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        false
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
