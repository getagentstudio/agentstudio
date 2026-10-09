import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Pane leaf command presentation")
struct PaneLeafCommandPresentationTests {
    @Test("management chrome preserves the shipped glyphs while command specs own behavior")
    func managementChromePreservesShippedGlyphs() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Panes/Hosting/PaneLeafContainer.swift"
            ),
            encoding: .utf8
        )

        #expect(
            source.contains(
                "presentation: minimizePresentation,\n                                    systemName: \"minus\""))
        #expect(
            source.contains(
                "presentation: closePresentation,\n                                    systemName: \"xmark\""))
        #expect(
            source.contains(
                "presentation: splitPresentation,\n                                        systemName: \"plus\""))
        #expect(source.contains(".controlHelp(presentation.spec.controlTooltipRenderValue())"))
        #expect(source.contains("isEnabled: presentation.isEnabled"))
        #expect(source.contains("minimizePresentation.perform()"))
        #expect(source.contains("closePresentation.perform()"))
        #expect(source.contains("splitPresentation.perform()"))
    }

    @Test("pane management projects only the catalog-declared surface and pane target")
    func projectsExactSurfaceAndPaneTarget() {
        let dispatcher = RecordingPaneLeafCommandDispatcher()
        let paneId = UUID()

        let inlineCommands: [AppCommand] = [
            .minimizePane,
            .closePane,
            .splitRight,
            .detachDrawerPane,
            .movePaneToTab,
        ]
        let contextMenuCommands: [AppCommand] = [
            .extractPaneToTab,
            .movePaneToTab,
        ]

        let presentedInlineCommands = inlineCommands.compactMap {
            PaneLeafCommandPresentation.resolve(
                command: $0,
                surface: .inlineControl,
                targetPaneId: paneId,
                dispatcher: dispatcher
            )
        }
        let presentedContextMenuCommands = contextMenuCommands.compactMap {
            PaneLeafCommandPresentation.resolve(
                command: $0,
                surface: .contextMenu,
                targetPaneId: paneId,
                dispatcher: dispatcher
            )
        }
        let wrongSurface = PaneLeafCommandPresentation.resolve(
            command: .extractPaneToTab,
            surface: .inlineControl,
            targetPaneId: paneId,
            dispatcher: dispatcher
        )
        let wrongTargetKind = PaneLeafCommandPresentation.resolve(
            command: .closePane,
            surface: .inlineControl,
            targetPaneId: paneId,
            targetType: .tab,
            dispatcher: dispatcher
        )

        #expect(presentedInlineCommands.map(\.spec.command) == inlineCommands)
        #expect(presentedContextMenuCommands.map(\.spec.command) == contextMenuCommands)
        #expect(wrongSurface == nil)
        #expect(wrongTargetKind == nil)
    }

    @Test("targeted capability controls enabled state without recreating display metadata")
    func targetedCapabilityControlsEnabledStateAndMetadata() {
        let dispatcher = RecordingPaneLeafCommandDispatcher()
        let paneId = UUID()
        dispatcher.enabledTargets = [
            PaneLeafTargetedCommand(command: .minimizePane, target: paneId, targetType: .pane)
        ]

        let minimizePresentation = PaneLeafCommandPresentation.resolve(
            command: .minimizePane,
            surface: .inlineControl,
            targetPaneId: paneId,
            dispatcher: dispatcher
        )
        let closePresentation = PaneLeafCommandPresentation.resolve(
            command: .closePane,
            surface: .inlineControl,
            targetPaneId: paneId,
            dispatcher: dispatcher
        )

        #expect(minimizePresentation?.isEnabled == true)
        #expect(minimizePresentation?.spec.label == "Minimize Pane")
        #expect(minimizePresentation?.spec.icon == .system(.minusCircle))
        #expect(closePresentation?.isEnabled == false)
        #expect(closePresentation?.spec.label == "Close Pane")
        #expect(closePresentation?.spec.icon == .system(.xmarkSquare))
    }

    @Test("direct pane command delivers command and pane UUID through targeted dispatch")
    func directPaneCommandDeliversTargetedIdentity() {
        let dispatcher = RecordingPaneLeafCommandDispatcher()
        let paneId = UUID()
        let expectedCommand = PaneLeafTargetedCommand(
            command: .splitRight,
            target: paneId,
            targetType: .pane
        )
        dispatcher.enabledTargets = [expectedCommand]
        let presentation = PaneLeafCommandPresentation.resolve(
            command: .splitRight,
            surface: .inlineControl,
            targetPaneId: paneId,
            dispatcher: dispatcher
        )

        presentation?.perform()

        #expect(dispatcher.dispatchedTargets == [expectedCommand])
    }

    @Test("capability is rechecked so a stale pane target is not dispatched")
    func stalePaneTargetIsNotDispatched() {
        let dispatcher = RecordingPaneLeafCommandDispatcher()
        let paneId = UUID()
        let expectedCommand = PaneLeafTargetedCommand(
            command: .closePane,
            target: paneId,
            targetType: .pane
        )
        dispatcher.enabledTargets = [expectedCommand]
        let presentation = PaneLeafCommandPresentation.resolve(
            command: .closePane,
            surface: .inlineControl,
            targetPaneId: paneId,
            dispatcher: dispatcher
        )
        dispatcher.enabledTargets = []

        presentation?.perform()

        #expect(presentation?.isEnabled == true)
        #expect(dispatcher.dispatchedTargets.isEmpty)
    }

    @Test("denied pane target stays disabled and cannot dispatch")
    func deniedPaneTargetCannotDispatch() {
        let dispatcher = RecordingPaneLeafCommandDispatcher()
        let paneId = UUID()
        let presentation = PaneLeafCommandPresentation.resolve(
            command: .detachDrawerPane,
            surface: .inlineControl,
            targetPaneId: paneId,
            dispatcher: dispatcher
        )

        presentation?.perform()

        #expect(presentation?.isEnabled == false)
        #expect(dispatcher.dispatchedTargets.isEmpty)
    }

    @Test("move command preserves source pane and destination tab identities")
    func moveCommandPreservesSourceAndDestinationIdentities() {
        let dispatcher = RecordingPaneLeafCommandDispatcher()
        let sourcePaneId = UUID()
        let sourceTabId = UUID()
        let targetTabId = UUID()
        dispatcher.enabledTargets = [
            PaneLeafTargetedCommand(
                command: .movePaneToTab,
                target: sourcePaneId,
                targetType: .pane
            )
        ]
        let presentation = PaneLeafCommandPresentation.resolve(
            command: .movePaneToTab,
            surface: .inlineControl,
            targetPaneId: sourcePaneId,
            dispatcher: dispatcher
        )

        presentation?.movePane(sourceTabId: sourceTabId, targetTabId: targetTabId)

        #expect(
            dispatcher.moveRequests == [
                PaneLeafMoveRequest(
                    sourcePaneId: sourcePaneId,
                    sourceTabId: sourceTabId,
                    targetTabId: targetTabId
                )
            ])
    }
}

