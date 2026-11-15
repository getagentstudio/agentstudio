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

        #expect(idle.backgroundColor == Color.white.opacity(0.04))
        #expect(hovered.backgroundColor == Color.white.opacity(0.08))
        #expect(pressed.backgroundColor == Color.white.opacity(0.10))
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

        #expect(active.backgroundColor == Color.white.opacity(0.12))
        #expect(activeHovered.backgroundColor == active.backgroundColor, "Hover must preserve a selected surface")
        #expect(activePressed.backgroundColor == Color.white.opacity(0.10))
        #expect(active.foregroundIsPrimary)
    }

}
