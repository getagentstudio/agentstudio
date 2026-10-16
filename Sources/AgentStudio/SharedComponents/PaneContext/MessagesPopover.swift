import AgentStudioInfrastructure
import Foundation
import SwiftUI

package struct MessagesPopoverActions {
    package let answer: @MainActor (UUID, UUID, AskFormDraft) -> Void
    package let dismiss: @MainActor (UUID, UUID) -> Void
    package let dismissAllNotices: @MainActor () -> Void
    package let markRead: @MainActor (UUID, UUID) -> Void
    package let runAction: @MainActor (UUID, UUID, MessageActionModel) -> Void
    package let goToPane: @MainActor (UUID) -> Void
    package let moreMessages: @MainActor (MessagePageCursorModel) -> Void
    package let moreSources: @MainActor (UUID) -> Void
    package init(
        answer: @escaping @MainActor (UUID, UUID, AskFormDraft) -> Void,
        dismiss: @escaping @MainActor (UUID, UUID) -> Void,
        dismissAllNotices: @escaping @MainActor () -> Void,
        markRead: @escaping @MainActor (UUID, UUID) -> Void,
        runAction: @escaping @MainActor (UUID, UUID, MessageActionModel) -> Void,
        goToPane: @escaping @MainActor (UUID) -> Void,
        moreMessages: @escaping @MainActor (MessagePageCursorModel) -> Void,
        moreSources: @escaping @MainActor (UUID) -> Void
    ) {
        self.answer = answer
        self.dismiss = dismiss
        self.dismissAllNotices = dismissAllNotices
        self.markRead = markRead
        self.runAction = runAction
        self.goToPane = goToPane
        self.moreMessages = moreMessages
        self.moreSources = moreSources
    }
}

package struct MessagesPopover: View {
    private let paneId: UUID
    private let model: MessagesPopoverModel
    private let controls: PaneContextPopoverControls
    private let location: PaneContextPopoverLocation
    private let providerPrompts: ProviderPromptsModel?
    private let feedback: String?
    private let informationalToggle: PaneContextControlModel?
    @Binding private var includesInformational: Bool
    private let actions: MessagesPopoverActions
    @State private var attentionType: MessageAttentionTypeModel?
    package init(
        paneId: UUID, model: MessagesPopoverModel, controls: PaneContextPopoverControls,
        location: PaneContextPopoverLocation, providerPrompts: ProviderPromptsModel? = nil,
        feedback: String? = nil, informationalToggle: PaneContextControlModel? = nil,
        includesInformational: Binding<Bool> = .constant(false), actions: MessagesPopoverActions
    ) {
        self.paneId = paneId
        self.model = model
        self.controls = controls
        self.location = location
        self.providerPrompts = providerPrompts
        self.feedback = feedback
        self.informationalToggle = informationalToggle
        _includesInformational = includesInformational
        self.actions = actions
    }
    private var groups: [MessageSourceGroupModel] { model.partitions.groups(for: attentionType) }
    package var body: some View {
        PopoverPanel {
            PopoverPanelSectionHeader(controls.messages.label)
            HStack(spacing: AppStyles.General.Spacing.tight) {
                ForEach(controls.filters.indices, id: \.self) { index in
                    let filter = controls.filters[index]
                    PaneContextActionButton(filter.control, isSelected: attentionType == filter.attentionType) {
                        attentionType = filter.attentionType
                    }
                }
            }
            if let informationalToggle {
                PaneContextActionButton(informationalToggle, isSelected: includesInformational) {
                    includesInformational.toggle()
                }
            }
            if let feedback { Text(feedback).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: AppStyles.Components.PopoverPanel.sectionSpacing) {
                    ForEach(groups.indices, id: \.self) { index in
                        let group = groups[index]
                        PopoverPanelSectionHeader(group.sourceLabel)
                        ForEach(group.rows, id: \.id) { row in
                            MessagePopoverRow(row: row, controls: controls, location: location, actions: actions)
                        }
                    }
                    if let providerPrompts { ProviderPromptRows(model: providerPrompts) }
                }
            }
            ForEach(model.pages.indices, id: \.self) { index in
                PaneContextActionButton(controls.moreMessages, scope: model.pages[index].sourcePaneId.uuidString) {
                    actions.moreMessages(model.pages[index])
                }
            }
            if let after = model.nextSourcesAfter {
                PaneContextActionButton(controls.moreSources) { actions.moreSources(after) }
            }
            HStack {
                PaneContextActionButton(controls.dismissAllNotices, action: actions.dismissAllNotices)
                Spacer()
                PaneContextActionButton(controls.goToPane) { actions.goToPane(paneId) }
            }
        }
    }
}

