import SwiftUI

/// Opening-owned UI values; filtering may unmount a row without retiring these bindings.
@MainActor
package struct MessagesPopoverBindings {
    package let selectedFilter: Binding<Int>
    package let draft: @MainActor (MessageRowModel.Key) -> Binding<AskFormDraft>
    package let details: Binding<PaneContextMessageTextValue?>

    package init(
        selectedFilter: Binding<Int>,
        draft: @escaping @MainActor (MessageRowModel.Key) -> Binding<AskFormDraft>,
        details: Binding<PaneContextMessageTextValue?>
    ) {
        self.selectedFilter = selectedFilter
        self.draft = draft
        self.details = details
    }
}