private struct PaneLeafTargetedCommand: Equatable, Hashable {
    let command: AppCommand
    let target: UUID
    let targetType: SearchItemType
}

private struct PaneLeafMoveRequest: Equatable {
    let sourcePaneId: UUID
    let sourceTabId: UUID?
    let targetTabId: UUID
}

@MainActor
private final class RecordingPaneLeafCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    var enabledTargets: Set<PaneLeafTargetedCommand> = []
    private(set) var dispatchedTargets: [PaneLeafTargetedCommand] = []
    private(set) var moveRequests: [PaneLeafMoveRequest] = []

    func dispatch(_: AppCommand) -> Bool { false }

    func dispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) {
        dispatchedTargets.append(
            PaneLeafTargetedCommand(
                command: command,
                target: target,
                targetType: targetType
            )
        )
    }

    func canDispatch(_: AppCommand) -> Bool {
        false
    }

    func canDispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> Bool {
        enabledTargets.contains(
            PaneLeafTargetedCommand(
                command: command,
                target: target,
                targetType: targetType
            )
        )
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(
        sourcePaneId: UUID,
        sourceTabId: UUID?,
        targetTabId: UUID
    ) {
        moveRequests.append(
            PaneLeafMoveRequest(
                sourcePaneId: sourcePaneId,
                sourceTabId: sourceTabId,
                targetTabId: targetTabId
            )
        )
    }
}
