import AppKit
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct SelectablePopoverKeyboardBridgeTests {
    @Test("focus view invokes configured auxiliary action")
    func focusViewInvokesConfiguredAuxiliaryAction() throws {
        let view = SelectablePopoverFocusCapturingView<String>()
        var auxiliaryItemId: String?
        view.items = [
            SelectablePopoverKeyboardItem(id: "first", shortcutNumber: 1, supportsAuxiliaryAction: true)
        ]
        view.selectedItemId = "first"
        view.auxiliaryAction = SelectablePopoverAuxiliaryAction(trigger: .character("b")) { itemId in
            auxiliaryItemId = itemId
        }

        let handled = view.performKeyEquivalent(
            with: try #require(
                makeKeyEvent(
                    characters: "b",
                    charactersIgnoringModifiers: "b",
                    keyCode: 11
                )
            )
        )

        #expect(handled)
        #expect(auxiliaryItemId == "first")
    }

    @Test("focus view passes auxiliary key through when no auxiliary action exists")
    func focusViewPassesAuxiliaryKeyThroughWhenNoAuxiliaryActionExists() throws {
        let view = SelectablePopoverFocusCapturingView<String>()
        view.items = [
            SelectablePopoverKeyboardItem(id: "first", shortcutNumber: 1, supportsAuxiliaryAction: true)
        ]
        view.selectedItemId = "first"
        view.auxiliaryAction = nil

        let handled = view.performKeyEquivalent(
            with: try #require(
                makeKeyEvent(
                    characters: "b",
                    charactersIgnoringModifiers: "b",
                    keyCode: 11
                )
            )
        )

        #expect(!handled)
    }

    @Test("focus view selects current item on Return")
    func focusViewSelectsCurrentItemOnReturn() throws {
        let view = SelectablePopoverFocusCapturingView<String>()
        var selectedItemId: String?
        view.items = [
            SelectablePopoverKeyboardItem(id: "first", shortcutNumber: 1),
            SelectablePopoverKeyboardItem(id: "second", shortcutNumber: 2),
        ]
        view.selectedItemId = "second"
        view.onSelect = { itemId in
            selectedItemId = itemId
        }

        let handled = view.performKeyEquivalent(
            with: try #require(makeKeyEvent(keyCode: 36))
        )

        #expect(handled)
        #expect(selectedItemId == "second")
    }

    @Test("focus view dismisses on Escape")
    func focusViewDismissesOnEscape() throws {
        let view = SelectablePopoverFocusCapturingView<String>()
        var dismissCount = 0
        view.onDismiss = {
            dismissCount += 1
        }

        let handled = view.performKeyEquivalent(
            with: try #require(
                makeKeyEvent(
                    characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}",
                    keyCode: 53
                )
            )
        )

        #expect(handled)
        #expect(dismissCount == 1)
    }

    @Test("focus view highlights next item on Down Arrow")
    func focusViewHighlightsNextItemOnDownArrow() throws {
        let view = SelectablePopoverFocusCapturingView<String>()
        var highlightedItemId: String?
        view.items = [
            SelectablePopoverKeyboardItem(id: "first", shortcutNumber: 1),
            SelectablePopoverKeyboardItem(id: "second", shortcutNumber: 2),
        ]
        view.selectedItemId = "first"
        view.onHighlight = { itemId in
            highlightedItemId = itemId
        }

        let handled = view.performKeyEquivalent(
            with: try #require(makeKeyEvent(keyCode: 125))
        )

        #expect(handled)
        #expect(highlightedItemId == "second")
    }

    @Test("focus view dismisses through cancelOperation key binding")
    func focusViewDismissesThroughCancelOperationKeyBinding() {
        let view = SelectablePopoverFocusCapturingView<String>()
        var dismissCount = 0
        view.onDismiss = {
            dismissCount += 1
        }

        view.cancelOperation(nil)

        #expect(dismissCount == 1)
    }

    @Test("focus view highlights through moveDown key binding")
    func focusViewHighlightsThroughMoveDownKeyBinding() {
        let view = SelectablePopoverFocusCapturingView<String>()
        var highlightedItemId: String?
        view.items = [
            SelectablePopoverKeyboardItem(id: "first", shortcutNumber: 1),
            SelectablePopoverKeyboardItem(id: "second", shortcutNumber: 2),
        ]
        view.selectedItemId = "first"
        view.onHighlight = { itemId in
            highlightedItemId = itemId
        }

        view.moveDown(nil)

        #expect(highlightedItemId == "second")
    }

    @Test("focus view selects through insertNewline key binding")
    func focusViewSelectsThroughInsertNewlineKeyBinding() {
        let view = SelectablePopoverFocusCapturingView<String>()
        var selectedItemId: String?
        view.items = [
            SelectablePopoverKeyboardItem(id: "first", shortcutNumber: 1),
            SelectablePopoverKeyboardItem(id: "second", shortcutNumber: 2),
        ]
        view.selectedItemId = "second"
        view.onSelect = { itemId in
            selectedItemId = itemId
        }

        view.insertNewline(nil)

        #expect(selectedItemId == "second")
    }
}
