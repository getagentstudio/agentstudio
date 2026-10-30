import AgentStudioInfrastructure
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

struct PopoverPanelTests {
    @Test
    func inactiveOptionsUseHoverAndPressedFills() {
        let idle = PopoverOptionVisualStyle(
            isSelected: false,
            isHighlighted: false,
            isPressed: false
        )
        let hovered = PopoverOptionVisualStyle(
            isSelected: false,
            isHighlighted: true,
            isPressed: false
        )
        let pressed = PopoverOptionVisualStyle(
            isSelected: false,
            isHighlighted: true,
            isPressed: true
        )

        #expect(idle.backgroundColor == Color.clear)
        #expect(hovered.backgroundColor == Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        #expect(pressed.backgroundColor == Color(nsColor: .selectedContentBackgroundColor))
    }

    @Test
    func selectedOptionsKeepActiveFillUntilPressed() {
        let active = PopoverOptionVisualStyle(
            isSelected: true,
            isHighlighted: false,
            isPressed: false
        )
        let activeHovered = PopoverOptionVisualStyle(
            isSelected: true,
            isHighlighted: true,
            isPressed: false
        )
        let activePressed = PopoverOptionVisualStyle(
            isSelected: true,
            isHighlighted: true,
            isPressed: true
        )

        #expect(active.backgroundColor == Color(nsColor: .selectedContentBackgroundColor))
        #expect(activeHovered.backgroundColor == active.backgroundColor, "Hover must preserve a selected surface")
        #expect(activePressed.backgroundColor == Color(nsColor: .selectedContentBackgroundColor))
        #expect(active.foregroundIsPrimary)
    }

}
