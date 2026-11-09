import AgentStudioCore
import AgentStudioInfrastructure
import SwiftUI

/// Presents the tab picker as a popover attached to the view it modifies: the
/// picker control, or the top of the pane when the navigation bar is hidden.
/// A click outside closes it; the toggle gate, when the anchor is a control,
/// keeps that same click from opening it again.
struct WebviewTabPickerPopover: ViewModifier {
    @Bindable var controller: WebviewPaneController
    let toggleGate: PopoverToggleGate?

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { controller.isTabPickerPresented },
                set: { isPresented in
                    if !isPresented && controller.isTabPickerPresented {
                        controller.isTabPickerPresented = false
                        toggleGate?.recordSystemDismissal()
                    } else {
                        controller.isTabPickerPresented = isPresented
                    }
                }
            ),
            arrowEdge: .bottom
        ) {
            WebviewTabPickerView(controller: controller)
        }
    }
}
