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
    var onRenderingTaskStarted: @MainActor (Task<Void, Never>) -> Void = { _ in }
    var onConsumerStarted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onConsumerReadCompleted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onApplication: PaneContextPopoverApplicationObserver?
    var onMessageApplication: (@MainActor @Sendable (PaneContextPopoverMessageApplicationEvent) -> Void)?
    var onPresentationEvent: PaneContextPopoverPresentationObserver?
    var onScrollEvent: PaneContextPopoverScrollObserver = { _ in }
    var onNoteApplication: PaneContextNoteApplicationObserver?
    let onActionCompleted: @MainActor () -> Void
    let onActionTaskStarted: @MainActor (Task<Void, Never>) -> Void
    private var controls: PaneContextPopoverControls { PaneContextPopoverControlProjection.controls() }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            switch request {
            case .none: EmptyView()
            case .providerPrompt(let source, let sourceLabel, let summary):
                if let summary { Text(summary).textSelection(.enabled) }
                if let sourceLabel { Text("Drawer · \(sourceLabel)").font(.caption).foregroundStyle(.secondary) }
                Text("Answer in the agent's terminal").foregroundStyle(.secondary)
                PaneContextActionButton(controls.goToPane, role: .utility(octiconLoader)) {
                    actions.goToPane(source.uuid)
                }
            case .ask(let row):
                HStack(alignment: .top, spacing: AppStyles.General.Spacing.standard) {
                    PaneContextDatedText(
                        body: row.body, explanation: row.why, age: row.age,
                        identifier: "pane-context.message-text." + row.key.controlScope
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if row.availability == .askForm {
                        PaneContextActionButton(
                            controls.dismiss, role: .rowDismiss(octiconLoader), scope: row.key.controlScope
                        ) {
                            actions.dismiss(row.id, row.sourcePaneId)
                        }
                        .fixedSize()
                    }
                }
                if let source = row.sourceLabel {
                    Text("Drawer · \(source)").font(.caption).foregroundStyle(.secondary)
                }
                if row.availability == .askForm, case .ask(_, let form, _, _) = row.shape {
                    switch PaneContextPopoverLocation.card.presentation(for: .answer(form)) {
                    case .inline:
                        AskAnswerForm(
                            form: form, submitControl: controls.submit, scope: row.key.controlScope,
                            choicePrompt: controls.chooseOption, requiredField: controls.requiredField
                        ) {
                            actions.answer(row.id, row.sourcePaneId, $0)
                        }
                        .id(row.key)
                    case .inMessages:
                        PaneContextPreparedPopoverHost(
                            paneId: owner,
                            presentation: .messagesAction(
                                PaneContextPopoverControlProjection.control(
                                    .answerPaneMessageInMessages, identifier: "pane-context.answer-in-messages"),
                                focusedMessage: .init(
                                    paneId: .init(existingUUID: row.sourcePaneId),
                                    messageId: .init(existingUUID: row.id))),
                            location: .pane, bindings: readers.popoverBindings, octiconLoader: octiconLoader,
                            onGoToPane: actions.goToPane,
                            onRenderingTaskStarted: onRenderingTaskStarted, onConsumerStarted: onConsumerStarted,
                            onConsumerReadCompleted: onConsumerReadCompleted, onApplication: onApplication,
                            onMessageApplication: onMessageApplication,
                            onPresentationEvent: onPresentationEvent, onScrollEvent: onScrollEvent,
                            onNoteApplication: onNoteApplication,
                            onActionCompleted: onActionCompleted, onActionTaskStarted: onActionTaskStarted)
                    case .notApplicable: EmptyView()
                    }
                }
            }
        }
        .background {
            AccessibilityLabelBridge(identifier: "paneManagement.card.request", label: "", role: .group)
        }
    }
}
