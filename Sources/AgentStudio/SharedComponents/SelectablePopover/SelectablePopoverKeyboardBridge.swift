import AppKit
import SwiftUI
import os.log

private let selectablePopoverKeyboardBridgeLogger = Logger(
    subsystem: "com.agentstudio",
    category: "SelectablePopoverKeyboardBridge"
)

package struct SelectablePopoverAuxiliaryAction<ItemID: Hashable> {
    let trigger: SelectablePopoverAuxiliaryTrigger
    let perform: @MainActor (ItemID) -> Void

    package init(trigger: SelectablePopoverAuxiliaryTrigger, perform: @escaping @MainActor (ItemID) -> Void) {
        self.trigger = trigger
        self.perform = perform
    }
}

package struct SelectablePopoverKeyboardBridge<ItemID: Hashable>: NSViewRepresentable {
    let items: [SelectablePopoverKeyboardItem<ItemID>]
    let selectedItemId: ItemID?
    let auxiliaryAction: SelectablePopoverAuxiliaryAction<ItemID>?
    let onSelect: (ItemID) -> Void
    let onHighlight: (ItemID) -> Void
    let onDismiss: () -> Void
    let matchesAdditionalDismissShortcut: (NSEvent) -> Bool
    /// False when another view, such as a search field, keeps focus. The key
    /// monitor still routes keys while focus is elsewhere in the popover.
    let capturesFirstResponder: Bool

    package init(
        items: [SelectablePopoverKeyboardItem<ItemID>],
        selectedItemId: ItemID?,
        auxiliaryAction: SelectablePopoverAuxiliaryAction<ItemID>?,
        onSelect: @escaping (ItemID) -> Void,
        onHighlight: @escaping (ItemID) -> Void,
        onDismiss: @escaping () -> Void,
        matchesAdditionalDismissShortcut: @escaping (NSEvent) -> Bool,
        capturesFirstResponder: Bool = true
    ) {
        self.items = items
        self.selectedItemId = selectedItemId
        self.auxiliaryAction = auxiliaryAction
        self.onSelect = onSelect
        self.onHighlight = onHighlight
        self.onDismiss = onDismiss
        self.matchesAdditionalDismissShortcut = matchesAdditionalDismissShortcut
        self.capturesFirstResponder = capturesFirstResponder
    }

    package func makeNSView(context _: Context) -> SelectablePopoverFocusCapturingView<ItemID> {
        let view = SelectablePopoverFocusCapturingView<ItemID>()
        update(view)
        return view
    }

    package func updateNSView(_ nsView: SelectablePopoverFocusCapturingView<ItemID>, context _: Context) {
        update(nsView)
        guard capturesFirstResponder else { return }
        // Defer first-responder handoff past SwiftUI's update tick to avoid
        // re-entering state observers while the representable is refreshing.
        Task { @MainActor [weak nsView] in
            guard let nsView, nsView.window?.firstResponder !== nsView else { return }
            guard nsView.window?.makeFirstResponder(nsView) == true else {
                selectablePopoverKeyboardBridgeLogger.warning(
                    "Selectable popover failed to become first responder"
                )
                return
            }
        }
    }

    private func update(_ view: SelectablePopoverFocusCapturingView<ItemID>) {
        view.items = items
        view.selectedItemId = selectedItemId
        view.auxiliaryAction = auxiliaryAction
        view.onSelect = onSelect
        view.onHighlight = onHighlight
        view.onDismiss = onDismiss
        view.matchesAdditionalDismissShortcut = matchesAdditionalDismissShortcut
    }
}

package final class SelectablePopoverFocusCapturingView<ItemID: Hashable>: NSView {
    var items: [SelectablePopoverKeyboardItem<ItemID>] = []
    var selectedItemId: ItemID?
    var auxiliaryAction: SelectablePopoverAuxiliaryAction<ItemID>?
    var onSelect: ((ItemID) -> Void)?
    var onHighlight: ((ItemID) -> Void)?
    var onDismiss: (() -> Void)?
    var matchesAdditionalDismissShortcut: ((NSEvent) -> Bool)?
    private var localMonitor: Any?

    package override var acceptsFirstResponder: Bool { true }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            teardownMonitor()
            return
        }

        installMonitorIfNeeded()
    }

    package override func keyDown(with event: NSEvent) {
        guard apply(event) else {
            super.keyDown(with: event)
            return
        }
    }

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if apply(event) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    package override func cancelOperation(_ sender: Any?) {
        _ = sender
        onDismiss?()
    }

    package override func moveUp(_ sender: Any?) {
        _ = sender
        highlightSelection(delta: -1)
    }

    package override func moveDown(_ sender: Any?) {
        _ = sender
        highlightSelection(delta: 1)
    }

    package override func insertNewline(_ sender: Any?) {
        _ = sender
        activateCurrentSelection()
    }

    private func apply(_ event: NSEvent) -> Bool {
        switch SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: selectedItemId,
            auxiliaryTrigger: auxiliaryAction?.trigger,
            matchesAdditionalDismissShortcut: matchesAdditionalDismissShortcut ?? { _ in false }
        ) {
        case .dismiss:
            onDismiss?()
        case .select(let itemId):
            onSelect?(itemId)
        case .auxiliary(let itemId):
            auxiliaryAction?.perform(itemId)
        case .highlight(let itemId):
            onHighlight?(itemId)
        case .consume:
            return true
        case .passthrough:
            return false
        }

        return true
    }

    private func installMonitorIfNeeded() {
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.eventBelongsToThisPopover(event) else { return event }
            return self.apply(event) ? nil : event
        }
    }

    // AppKit removes the view from its window before teardown, which gives us
    // a main-actor cleanup point. Do not move this into deinit; the monitor
    // token is non-Sendable under Swift 6 strict concurrency.
    private func teardownMonitor() {
        guard let localMonitor else { return }
        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }

    private func eventBelongsToThisPopover(_ event: NSEvent) -> Bool {
        guard let popoverWindow = window else { return false }

        if let eventWindow = event.window {
            return eventWindow == popoverWindow
                || eventWindow.parent == popoverWindow
                || popoverWindow.parent == eventWindow
        }

        if event.windowNumber != 0 {
            return event.windowNumber == popoverWindow.windowNumber
        }

        if let keyWindow = NSApp.keyWindow {
            return keyWindow == popoverWindow
                || keyWindow.parent == popoverWindow
                || popoverWindow.parent == keyWindow
        }

        return false
    }

    private func highlightSelection(delta: Int) {
        guard
            let itemId = SelectablePopoverKeyboardRouter.movedSelection(
                delta: delta,
                items: items,
                selectedItemId: selectedItemId
            )
        else {
            return
        }

        onHighlight?(itemId)
    }

    private func activateCurrentSelection() {
        guard
            let itemId = SelectablePopoverKeyboardRouter.currentSelection(
                items: items,
                selectedItemId: selectedItemId
            )
        else {
            return
        }

        onSelect?(itemId)
    }
}
