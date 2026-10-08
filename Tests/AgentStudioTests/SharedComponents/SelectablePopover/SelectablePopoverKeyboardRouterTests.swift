import AppKit
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct SelectablePopoverKeyboardRouterTests {
    private let items = [
        SelectablePopoverKeyboardItem(id: "first", shortcutNumber: 1, supportsAuxiliaryAction: true),
        SelectablePopoverKeyboardItem(id: "second", shortcutNumber: 2, supportsAuxiliaryAction: true),
        SelectablePopoverKeyboardItem(id: "third", shortcutNumber: 3, supportsAuxiliaryAction: false),
    ]

    @Test
    func escape_dismissesPopover() {
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

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .dismiss)
    }

    @Test
    func additionalDismissShortcut_dismissesPopover() {
        guard
            let event = makeKeyEvent(
                modifierFlags: [.command, .shift],
                characters: "i",
                charactersIgnoringModifiers: "i",
                keyCode: 34
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return event.keyCode == 34 && flags.contains(.command) && flags.contains(.shift)
            }
        )

        #expect(action == .dismiss)
    }

    @Test
    func return_selectsCurrentItem() {
        guard let event = makeKeyEvent(keyCode: 36) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "second",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .select("second"))
    }

    @Test
    func downArrow_highlightsNextItem() {
        guard let event = makeKeyEvent(keyCode: 125) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .highlight("second"))
    }

    @Test
    func upArrow_highlightsPreviousItem() {
        guard let event = makeKeyEvent(keyCode: 126) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "second",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .highlight("first"))
    }

    @Test
    func shortcutNumber_selectsMatchingItem() {
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

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .select("second"))
    }

    @Test
    func zero_passthroughs() {
        guard
            let event = makeKeyEvent(
                characters: "0",
                charactersIgnoringModifiers: "0",
                keyCode: 29
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .passthrough)
    }

    @Test
    func missingShortcutNumber_passthroughsDigit() {
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

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: [
                SelectablePopoverKeyboardItem(id: "first", shortcutNumber: nil, supportsAuxiliaryAction: true)
            ],
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .passthrough)
    }

    @Test
    func modifiedReturn_passthroughs() {
        guard let event = makeKeyEvent(modifierFlags: .command, keyCode: 36) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .passthrough)
    }

    @Test
    func modifiedShortcutNumber_passthroughs() {
        guard
            let event = makeKeyEvent(
                modifierFlags: .command,
                characters: "1",
                charactersIgnoringModifiers: "1",
                keyCode: 18
            )
        else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .passthrough)
    }

    @Test
    func modifiedArrow_passthroughs() {
        guard let event = makeKeyEvent(modifierFlags: .shift, keyCode: 125) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .passthrough)
    }

    @Test
    func auxiliaryKey_returnsAuxiliaryActionForCurrentItem() {
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

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "second",
            auxiliaryKey: "b",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .auxiliary("second"))
    }

    @Test
    func auxiliaryKey_consumesWhenCurrentItemDoesNotSupportAuxiliaryAction() {
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

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "third",
            auxiliaryKey: "b",
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .consume)
    }

    @Test
    func nilAuxiliaryKey_passthroughsAuxiliaryCharacter() {
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

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: items,
            selectedItemId: "first",
            auxiliaryKey: nil,
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .passthrough)
    }

    @Test
    func emptyItems_consumeSelectionKeys() {
        guard let event = makeKeyEvent(keyCode: 36) else {
            Issue.record("Expected synthetic key event")
            return
        }

        let action = SelectablePopoverKeyboardRouter.action(
            for: event,
            items: [],
            selectedItemId: Optional<String>.none,
            matchesAdditionalDismissShortcut: { _ in false }
        )

        #expect(action == .consume)
        #expect(
            SelectablePopoverKeyboardRouter.defaultSelection(
                items: [SelectablePopoverKeyboardItem<String>](),
                preferredItemId: nil
            ) == nil
        )
    }

    @Test
    func nilSelection_defaultsToFirstItem() {
        #expect(
            SelectablePopoverKeyboardRouter.currentSelection(
                items: items,
                selectedItemId: nil
            ) == "first"
        )
        #expect(
            SelectablePopoverKeyboardRouter.movedSelection(
                delta: 1,
                items: items,
                selectedItemId: nil
            ) == "second"
        )
    }
}
