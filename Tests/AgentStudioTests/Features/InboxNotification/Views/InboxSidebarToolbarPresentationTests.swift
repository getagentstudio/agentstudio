import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioInboxNotification

@Suite("InboxSidebarToolbarPresentation")
struct InboxSidebarToolbarPresentationTests {
    @Test("retired sidebar command presentation exposes no inline controls")
    @MainActor
    func sidebarCommandPresentationIncludesExactContextualInlineControls() {
        let presentation = InboxSidebarCommandPresentation(commandContext: .empty)

        #expect(presentation.sort == nil)
        #expect(presentation.rowStateFilter == nil)
        #expect(presentation.contentMode == nil)
        #expect(presentation.clearRead == nil)
        #expect(presentation.clearAll == nil)
        #expect(presentation.groupingOptions.isEmpty)
    }

    @Test("sidebar command capability remains separate from presentation")
    @MainActor
    func sidebarCommandCapabilityRemainsSeparateFromPresentation() {
        let dispatcher = InboxSidebarCommandDispatcherProbe(
            deniedCommands: [.clearAllInboxNotifications]
        )
        let presentation = InboxSidebarCommandPresentation(commandContext: .empty)
        let capability = InboxSidebarCommandCapability(dispatcher: dispatcher)

        #expect(presentation.clearAll == nil)
        #expect(capability.canDispatch(.clearReadInboxNotifications))
        #expect(!capability.canDispatch(.clearAllInboxNotifications))
    }

    @Test("retired delete commands have no sidebar presentation")
    @MainActor
    func deleteCommandRowsSourcePresentationFromCommandSpecs() throws {
        let presentation = InboxSidebarCommandPresentation(commandContext: .empty)
        #expect(presentation.clearRead == nil)
        #expect(presentation.clearAll == nil)
    }

}

@MainActor
private final class InboxSidebarCommandDispatcherProbe: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    private let deniedCommands: Set<AppCommand>

    init(deniedCommands: Set<AppCommand>) {
        self.deniedCommands = deniedCommands
    }

    func dispatch(_: AppCommand) -> Bool { false }

    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}

    func canDispatch(_ command: AppCommand) -> Bool {
        !deniedCommands.contains(command)
    }

    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        true
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
