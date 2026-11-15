import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSharedComponents

struct PaneContextPopoverModelTests {
    @Test
    func formsPreserveChoiceMultiplicityAndConstraints() {
        let choices = [
            AskChoiceModel(
                id: "allow", label: "Allow",
                control: .init(
                    identifier: "pane-context.choice.allow", label: "Allow", icon: .system("checkmark.circle"),
                    tooltip: .init(text: "Select Allow", shortcutDisplayText: nil))),
            AskChoiceModel(
                id: "deny", label: "Deny",
                control: .init(
                    identifier: "pane-context.choice.deny", label: "Deny", icon: .system("checkmark.circle"),
                    tooltip: .init(text: "Select Deny", shortcutDisplayText: nil))),
        ]
        #expect(
            AskFormModel.choice(options: choices, presentation: .radio)
                != .choice(options: choices, presentation: .checkboxes))
        let property = ElicitationPropertyModel(
            name: "count", title: "Count", description: "How many?", required: true,
            kind: .integer(minimum: 1, maximum: 5))
        #expect(AskFormModel.elicitation([property]) == .elicitation([property]))
        #expect(property.required)
    }

    @Test
    func answeredShapeRetainsTheAnswerAndReceipt() {
        let confirmedAt = Date(timeIntervalSince1970: 10)
        let state = AskStateModel.answered(
            by: .localUser, value: .choices(["allow"]), receipt: .confirmed(at: confirmedAt))
        #expect(state != .answered(by: .localUser, value: .choices(["allow"]), receipt: .notYetConfirmed))
        #expect(state != .expired)
    }

}
