import AgentStudioInfrastructure
import AppKit

/// What starts a popover's auxiliary action on the current row.
package enum SelectablePopoverAuxiliaryTrigger: Equatable {
    /// An unmodified character. Only for popovers with no text field, since
    /// the character never reaches one.
    case character(Character)
    /// A physical key with exactly these modifiers, matched by key code so it
    /// works whatever characters the key produces and never eats typed text.
    case chord(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)

    /// Command-Delete: the Delete key (key code 51) with Command.
    package static let commandDelete = Self.chord(keyCode: 51, modifiers: .command)
}

package enum SelectablePopoverKeyboardRouter {
    private enum KeyCode: UInt16 {
        case escape = 53
        case returnKey = 36
        case keypadEnter = 76
        case downArrow = 125
        case upArrow = 126
    }

    package static func action<ItemID: Hashable>(
        for event: NSEvent,
        items: [SelectablePopoverKeyboardItem<ItemID>],
        selectedItemId: ItemID?,
        auxiliaryTrigger: SelectablePopoverAuxiliaryTrigger? = nil,
        matchesAdditionalDismissShortcut: (NSEvent) -> Bool
    ) -> SelectablePopoverKeyboardAction<ItemID> {
        guard event.type == .keyDown else { return .passthrough }

        if event.keyCode == KeyCode.escape.rawValue || matchesAdditionalDismissShortcut(event) {
            return .dismiss
        }

        let modifiers = significantModifiers(of: event)
        if case .chord(let keyCode, let chordModifiers) = auxiliaryTrigger,
            event.keyCode == keyCode, modifiers == chordModifiers
        {
            return auxiliaryAction(items: items, selectedItemId: selectedItemId)
        }
        guard modifiers.isEmpty else { return .passthrough }

        switch event.keyCode {
        case KeyCode.returnKey.rawValue, KeyCode.keypadEnter.rawValue:
            guard let itemId = currentSelection(items: items, selectedItemId: selectedItemId) else {
                return .consume
            }
            return .select(itemId)
        case KeyCode.downArrow.rawValue:
            guard let itemId = movedSelection(delta: 1, items: items, selectedItemId: selectedItemId) else {
                return .consume
            }
            return .highlight(itemId)
        case KeyCode.upArrow.rawValue:
            guard let itemId = movedSelection(delta: -1, items: items, selectedItemId: selectedItemId) else {
                return .consume
            }
            return .highlight(itemId)
        default:
            break
        }

        if case .character(let auxiliaryKey) = auxiliaryTrigger,
            event.charactersIgnoringModifiers?.lowercased() == String(auxiliaryKey).lowercased()
        {
            return auxiliaryAction(items: items, selectedItemId: selectedItemId)
        }

        if let characters = event.charactersIgnoringModifiers,
            characters.count == 1,
            let shortcutNumber = Int(characters),
            (1...AppPolicies.SelectablePopover.maxNumberedShortcuts).contains(shortcutNumber)
        {
            guard let itemId = items.first(where: { $0.shortcutNumber == shortcutNumber })?.id else {
                return .passthrough
            }
            return .select(itemId)
        }

        return .passthrough
    }

    /// The modifiers that make a key a different key. macOS tags arrow keys
    /// with `.function` (and keypad arrows with `.numericPad`) even when
    /// nothing is held, so those flags don't count on arrows.
    private static func significantModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        var modifiers = event.modifierFlags.intersection([.command, .control, .option, .function, .shift])
        if event.keyCode == KeyCode.upArrow.rawValue || event.keyCode == KeyCode.downArrow.rawValue {
            modifiers.subtract([.function, .numericPad])
        }
        return modifiers
    }

    private static func auxiliaryAction<ItemID: Hashable>(
        items: [SelectablePopoverKeyboardItem<ItemID>],
        selectedItemId: ItemID?
    ) -> SelectablePopoverKeyboardAction<ItemID> {
        guard
            let itemId = currentSelection(items: items, selectedItemId: selectedItemId),
            items.first(where: { $0.id == itemId })?.supportsAuxiliaryAction == true
        else {
            return .consume
        }
        return .auxiliary(itemId)
    }

    package static func defaultSelection<ItemID: Hashable>(
        items: [SelectablePopoverKeyboardItem<ItemID>],
        preferredItemId: ItemID?
    ) -> ItemID? {
        if let preferredItemId, items.contains(where: { $0.id == preferredItemId }) {
            return preferredItemId
        }

        return items.first?.id
    }

    package static func currentSelection<ItemID: Hashable>(
        items: [SelectablePopoverKeyboardItem<ItemID>],
        selectedItemId: ItemID?
    ) -> ItemID? {
        if let selectedItemId, items.contains(where: { $0.id == selectedItemId }) {
            return selectedItemId
        }

        return items.first?.id
    }

    package static func movedSelection<ItemID: Hashable>(
        delta: Int,
        items: [SelectablePopoverKeyboardItem<ItemID>],
        selectedItemId: ItemID?
    ) -> ItemID? {
        guard !items.isEmpty else { return nil }

        let currentIndex = items.firstIndex { $0.id == selectedItemId } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
        return items[nextIndex].id
    }
}
