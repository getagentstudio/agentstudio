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
            auxiliaryTrigger: .character("b"),
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
            auxiliaryTrigger: .character("b"),
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
            auxiliaryTrigger: nil,
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

    // MARK: - Keys as macOS delivers them, for a popover whose search field keeps focus

    /// macOS tags unmodified arrows with `.function`, and keypad-style arrows
    /// with `.numericPad`; without a focus-capturing view to fall back on, the
    /// router itself must treat them as plain arrows.
    @Test(arguments: [NSEvent.ModifierFlags.function, [.function, .numericPad]])
    func systemTaggedArrows_moveTheHighlight(flags: NSEvent.ModifierFlags) throws {
        let down = try #require(makeKeyEvent(modifierFlags: flags, keyCode: 125))
        let up = try #require(makeKeyEvent(modifierFlags: flags, keyCode: 126))

        let downAction = SelectablePopoverKeyboardRouter.action(
            for: down, items: items, selectedItemId: "first", matchesAdditionalDismissShortcut: { _ in false })
        let upAction = SelectablePopoverKeyboardRouter.action(
            for: up, items: items, selectedItemId: "second", matchesAdditionalDismissShortcut: { _ in false })

        #expect(downAction == .highlight("second"))
        #expect(upAction == .highlight("first"))
    }

    @Test
    func reallyModifiedSystemArrow_passthroughs() throws {
        let event = try #require(makeKeyEvent(modifierFlags: [.shift, .function, .numericPad], keyCode: 125))

        let action = SelectablePopoverKeyboardRouter.action(
            for: event, items: items, selectedItemId: "first", matchesAdditionalDismissShortcut: { _ in false })

        #expect(action == .passthrough)
    }

    /// Command-Delete closes the current row by key code, whatever characters
    /// the Delete key produces.
    @Test(arguments: ["\u{7f}", "\u{8}"])
    func commandDeleteChord_runsAuxiliaryActionForCurrentRow(characters: String) throws {
        let event = try #require(
            makeKeyEvent(
                modifierFlags: .command, characters: characters, charactersIgnoringModifiers: characters,
                keyCode: 51))

        let action = SelectablePopoverKeyboardRouter.action(
            for: event, items: items, selectedItemId: "second", auxiliaryTrigger: .commandDelete,
            matchesAdditionalDismissShortcut: { _ in false })

        #expect(action == .auxiliary("second"))
    }

    @Test
    func commandDeleteChord_consumesOnRowWithoutAuxiliaryAction() throws {
        let event = try #require(
            makeKeyEvent(
                modifierFlags: .command, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", keyCode: 51))

        let action = SelectablePopoverKeyboardRouter.action(
            for: event, items: items, selectedItemId: "third", auxiliaryTrigger: .commandDelete,
            matchesAdditionalDismissShortcut: { _ in false })

        #expect(action == .consume)
    }

    /// Plain Delete edits the search text, and Delete with other modifiers
    /// isn't the chord.
    @Test(arguments: [NSEvent.ModifierFlags(), [.command, .shift], .option])
    func deleteOutsideTheChord_passthroughs(flags: NSEvent.ModifierFlags) throws {
        let event = try #require(
            makeKeyEvent(modifierFlags: flags, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", keyCode: 51)
        )

        let action = SelectablePopoverKeyboardRouter.action(
            for: event, items: items, selectedItemId: "first", auxiliaryTrigger: .commandDelete,
            matchesAdditionalDismissShortcut: { _ in false })

        #expect(action == .passthrough)
    }

    @Test
    func typedLetter_passthroughsToSearchWithChordTrigger() throws {
        let event = try #require(makeKeyEvent(characters: "b", charactersIgnoringModifiers: "b", keyCode: 11))

        let action = SelectablePopoverKeyboardRouter.action(
            for: event, items: items, selectedItemId: "first", auxiliaryTrigger: .commandDelete,
            matchesAdditionalDismissShortcut: { _ in false })

        #expect(action == .passthrough)
    }
}
