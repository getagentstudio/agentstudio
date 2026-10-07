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
            AskFormModel.choice(options: choices, allowsMultiple: false)
                != .choice(options: choices, allowsMultiple: true))
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

    @Test
    func partitionsKeepDrawerAttributionAndPagingIndependent() {
        let paneId = UUIDv7.generate()
        let cursor = MessagePageCursorModel(sourcePaneId: paneId, rank: 0, position: 12, openAsks: 2, unreadNotices: 3)
        let group = MessageSourceGroupModel(sourcePaneId: paneId, sourceLabel: "Drawer", rows: [])
        let partition = MessagePartitionModel(
            all: [group], needsApproval: [group], needsReply: [], attention: [], informational: [])
        let model = MessagesPopoverModel(
            partitions: partition, pages: [cursor], remainingLiveSources: 2, nextSourcesAfter: paneId)
        #expect(model.partitions.groups(for: .needsApproval) == [group])
        #expect(model.partitions.groups(for: .informational).isEmpty)
        #expect(model.pages.first?.position == 12)
        #expect(model.nextSourcesAfter == paneId)
    }

    @Test
    func providerPromptsRemainReadOnlyAndKeepOmittedCount() {
        let model = ProviderPromptsModel(prompts: [], omittedPromptCount: 4)
        #expect(model.omittedPromptCount == 4)
        #expect(model.prompts.isEmpty)
    }
}
