import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Targeted command-backed pane controls")
struct TargetedCommandControlActionTests {
    @Test("arrangement actions request exact inline and context-menu surfaces")
    func arrangementActionsRequestExactSurfaces() throws {
        let arrangementId = UUID()
        let recorder = RecordingTargetedCommandActionResolver()
        let arrangement = ArrangementInfo(
            id: arrangementId,
            name: "Review",
            role: .userLayout,
            isActive: false
        )

        let presentation = ArrangementPanelCommandPresentation.resolve(
            arrangement: arrangement,
            actionResolver: recorder.resolve
        )

        #expect(
            recorder.requests == [
                .init(
                    command: .switchArrangement,
                    surface: .inlineControl,
                    target: arrangementId,
                    targetType: .tab
                ),
                .init(
                    command: .renameArrangement,
                    surface: .inlineControl,
                    target: arrangementId,
                    targetType: .tab
                ),
                .init(
                    command: .renameArrangement,
                    surface: .contextMenu,
                    target: arrangementId,
                    targetType: .tab
                ),
                .init(
                    command: .deleteArrangement,
                    surface: .contextMenu,
                    target: arrangementId,
                    targetType: .tab
                ),
            ])
        #expect(presentation.switchArrangement?.commandSpec.command == .switchArrangement)
        #expect(presentation.inlineRenameArrangement?.commandSpec.command == .renameArrangement)
        #expect(presentation.contextMenuRenameArrangement?.commandSpec.command == .renameArrangement)
        #expect(presentation.contextMenuDeleteArrangement?.commandSpec.command == .deleteArrangement)
    }

    @Test("default arrangement keeps switch but omits rename and delete")
    func defaultArrangementOmitsMutationActions() {
        let arrangementId = UUID()
        let recorder = RecordingTargetedCommandActionResolver()
        let arrangement = ArrangementInfo(
            id: arrangementId,
            name: "Default",
            role: .defaultArrangement,
            isActive: true
        )

        let presentation = ArrangementPanelCommandPresentation.resolve(
            arrangement: arrangement,
            actionResolver: recorder.resolve
        )

        #expect(
            recorder.requests == [
                .init(
                    command: .switchArrangement,
                    surface: .inlineControl,
                    target: arrangementId,
                    targetType: .tab
                )
            ])
        #expect(presentation.switchArrangement != nil)
        #expect(presentation.inlineRenameArrangement == nil)
        #expect(presentation.contextMenuRenameArrangement == nil)
        #expect(presentation.contextMenuDeleteArrangement == nil)
    }

    @Test("save arrangement requests canonical inline command targeting the tab UUID")
    func saveArrangementRequestsCanonicalInlineTabTarget() throws {
        let tabId = UUID()
        let recorder = RecordingTargetedCommandActionResolver()

        let action = try #require(
            ArrangementPanelCommandPresentation.resolveSaveArrangement(
                tabId: tabId,
                actionResolver: recorder.resolve
            )
        )

        #expect(
            recorder.requests == [
                .init(
                    command: .saveArrangement,
                    surface: .inlineControl,
                    target: tabId,
                    targetType: .tab
                )
            ])
        #expect(action.commandSpec.command == .saveArrangement)
    }

    @Test("collapsed pane actions use their exact context-menu and inline surfaces")
    func collapsedPaneActionsUseExactSurfaces() {
        let paneId = UUID()
        let recorder = RecordingTargetedCommandActionResolver()

        _ = CollapsedPaneBarCommandPresentation.resolve(
            paneId: paneId,
            actionResolver: recorder.resolve
        )

        #expect(
            recorder.requests == [
                .init(
                    command: .expandPane,
                    surface: .contextMenu,
                    target: paneId,
                    targetType: .pane
                ),
                .init(
                    command: .closePane,
                    surface: .contextMenu,
                    target: paneId,
                    targetType: .pane
                ),
                .init(
                    command: .expandPane,
                    surface: .inlineControl,
                    target: paneId,
                    targetType: .pane
                ),
            ])
    }

    @Test("resolver rejects unsupported surface and target kind before capability")
    func resolverRejectsUnsupportedPresentationBeforeCapability() {
        let dispatcher = RecordingTargetedCommandDispatcher()
        let arrangementId = UUID()

        let unsupportedSurface = TargetedCommandControlAction.resolve(
            command: .deleteArrangement,
            surface: .inlineControl,
            target: arrangementId,
            targetType: .tab,
            dispatcher: dispatcher
        )
        let unsupportedTargetKind = TargetedCommandControlAction.resolve(
            command: .renameArrangement,
            surface: .inlineControl,
            target: arrangementId,
            targetType: .pane,
            dispatcher: dispatcher
        )

        #expect(unsupportedSurface == nil)
        #expect(unsupportedTargetKind == nil)
        #expect(dispatcher.capabilityQueries.isEmpty)
    }

    @Test("resolver preserves targeted disabled state and canonical presentation")
    func resolverPreservesDisabledStateAndCanonicalPresentation() throws {
        let dispatcher = RecordingTargetedCommandDispatcher()
        let arrangementId = UUID()

        let action = try #require(
            TargetedCommandControlAction.resolve(
                command: .renameArrangement,
                surface: .inlineControl,
                target: arrangementId,
                targetType: .tab,
                dispatcher: dispatcher
            )
        )

        #expect(action.commandSpec.command == .renameArrangement)
        #expect(action.commandSpec.label == AppCommand.renameArrangement.definition.label)
        #expect(action.commandSpec.icon == AppCommand.renameArrangement.definition.icon)
        #expect(!action.isEnabled)
        #expect(
            dispatcher.capabilityQueries == [
                .init(command: .renameArrangement, target: arrangementId, targetType: .tab)
            ])
    }

    @Test("execution rechecks stale capability before targeted dispatch")
    func executionRechecksStaleCapability() throws {
        let dispatcher = RecordingTargetedCommandDispatcher()
        let paneId = UUID()
        let query = TargetedCommandQuery(
            command: .expandPane,
            target: paneId,
            targetType: .pane
        )
        dispatcher.enabledQueries = [query]
        let action = try #require(
            TargetedCommandControlAction.resolve(
                command: .expandPane,
                surface: .inlineControl,
                target: paneId,
                targetType: .pane,
                dispatcher: dispatcher
            )
        )
        dispatcher.enabledQueries = []

        action.perform()

        #expect(dispatcher.capabilityQueries == [query, query])
        #expect(dispatcher.dispatchedQueries.isEmpty)
    }

    @Test("enabled execution delivers the command and target UUID")
    func enabledExecutionDeliversCommandAndTarget() throws {
        let dispatcher = RecordingTargetedCommandDispatcher()
        let arrangementId = UUID()
        let query = TargetedCommandQuery(
            command: .switchArrangement,
            target: arrangementId,
            targetType: .tab
        )
        dispatcher.enabledQueries = [query]
        let action = try #require(
            TargetedCommandControlAction.resolve(
                command: .switchArrangement,
                surface: .inlineControl,
                target: arrangementId,
                targetType: .tab,
                dispatcher: dispatcher
            )
        )

        action.perform()

        #expect(dispatcher.capabilityQueries == [query, query])
        #expect(dispatcher.dispatchedQueries == [query])
    }
}

