import Foundation

package struct SelectablePopoverKeyboardItem<ItemID: Hashable>: Equatable, Identifiable {
    package let id: ItemID
    package let shortcutNumber: Int?
    package let supportsAuxiliaryAction: Bool

    package init(
        id: ItemID,
        shortcutNumber: Int? = nil,
        supportsAuxiliaryAction: Bool = false
    ) {
        self.id = id
        self.shortcutNumber = shortcutNumber
        self.supportsAuxiliaryAction = supportsAuxiliaryAction
    }
}

extension SelectablePopoverKeyboardItem: Sendable where ItemID: Sendable {}