private struct MessagePopoverRow: View {
    let row: MessageRowModel
    let controls: PaneContextPopoverControls
    let location: PaneContextPopoverLocation
    let actions: MessagesPopoverActions
    @State private var isNoticeExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            MessageSenderLabel(sender: row.sender)
            Text(row.sentAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            switch row.shape {
            case .notice(let state):
                DisclosureGroup(isExpanded: $isNoticeExpanded) {
                    messageContent
                    Text(Self.noticeText(state)).font(.caption).foregroundStyle(.secondary)
                    if state == .unread {
                        PaneContextActionButton(controls.markRead, scope: row.id.uuidString) {
                            actions.markRead(row.id, row.sourcePaneId)
                        }
                    }
                    if state == .unread || state == .read {
                        PaneContextActionButton(controls.dismiss, scope: row.id.uuidString) {
                            actions.dismiss(row.id, row.sourcePaneId)
                        }
                    }
                } label: {
                    Text(row.body).lineLimit(2).accessibilityHidden(true)
                }
                .background {
                    AccessibilityPressBridge(
                        identifier: controls.messageDetails.identifier(in: row.id.uuidString),
                        label: controls.messageDetails.label, help: controls.messageDetails.tooltip.text,
                        action: { isNoticeExpanded.toggle() })
                }
                .onChange(of: isNoticeExpanded) { _, expanded in
                    if expanded, state == .unread { actions.markRead(row.id, row.sourcePaneId) }
                }
            case .ask(let reason, let form, let waiting, let state):
                Text(Self.reasonText(reason)).font(.headline)
                messageContent
                if case .blocking(let deadline) = waiting {
                    HStack {
                        Text("Waiting until")
                        Text(deadline, format: .dateTime)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if state == .open, location == .pane {
                    AskAnswerForm(form: form, submitControl: controls.answer, scope: row.id.uuidString) {
                        actions.answer(row.id, row.sourcePaneId, $0)
                    }
                    PaneContextActionButton(controls.dismiss, scope: row.id.uuidString) {
                        actions.dismiss(row.id, row.sourcePaneId)
                    }
                } else if state == .open {
                    Text("Answer in the pane").foregroundStyle(.secondary)
                } else {
                    Text(Self.askText(state)).foregroundStyle(.secondary)
                }
            }
            Divider()
        }
    }
    private var messageContent: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
            Text(row.body).textSelection(.enabled)
            if let why = row.why { Text(why).foregroundStyle(.secondary) }
            if location == .pane {
                ForEach(row.actions.indices, id: \.self) { index in
                    let action = row.actions[index]
                    PaneContextActionButton(control(for: action), scope: row.id.uuidString) {
                        actions.runAction(row.id, row.sourcePaneId, action)
                    }
                }
            }
        }
    }
    private func control(for action: MessageActionModel) -> PaneContextControlModel {
        switch action {
        case .openFile: controls.openFile
        case .openPullRequest: controls.openPullRequest
        case .goToPane: controls.goToPane
        }
    }
    private static func noticeText(_ state: NoticeStateModel) -> String {
        switch state {
        case .unread: "Unread"
        case .read: "Read"
        case .dismissed: "Dismissed"
        case .withdrawn: "Withdrawn"
        }
    }
    private static func reasonText(_ reason: AskReasonModel) -> String {
        switch reason {
        case .approval: "Approval"
        case .question: "Question"
        case .blocked: "Blocked on you"
        }
    }
    private static func askText(_ state: AskStateModel) -> String {
        switch state {
        case .open: "Awaiting your answer"
        case .answered(_, _, .notYetConfirmed): "Answered by you · not yet confirmed"
        case .answered(_, _, .confirmed): "Answered by you · confirmed"
        case .answered(_, _, .unconfirmed): "Answered by you · unconfirmed"
        case .handedBack: "Handed back to the provider"
        case .dismissed: "Dismissed"
        case .expired: "Expired"
        case .withdrawn: "Withdrawn"
        case .stale: "Stale"
        }
    }
}

package struct MessageSenderLabel: View {
    private let sender: MessageSenderModel
    package init(sender: MessageSenderModel) { self.sender = sender }
    package var body: some View {
        switch sender {
        case .pane: Text("This pane").font(.caption)
        case .session(let provider, let sessionRef, _): Text("\(provider) · \(sessionRef)").font(.caption)
        }
    }
}

package struct ProviderPromptRows: View {
    private let model: ProviderPromptsModel
    package init(model: ProviderPromptsModel) { self.model = model }
    package var body: some View {
        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
            ForEach(model.prompts.indices, id: \.self) { index in
                let prompt = model.prompts[index]
                Text(prompt.summary ?? "Provider prompt")
                Text(prompt.observedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                Text("Answer in the provider terminal").font(.caption).foregroundStyle(.secondary)
            }
            if model.omittedPromptCount > 0 {
                Text("+\(model.omittedPromptCount) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
