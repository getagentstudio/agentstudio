import AppKit
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct EditorChooserKeyboardRouterTests {
    private let items = [
        EditorChoiceItem(id: "cursor", title: "Cursor", appIcon: nil, shortcutNumber: 1),
        EditorChoiceItem(id: "vscode", title: "VS Code", appIcon: nil, shortcutNumber: 2),
        EditorChoiceItem(id: "xcode", title: "Xcode", appIcon: nil, shortcutNumber: 3),
    ]

    @Test
    func escape_dismissesChooser() {
        guard
            let event = makeKeyEvent(
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                keyCode: 53
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "cursor",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .dismiss)
    }

    @Test
    func additionalDismissShortcut_dismissesChooser() {
        guard
            let event = makeKeyEvent(
                modifierFlags: [.command, .option],
                characters: "o",
                charactersIgnoringModifiers: "o",
                keyCode: 31
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "cursor",
            matchesAdditionalDismissShortcut: { event in
                let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return event.keyCode == 31
                    && normalizedFlags.contains(.command)
                    && normalizedFlags.contains(.option)
            }
        )

        #expect(action == .dismiss)
    }

    @Test
    func digitShortcut_selectsMatchingEditor() {
        guard
            let event = makeKeyEvent(
                characters: "2",
                charactersIgnoringModifiers: "2",
                keyCode: 19
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "cursor",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .select("vscode"))
    }

    @Test
    func outOfRangeDigit_passesThroughWithoutSelection() {
        guard
            let event = makeKeyEvent(
                characters: "9",
                charactersIgnoringModifiers: "9",
                keyCode: 25
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "cursor",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .passthrough)
    }

    @Test
    func enter_selectsCurrentItem() {
        guard let event = makeKeyEvent(keyCode: 36) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "vscode",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .select("vscode"))
    }

    @Test
    func arrowDown_highlightsNextItem() {
        guard let event = makeKeyEvent(keyCode: 125) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "cursor",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .highlight("vscode"))
    }

    @Test
    func arrowUp_clampsAtFirstItem() {
        guard let event = makeKeyEvent(keyCode: 126) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "cursor",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .highlight("cursor"))
    }

    @Test
    func bookmarkShortcut_togglesCurrentItem() {
        guard
            let event = makeKeyEvent(
                characters: "b",
                charactersIgnoringModifiers: "b",
                keyCode: 11
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = EditorChooserKeyboardRouter.action(
            for: event,
            items: items,
            selectedEditorId: "xcode",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .toggleBookmark("xcode"))
    }
}
