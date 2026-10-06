import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Testing

@testable import AgentStudio

struct PaneContextPopoverControlTests {
    @Test
    func controlsUseTheLocalActionSpecs() {
        let controls = PaneContextPopoverControlProjection.controls()
        #expect(controls.answer.label == LocalActionSpec.answerPaneMessage.actionSpec.label)
        #expect(controls.goToPane.label == LocalActionSpec.goToMessagePane.actionSpec.label)
        #expect(controls.messages.icon == .system(SystemSymbol.bell.rawValue))
        #expect(
            controls.answer.tooltip
                == LocalActionSpec.answerPaneMessage.actionSpec.controlTooltipRenderValue(
                    provenance: .localAction(rawValue: LocalActionSpec.answerPaneMessage.actionSpec.label)))
        #expect(
            controls.filters.map(\.attentionType) == [nil, .needsApproval, .needsReply, .attention, .informational])
    }

}
