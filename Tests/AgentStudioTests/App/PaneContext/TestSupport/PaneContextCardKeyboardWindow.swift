import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

/// Mounts two real card request blocks in one window; literal request values isolate focus ownership from service admission.
@MainActor
final class PaneContextCardKeyboardWindow {
    struct Card {
        let pane: PaneId
        let row: MessageRowModel
    }
    final class KeyReceiver: NSView {
        var received: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { received.append(event.characters ?? "") }
    }

    let cards: [Card]
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let keyReceiver = KeyReceiver(frame: .init(x: 0, y: 0, width: 4, height: 4))
    let monitor: ManagementLayerMonitor
    let workspaceWindowId = UUIDv7.generate()
    private let bindings: PaneContextPopoverHostBindings
    private let interactions: PaneContextPopoverInteractionState
    private var closed = false

    static func make() async throws -> PaneContextCardKeyboardWindow {
        installTestCoreAtomsIfNeeded()
        try #require(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
        try #require(!CoreAtomScope.store.managementLayer.isActive)
        var cards: [Card] = []
        for index in 0..<2 {
            let pane = PaneId.generateUUIDv7()
            let message = try PaneContextPopoverShapingTests.message(
                paneId: pane, shape: .ask(.question, .freeText(placeholder: "Reply \(index)"), .nonBlocking, .open),
                importance: .attention)
            cards.append(.init(pane: pane, row: try await PaneContextPopoverShapingTests.onlyRow(message)))
        }
        return PaneContextCardKeyboardWindow(cards: cards)
    }

    private init(cards: [Card]) {
        self.cards = cards
        let atoms = CoreAtomScope.store
        atoms.windowLifecycle.recordWindowRegistered(workspaceWindowId)
        atoms.windowLifecycle.recordWindowBecameKey(workspaceWindowId)
        atoms.managementLayer.activate()
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: PaneContextPresentationAtom(),
            pane: { _ in nil }, serviceProvider: { nil })
        let bindings = owners.bindings(clock: TestPushClock(), wallNow: { .distantPast })
        self.bindings = bindings
        let readers = PaneContextUIReaders(
            sessionStatus: owners.sessionStatus, presentation: owners.presentation, pane: owners.pane,
            popoverBindings: bindings)
        let interactions = PaneContextPopoverInteractionState()
        interactions.beginOpening(1)
        self.interactions = interactions
        let versions = Dictionary(uniqueKeysWithValues: cards.map { ($0.row.key, UUIDv7.generate()) })
        let input = interactions.bindings(versions: versions, opening: 1, currentVersions: { versions })
        let actions = MessagesPopoverActions(
            answer: { _, _, _ in }, dismiss: { _, _ in }, dismissAllNotices: {}, runAction: { _, _, _ in },
            goToPane: { _ in }, moreMessages: { _ in }, moreSources: { _ in }, dismissPopover: {},
            captureBodyGeometry: { _, _ in })
        let content = VStack {
            ForEach(cards.indices, id: \.self) { index in
                PaneContextCardRequestBlock(
                    request: .ask(cards[index].row), actions: actions, readers: readers, interactions: input,
                    owner: cards[index].pane, octiconLoader: makeTestOcticonLoader(),
                    onActionCompleted: {}, onActionTaskStarted: { _ in })
            }
        }
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(content))
        host.frame = .init(x: 0, y: 0, width: 640, height: 600)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.addSubview(keyReceiver)
        window.makeKeyAndOrderFront(nil)
        monitor = ManagementLayerMonitor(commandDispatcher: AppTerminalFixtureCommandDispatcher())
        render()
    }

    @discardableResult func focusCard(_ index: Int) throws -> NSTextField {
        let field = try #require(editableFields(host).first { $0.placeholderString == "Reply \(index)" })
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        try #require(window.firstResponder === editor)
        return field
    }

    func focusReceiver() throws {
        try #require(window.makeFirstResponder(keyReceiver))
        try #require(window.firstResponder === keyReceiver)
    }

    func send(_ text: String, code: UInt16) throws {
        NSApp.sendEvent(
            try #require(
                makeKeyEvent(
                    characters: text, charactersIgnoringModifiers: text, keyCode: code,
                    windowNumber: window.windowNumber)))
    }

    func render() {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func retireCards() {
        host.rootView = AnyView(EmptyView())
        render()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        monitor.stopMonitoring()
        retireCards()
        let paneIds = Set(cards.map { $0.pane.uuid })
        let leftovers = CoreAtomScope.store.transientKeyboardSurface.surfaces.filter {
            if case .paneContextCardTextForm(let pane) = $0.kind { return paneIds.contains(pane) }
            return false
        }
        #expect(
            leftovers.isEmpty, "Actual card retirement must withdraw every owned registration before harness cleanup")
        // Preserve the failure above, then retire only this fixture's data if the deliberately broken subject leaked it.
        for surface in leftovers { CoreAtomScope.store.transientKeyboardSurface.dismiss(surface.token) }
        monitor.deactivate()
        window.contentView = nil
        window.close()
        await bindings.stop()
        interactions.close()
        let lifecycle = CoreAtomScope.store.windowLifecycle
        lifecycle.recordWindowResignedKey(workspaceWindowId)
        lifecycle.recordWindowResignedFocused(workspaceWindowId)
    }

    private func editableFields(_ root: NSView) -> [NSTextField] {
        let own = (root as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + root.subviews.flatMap(editableFields)
    }
}
