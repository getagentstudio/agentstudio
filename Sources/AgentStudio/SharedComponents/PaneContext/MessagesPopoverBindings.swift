import SwiftUI

/// Opening-owned UI values; filtering may unmount a row without retiring these bindings.
@MainActor
package struct MessagesPopoverBindings {
    package let selectedFilter: Binding<Int>
    package let draft: @MainActor (MessageRowModel.Key) -> Binding<AskFormDraft>
    package let expanded: @MainActor (MessageRowModel.Key) -> Binding<Bool>

    package init(
        selectedFilter: Binding<Int>,
        draft: @escaping @MainActor (MessageRowModel.Key) -> Binding<AskFormDraft>,
        expanded: @escaping @MainActor (MessageRowModel.Key) -> Binding<Bool>
    ) {
        self.selectedFilter = selectedFilter
        self.draft = draft
        self.expanded = expanded
    }
}
