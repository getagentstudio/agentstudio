import AgentStudioInfrastructure
import AppKit

enum EditorChooserKeyboardAction: Equatable {
    case dismiss
    case select(EditorTargetId)
    case toggleBookmark(EditorTargetId)
    case highlight(EditorTargetId)
    case consume
    case passthrough
}

enum EditorChooserKeyboardRouter {
    static func action(
        for event: NSEvent,
        items: [EditorChoiceItem],
        selectedEditorId: EditorTargetId?,
        matchesAdditionalDismissShortcut: (NSEvent) -> Bool
    ) -> EditorChooserKeyboardAction {
        switch SelectablePopoverKeyboardRouter.action(
            for: event,
            items: keyboardItems(for: items),
            selectedItemId: selectedEditorId,
            auxiliaryTrigger: .character("b"),
            matchesAdditionalDismissShortcut: matchesAdditionalDismissShortcut
        ) {
        case .dismiss:
            return .dismiss
        case .select(let editorId):
            return .select(editorId)
        case .auxiliary(let editorId):
            return .toggleBookmark(editorId)
        case .highlight(let editorId):
            return .highlight(editorId)
        case .consume:
            return .consume
        case .passthrough:
            return .passthrough
        }
    }

    static func defaultSelection(
        items: [EditorChoiceItem],
        bookmarkedEditorId: EditorTargetId?
    ) -> EditorTargetId? {
        SelectablePopoverKeyboardRouter.defaultSelection(
            items: keyboardItems(for: items),
            preferredItemId: bookmarkedEditorId
        )
    }

    private static func keyboardItems(
        for items: [EditorChoiceItem]
    ) -> [SelectablePopoverKeyboardItem<EditorTargetId>] {
        items.map {
            SelectablePopoverKeyboardItem(
                id: $0.id,
                shortcutNumber: $0.shortcutNumber,
                supportsAuxiliaryAction: true
            )
        }
    }
}
