import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioSharedComponents
@testable import AgentStudioTestSupport

@MainActor
@Suite("PaneInboxNotificationPopover", .serialized)
struct PaneInboxNotificationPopoverTests {
    @Test("retired pane clear command has no presentation")
    func retiredPaneClearCommandHasNoPresentation() {
        let paneId = UUID()
        let dispatcher = PaneInboxCommandDispatcherProbe()

        let presentation = PaneInboxClearCommandPresentation.resolve(
            targetPaneId: paneId,
            dispatcher: dispatcher
        )

        #expect(presentation == nil)
        #expect(dispatcher.capabilityQueries.isEmpty)
    }

    @Test("retired pane clear command does not query capability")
    func retiredPaneClearCommandDoesNotQueryCapability() {
        let paneId = UUID()
        let dispatcher = PaneInboxCommandDispatcherProbe(targetedCapability: false)
        let presentation = PaneInboxClearCommandPresentation.resolve(
            targetPaneId: paneId,
            dispatcher: dispatcher
        )

        #expect(presentation == nil)
        #expect(dispatcher.capabilityQueries.isEmpty)
        #expect(dispatcher.dispatchedTargets.isEmpty)
    }

    @Test("mounted dormant pane Inbox omits the retired clear command")
    func mountedDormantPaneInboxOmitsRetiredClearCommand() throws {
        let commandDispatcher = PaneInboxCommandDispatcherProbe()

        try withMountedClearButton(commandDispatcher: commandDispatcher) { clearButton, _ in
            #expect(clearButton == nil)
            #expect(commandDispatcher.capabilityQueries.isEmpty)
            #expect(commandDispatcher.dispatchedTargets.isEmpty)
        }
    }

    private func withMountedClearButton(
        commandDispatcher: PaneInboxCommandDispatcherProbe,
        assertions: (AccessibilityPressBridgeView?, UUID) -> Void
    ) throws {
        let parentPaneId = UUID()
        let inboxAtom = InboxNotificationAtom()
        let prefsAtom = InboxNotificationPrefsAtom()
        let presentationAtom = PaneInboxPresentationAtom()

        withTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore(
                catalogAtom: coreAtoms.workspaceRepositoryTopology,
                graphAtom: coreAtoms.workspacePane,
                interactionAtom: coreAtoms.workspaceTabLayout
            )
            let parentPane = store.createPane(
                content: .terminal(
                    TerminalState(
                        provider: .zmx,
                        lifetime: .persistent,
                        zmxSessionID: .generateUUIDv7()
                    )
                ),
                metadata: PaneMetadata(
                    paneId: PaneId(existingUUID: parentPaneId),
                    contentType: .terminal,
                    launchDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    title: "Parent"
                )
            )
            let tab = Tab(paneId: parentPane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            coreAtoms.workspaceFocusOwner.focusMainPane(parentPane.id)

            let hostingView = NSHostingView(
                rootView: PaneInboxNotificationPopover(
                    parentPaneId: parentPaneId,
                    octiconLoader: makeInboxNotificationTestOcticonLoader(),
                    workspaceWindowId: nil,
                    paneIds: [parentPaneId],
                    inboxAtom: inboxAtom,
                    prefsAtom: prefsAtom,
                    presentationAtom: presentationAtom,
                    commandDispatcher: commandDispatcher,
                    onActivate: { _ in },
                    onFocusPane: { _ in },
                    onClose: {}
                )
                .frame(width: 360, height: 240)
            )
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            hostingView.layoutSubtreeIfNeeded()

            let clearButton =
                findAccessibleElement(in: hostingView, identifier: "paneInboxClearButton")
                as? AccessibilityPressBridgeView
            assertions(clearButton, parentPaneId)
        }
    }

}

private struct PaneInboxCommandQuery: Equatable {
    let command: AppCommand
    let target: UUID
    let targetType: SearchItemType
}

@MainActor
private final class PaneInboxCommandDispatcherProbe: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    private let targetedCapability: Bool
    private(set) var capabilityQueries: [PaneInboxCommandQuery] = []
    private(set) var dispatchedTargets: [PaneInboxCommandQuery] = []

    init(targetedCapability: Bool = true) {
        self.targetedCapability = targetedCapability
    }

    func dispatch(_: AppCommand) -> Bool { false }

    func dispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) {
        dispatchedTargets.append(
            PaneInboxCommandQuery(
                command: command,
                target: target,
                targetType: targetType
            )
        )
    }

    func canDispatch(_: AppCommand) -> Bool {
        false
    }

    func canDispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        capabilityQueries.append(
            PaneInboxCommandQuery(
                command: command,
                target: target,
                targetType: targetType
            )
        )
        return targetedCapability
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}

@MainActor
private func findAccessibleElement(in root: AnyObject, identifier: String) -> AnyObject? {
    var visited: Set<ObjectIdentifier> = []
    return findAccessibleElement(in: root, identifier: identifier, visited: &visited)
}

@MainActor
private func findAccessibleElement(
    in element: AnyObject,
    identifier: String,
    visited: inout Set<ObjectIdentifier>
) -> AnyObject? {
    let objectIdentifier = ObjectIdentifier(element)
    guard visited.insert(objectIdentifier).inserted else { return nil }

    if accessibilityIdentifier(of: element) == identifier {
        return element
    }

    for child in accessibilityChildren(of: element) {
        if let match = findAccessibleElement(in: child, identifier: identifier, visited: &visited) {
            return match
        }
    }

    for subview in (element as? NSView)?.subviews ?? [] {
        if let match = findAccessibleElement(in: subview, identifier: identifier, visited: &visited) {
            return match
        }
    }

    return nil
}

private func accessibilityIdentifier(of element: AnyObject) -> String? {
    let selector = NSSelectorFromString("accessibilityIdentifier")
    guard element.responds(to: selector) else { return nil }
    return element.perform(selector)?.takeUnretainedValue() as? String
}

private func accessibilityChildren(of element: AnyObject) -> [AnyObject] {
    let selector = NSSelectorFromString("accessibilityChildren")
    guard element.responds(to: selector) else { return [] }
    return element.perform(selector)?.takeUnretainedValue() as? [AnyObject] ?? []
}

private func pressAccessibleElement(_ element: AnyObject) {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard element.responds(to: selector) else { return }
    _ = element.perform(selector)
}
