import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

/// What the keyboard bridge asked the popover to do.
@MainActor @Observable
private final class SearchPopoverKeyboardRecorder {
    var highlighted: [String] = []
    var selected: [String] = []
    var closed: [String] = []
    var dismissals = 0
}

/// A search field that keeps focus, with the selectable-popover bridge beside
/// it not capturing focus: the shape of the browser tab picker.
private struct SearchPopoverHarnessView: View {
    private enum Focus: Hashable { case search }

    let recorder: SearchPopoverKeyboardRecorder
    @State private var query = ""
    @FocusState private var focus: Focus?

    private static let items = [
        SelectablePopoverKeyboardItem(id: "a", supportsAuxiliaryAction: true),
        SelectablePopoverKeyboardItem(id: "b", supportsAuxiliaryAction: true),
        SelectablePopoverKeyboardItem(id: "c", supportsAuxiliaryAction: false),
    ]

    var body: some View {
        SidebarSearchField(placeholder: "Search", text: $query, focusedField: $focus, focusValue: Focus.search)
            .background(
                SelectablePopoverKeyboardBridge(
                    items: Self.items,
                    selectedItemId: "b",
                    auxiliaryAction: SelectablePopoverAuxiliaryAction(trigger: .commandDelete) {
                        recorder.closed.append($0)
                    },
                    onSelect: { recorder.selected.append($0) },
                    onHighlight: { recorder.highlighted.append($0) },
                    onDismiss: { recorder.dismissals += 1 },
                    matchesAdditionalDismissShortcut: { _ in false },
                    capturesFirstResponder: false
                )
                .frame(width: 0, height: 0)
            )
            .frame(width: 320)
    }
}

/// R9 through the real AppKit path: keys sent to the window reach the bridge's
/// key monitor while the search field keeps focus. Arrows, Return, Escape and
/// Command-Delete act on the rows; typed text and plain Delete stay in search.
@MainActor
@Suite(.serialized)
struct SelectablePopoverSearchFieldKeyboardTests {
    @Test("keys act on rows while the search field keeps focus, and typed text stays in search")
    func keysReachRowsWhileSearchKeepsFocus() throws {
        // Arrange: a key window holding the search field and the bridge.
        _ = NSApplication.shared
        let recorder = SearchPopoverKeyboardRecorder()
        let host = NSHostingView(rootView: SearchPopoverHarnessView(recorder: recorder))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let field = try #require(Self.editableFields(host).first, "the search field is mounted")
        field.selectText(nil)
        let editor = try #require(field.currentEditor(), "the search field took focus")

        func send(
            _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
        ) throws {
            NSApp.sendEvent(
                try #require(
                    makeKeyEvent(
                        modifierFlags: modifiers, characters: characters, charactersIgnoringModifiers: characters,
                        keyCode: keyCode, windowNumber: window.windowNumber)))
        }

        // Act and assert, one key at a time.
        try send("x", keyCode: 7)
        #expect(field.stringValue == "x", "a typed letter must reach search")

        try send("\u{F701}", keyCode: 125, modifiers: [.function, .numericPad])
        #expect(recorder.highlighted == ["c"], "Down must move the highlight, not the search cursor")

        try send("\u{F700}", keyCode: 126, modifiers: [.function, .numericPad])
        #expect(recorder.highlighted == ["c", "a"])

        try send("\u{7f}", keyCode: 51, modifiers: .command)
        #expect(recorder.closed == ["b"], "Command-Delete must close the highlighted row")
        #expect(field.stringValue == "x", "Command-Delete must not edit search")

        try send("\u{7f}", keyCode: 51)
        #expect(field.stringValue.isEmpty, "plain Delete must edit search")
        #expect(recorder.closed == ["b"])

        try send("\r", keyCode: 36)
        #expect(recorder.selected == ["b"], "Return must choose the highlighted row")

        try send("\u{1b}", keyCode: 53)
        #expect(recorder.dismissals == 1, "Escape must dismiss")

        #expect(window.firstResponder === editor, "search must keep focus throughout")
    }

    private static func editableFields(_ root: NSView) -> [NSTextField] {
        let own = (root as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + root.subviews.flatMap { editableFields($0) }
    }
}
