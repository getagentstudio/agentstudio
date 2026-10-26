import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

struct PaneContextCardRequestBlock: View {
    let request: CardModel.Request
    let actions: MessagesPopoverActions
    let readers: PaneContextUIReaders
    let owner: PaneId
    let octiconLoader: OcticonLoader
    let onReadCompleted: @MainActor (PaneContextRefreshKey, PaneContextPopoverController?) -> Void
    let onActionCompleted: @MainActor () -> Void
    let onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void
    let onRelativeTimeEvent: @MainActor @Sendable (PaneRelativeTimeRefresh.Event) -> Void
    private var controls: PaneContextPopoverControls { PaneContextPopoverControlProjection.controls() }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            switch request {
            case .none: EmptyView()
            case .providerPrompt(let source, let sourceLabel, let summary):
                if let summary { Text(summary).textSelection(.enabled) }
                if let sourceLabel { Text("Drawer · \(sourceLabel)").font(.caption).foregroundStyle(.secondary) }
                Text("Answer in the agent's terminal").foregroundStyle(.secondary)
                PaneContextActionButton(controls.goToPane) { actions.goToPane(source.uuid) }
            case .ask(let row):
                Text(row.body).textSelection(.enabled)
                if let why = row.why { Text(why).foregroundStyle(.secondary).textSelection(.enabled) }
                if let source = row.sourceLabel {
                    Text("Drawer · \(source)").font(.caption).foregroundStyle(.secondary)
                }
                if row.availability == .askForm, case .ask(_, let form, _, _) = row.shape {
                    switch PaneContextPopoverLocation.card.presentation(for: .answer(form)) {
                    case .inline:
                        AskAnswerForm(form: form, submitControl: controls.submit, scope: row.key.controlScope) {
                            actions.answer(row.id, row.sourcePaneId, $0)
                        }
                    case .inMessages:
                        PaneContextPopoverHost(
                            paneId: owner,
                            presentation: .messagesAction(
                                PaneContextPopoverControlProjection.control(
                                    .answerPaneMessageInMessages, identifier: "pane-context.answer-in-messages"),
                                focusedMessage: .init(
                                    paneId: .init(existingUUID: row.sourcePaneId),
                                    messageId: .init(existingUUID: row.id))),
                            location: .pane, readers: readers, octiconLoader: octiconLoader,
                            onGoToPane: actions.goToPane,
                            onReadCompleted: onReadCompleted, onActionCompleted: onActionCompleted,
                            onActionTaskStarted: onActionTaskStarted, clock: ContinuousClock(),
                            onRelativeTimeEvent: onRelativeTimeEvent)
                    case .notApplicable: EmptyView()
                    }
                    PaneContextActionButton(controls.dismiss, scope: row.key.controlScope) {
                        actions.dismiss(row.id, row.sourcePaneId)
                    }
                }
            }
        }
        .background {
            AccessibilityLabelBridge(identifier: "paneManagement.card.request", label: "", role: .group)
        }
    }
}
