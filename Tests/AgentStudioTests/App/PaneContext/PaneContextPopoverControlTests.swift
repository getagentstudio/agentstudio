import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Testing

@testable import AgentStudio

struct PaneContextPopoverControlTests {
    @Test
    func controlsUseTheLocalActionSpecs() {
        let controls = PaneContextPopoverControlProjection.controls()
        #expect(controls.submit.label == "Submit")
        #expect(controls.goToPane.label == "To pane")
        #expect(controls.goToPane.accessibilityLabel == LocalActionSpec.goToMessagePane.actionSpec.label)
        #expect(controls.dismissAllNotices.label == "Dismiss all")
        #expect(controls.dismissAllNotices.accessibilityLabel == LocalActionSpec.dismissAllPaneNotices.actionSpec.label)
        #expect(controls.messages.icon == .system(SystemSymbol.bell.rawValue))
        #expect(
            controls.submit.tooltip
                == LocalActionSpec.submitPaneMessageAnswer.actionSpec.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: "Submit")))
    }

}
