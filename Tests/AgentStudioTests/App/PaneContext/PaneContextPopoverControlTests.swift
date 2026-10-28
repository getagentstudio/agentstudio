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
        #expect(controls.goToPane.label == LocalActionSpec.goToMessagePane.actionSpec.label)
        #expect(controls.messages.icon == .system(SystemSymbol.bell.rawValue))
        #expect(
            controls.submit.tooltip
                == LocalActionSpec.submitPaneMessageAnswer.actionSpec.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: "Submit")))
    }

}
