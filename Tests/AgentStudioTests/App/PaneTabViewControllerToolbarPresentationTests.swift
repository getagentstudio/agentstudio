import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("PaneTabViewController toolbar presentation", .serialized)
struct PaneTabViewControllerToolbarPresentationTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("Viewer is absent from a normal pane and available in terminal Zoom")
    func normalPaneAndTerminalZoomFactoriesRemainDistinct() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(sourcePane.id, inTab: tab.id)
        atom(\.workspaceFocusOwner).focusMainPane(sourcePane.id)

        let normalPanePresentation =
            harness.controller.normalPaneSurfaceToolbarPresentation(for: sourcePane.id)

        harness.store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .retryable
        )
        let terminalZoomPresentation =
            harness.controller.zoomPaneSurfaceToolbarPresentation(
                for: sourcePane.id,
                viewerPresentation: .retryable
            )

        #expect(
            normalPanePresentation.contextActions.map(\.state.label) == [
                AppCommand.zoomPane.definition.label
            ]
        )
        #expect(normalPanePresentation.contextActions.allSatisfy { !$0.state.isSelected })
        #expect(
            terminalZoomPresentation.contextActions.map(\.state.label) == [
                AppCommand.zoomPane.definition.label,
                AppCommand.showViewer.definition.label,
            ]
        )
        #expect(terminalZoomPresentation.zoomAction?.state.isSelected == true)
        #expect(
            terminalZoomPresentation.contextActions.first {
                $0.state.label == AppCommand.showViewer.definition.label
            }?.state.isSelected == false
        )
    }

    @Test("terminal pane keeps Zoom when another pane owns focus")
    func terminalPaneKeepsZoomWhenWebviewOwnsFocus() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let terminalPane = harness.store.createPane()
        let webviewPane = harness.store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://focused.example")!)),
            metadata: PaneMetadata(contentType: .browser, title: "Focused Webview")
        )
        let tab = Tab(paneId: terminalPane.id)
        harness.store.appendTab(tab)
        #expect(
            harness.store.insertPane(
                webviewPane.id,
                inTab: tab.id,
                at: terminalPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(webviewPane.id, inTab: tab.id)
        atom(\.workspaceFocusOwner).focusMainPane(webviewPane.id)

        let terminalPresentation =
            harness.controller.normalPaneSurfaceToolbarPresentation(for: terminalPane.id)

        #expect(
            terminalPresentation.contextActions.map(\.state.label) == [
                AppCommand.zoomPane.definition.label
            ]
        )
    }

    @Test("pane toolbar uses targeted dispatcher capability and activation")
    func paneToolbarUsesTargetedDispatcher() async throws {
        let shellProbe = ToolbarShellCommandProbe()
        let harness = makeHarness(shellCommandOwner: shellProbe)
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let terminalPane = harness.store.createPane()
        let tab = Tab(paneId: terminalPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(terminalPane.id, inTab: tab.id)
        atom(\.workspaceFocusOwner).focusMainPane(terminalPane.id)
        try await withCommandDispatcher(
            harness.commandDispatcher,
            body: { _ in
                let presentation =
                    harness.controller.normalPaneSurfaceToolbarPresentation(for: terminalPane.id)
                let zoomAction = try #require(
                    presentation.contextActions.first {
                        $0.state.label == AppCommand.zoomPane.definition.label
                    }
                )

                #expect(
                    shellProbe.targetedCapabilityCommands == [
                        .init(command: .zoomPane, target: terminalPane.id, targetType: .pane)
                    ]
                )

                zoomAction.perform()

                #expect(
                    shellProbe.targetedCapabilityCommands == [
                        .init(command: .zoomPane, target: terminalPane.id, targetType: .pane),
                        .init(command: .zoomPane, target: terminalPane.id, targetType: .pane),
                    ]
                )
                #expect(
                    shellProbe.targetedExecutionCommands == [
                        .init(command: .zoomPane, target: terminalPane.id, targetType: .pane)
                    ]
                )
            }
        )
    }
}

private struct ToolbarTargetedCommand: Equatable {
    let command: AppCommand
    let target: UUID
    let targetType: SearchItemType
}

@MainActor
private final class ToolbarShellCommandProbe: ShellCommandHandling {
    private(set) var targetedCapabilityCommands: [ToolbarTargetedCommand] = []
    private(set) var targetedExecutionCommands: [ToolbarTargetedCommand] = []

    func canExecute(_: AppCommand) -> Bool { false }

    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        targetedCapabilityCommands.append(
            ToolbarTargetedCommand(
                command: command,
                target: target,
                targetType: targetType
            )
        )
        return false
    }

    func execute(_: AppCommand) -> Bool { false }

    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        targetedExecutionCommands.append(
            ToolbarTargetedCommand(
                command: command,
                target: target,
                targetType: targetType
            )
        )
        return false
    }

    func showRepoCommandBar() {}
    func refreshWorktrees() {}
    func refocusActivePane() {}
}