private struct TargetedCommandActionRequest: Equatable {
    let command: AppCommand
    let surface: AppCommandSurface
    let target: UUID
    let targetType: SearchItemType
}

@MainActor
private final class RecordingTargetedCommandActionResolver {
    private(set) var requests: [TargetedCommandActionRequest] = []

    func resolve(
        command: AppCommand,
        surface: AppCommandSurface,
        target: UUID,
        targetType: SearchItemType
    ) -> TargetedCommandControlAction? {
        requests.append(
            TargetedCommandActionRequest(
                command: command,
                surface: surface,
                target: target,
                targetType: targetType
            )
        )
        return TargetedCommandControlAction(
            commandSpec: command.definition,
            isEnabled: true,
            perform: {}
        )
    }
}

private struct TargetedCommandQuery: Equatable, Hashable {
    let command: AppCommand
    let target: UUID
    let targetType: SearchItemType
}

@MainActor
private final class RecordingTargetedCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    var enabledQueries: Set<TargetedCommandQuery> = []
    private(set) var capabilityQueries: [TargetedCommandQuery] = []
    private(set) var dispatchedQueries: [TargetedCommandQuery] = []

    func dispatch(_: AppCommand) -> Bool { false }

    func dispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) {
        dispatchedQueries.append(
            TargetedCommandQuery(
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
        let query = TargetedCommandQuery(
            command: command,
            target: target,
            targetType: targetType
        )
        capabilityQueries.append(query)
        return enabledQueries.contains(query)
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(
        sourcePaneId _: UUID,
        sourceTabId _: UUID?,
        targetTabId _: UUID
    ) {}
}
