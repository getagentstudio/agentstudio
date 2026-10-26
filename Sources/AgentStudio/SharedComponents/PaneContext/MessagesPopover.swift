import AgentStudioInfrastructure
import Foundation
import SwiftUI

package struct MessagesPopoverActions {
    package let answer: @MainActor (UUID, UUID, AskFormDraft) -> Void
    package let dismiss: @MainActor (UUID, UUID) -> Void
    package let dismissAllNotices: @MainActor () -> Void
    package let runAction: @MainActor (UUID, UUID, MessageActionModel) -> Void
    package let goToPane: @MainActor (UUID) -> Void
    package let moreMessages: @MainActor (MessagePageCursorModel) -> Void
    package let moreSources: @MainActor (UUID) -> Void
    package init(
        answer: @escaping @MainActor (UUID, UUID, AskFormDraft) -> Void,
        dismiss: @escaping @MainActor (UUID, UUID) -> Void,
        dismissAllNotices: @escaping @MainActor () -> Void,
        runAction: @escaping @MainActor (UUID, UUID, MessageActionModel) -> Void,
        goToPane: @escaping @MainActor (UUID) -> Void,
        moreMessages: @escaping @MainActor (MessagePageCursorModel) -> Void,
        moreSources: @escaping @MainActor (UUID) -> Void
    ) {
        self.answer = answer
        self.dismiss = dismiss
        self.dismissAllNotices = dismissAllNotices
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
    private let octiconLoader: OcticonLoader
    private let location: PaneContextPopoverLocation
    private let feedback: String?
    private let actions: MessagesPopoverActions

    package init(
        paneId: UUID, model: MessagesPopoverModel, controls: PaneContextPopoverControls, octiconLoader: OcticonLoader,
        location: PaneContextPopoverLocation, feedback: String? = nil, actions: MessagesPopoverActions
    ) {
        self.paneId = paneId
        self.model = model
        self.controls = controls
        self.octiconLoader = octiconLoader
        self.location = location
        self.feedback = feedback
        self.actions = actions
    }

    package var body: some View {
        PaneContextPopoverPanel {
            messagesHeader
            if let feedback { PaneContextPopoverNote(feedback) }
            ForEach(model.groups, id: \.kind) { group in
                VStack(alignment: .leading, spacing: AppStyles.Components.PopoverPanel.sectionSpacing) {
                    HStack(spacing: AppStyles.General.Spacing.standard) {
                        PopoverPanelSectionHeader(group.kind.title)
                        if case .kindChip(let model, let control) = group.header {
                            PaneMessageKindChip.label(model: model, control: control, octiconLoader: octiconLoader)
                                .background {
                                    AccessibilityLabelBridge(
                                        identifier: "pane-context.group-chip." + group.kind.rawValue,
                                        label: String(model.count), role: .staticText)
                                }
                        }
                    }
                    .background {
                        AccessibilityLabelBridge(
                            identifier: "pane-context.group." + group.kind.rawValue,
                            label: group.kind.title, role: .staticText)
                    }
                    ForEach(group.items) { item in
                        switch item {
                        case .message(let row):
                            MessagePopoverRow(
                                row: row, controls: controls, octiconLoader: octiconLoader,
                                location: location, actions: actions
                            )
                            .id(row.key)
                        case .providerPrompt(let prompt):
                            ProviderPromptRow(prompt: prompt, octiconLoader: octiconLoader)
                        }
                    }
                    if group.omittedPromptCount > 0 {
                        Text("+\(group.omittedPromptCount) more not shown").font(.caption).foregroundStyle(.secondary)
                            .background {
                                AccessibilityLabelBridge(
                                    identifier: "pane-context.omitted-prompts",
                                    label: "+\(group.omittedPromptCount) more not shown", role: .staticText)
                            }
                    }
                }
                .id(group.kind)
            }
            ForEach(model.pages.indices, id: \.self) { index in
                PaneContextActionButton(controls.moreMessages, scope: model.pages[index].sourcePaneId.uuidString) {
                    actions.moreMessages(model.pages[index])
                }
            }
            if let after = model.nextSourcesAfter {
                PaneContextActionButton(controls.moreSources) { actions.moreSources(after) }
            }
        } footer: {
            HStack {
                if model.hasNotices {
                    PaneContextActionButton(controls.dismissAllNotices, action: actions.dismissAllNotices)
                }
                Spacer()
                PaneContextActionButton(controls.goToPane) { actions.goToPane(paneId) }
            }
            .background {
                AccessibilityLabelBridge(identifier: "pane-context.messages-footer", label: "", role: .group)
            }
        }
    }

    private var messagesHeader: some View {
        HStack(spacing: AppStyles.General.Spacing.loose) {
            Text(controls.messages.label)
                .font(.system(size: AppStyles.General.Typography.textBase, weight: .semibold))
                .foregroundStyle(.primary)
            if model.unreadCount > 0 {
                Text(String(model.unreadCount))
                    .font(.system(size: AppStyles.General.Typography.textXs))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .background {
            AccessibilityLabelBridge(
                identifier: "pane-context.messages-header",
                label: controls.messages.label + (model.unreadCount > 0 ? " \(model.unreadCount)" : ""),
                role: .staticText)
        }
    }
}

private struct MessagePopoverRow: View {
    let row: MessageRowModel
    let controls: PaneContextPopoverControls
    let octiconLoader: OcticonLoader
    let location: PaneContextPopoverLocation
    let actions: MessagesPopoverActions

    var body: some View {
        HStack(alignment: .top, spacing: AppStyles.General.Spacing.standard) {
            PaneContextRowGlyph(icon: row.kindIcon, style: glyphStyle, octiconLoader: octiconLoader)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                HStack(alignment: .top, spacing: AppStyles.General.Spacing.standard) {
                    PaneContextDatedText(
                        body: row.body, explanation: row.why, age: row.age,
                        identifier: "pane-context.message-text." + row.key.controlScope
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if showsDismissInRowHead {
                        dismiss.fixedSize()
                    }
                }
                if let source = row.sourceLabel {
                    PaneContextSourceLabel(title: source, scope: row.key.controlScope)
                }
                if let settledLabel = row.settledLabel {
                    Text(settledLabel).foregroundStyle(.secondary).background {
                        AccessibilityLabelBridge(
                            identifier: "pane-context.settled." + row.key.controlScope,
                            label: settledLabel, role: .staticText)
                    }
                }
                rowActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(row.isDimmed ? AppStyles.General.Foreground.dim : 1)
    }

    @ViewBuilder private var rowActions: some View {
        switch row.availability {
        case .none: EmptyView()
        case .noticeActions:
            if location.presentation(for: .noticeActions) == .inline {
                ForEach(row.actions.indices, id: \.self) { index in
                    let action = row.actions[index]
                    PaneContextActionButton(control(for: action), scope: row.key.controlScope + ".\(index)") {
                        actions.runAction(row.id, row.sourcePaneId, action)
                    }
                }
            }
        case .askForm:
            if case .ask(_, let form, _, _) = row.shape {
                if location.presentation(for: .answer(form)) == .inline {
                    AskAnswerForm(form: form, submitControl: controls.submit, scope: row.key.controlScope) {
                        actions.answer(row.id, row.sourcePaneId, $0)
                    }
                }
            }
        }
    }

    private var showsDismissInRowHead: Bool {
        switch row.availability {
        case .none: false
        case .noticeActions: location.presentation(for: .noticeActions) == .inline
        case .askForm: location.presentation(for: .dismissAsk) == .inline
        }
    }

    private var dismiss: some View {
        PaneContextActionButton(controls.dismiss, scope: row.key.controlScope) {
            actions.dismiss(row.id, row.sourcePaneId)
        }
    }
    private var glyphStyle: SidebarChip.Style {
        switch row.kind {
        case .notice(let kind): kind.style
        case .openAsk: .warning
        case .settledAsk: .neutral
        }
    }
    private func control(for action: MessageActionModel) -> PaneContextControlModel {
        switch action {
        case .openFile: controls.openFile
        case .openPullRequest: controls.openPullRequest
        case .goToPane: controls.goToPane
        }
    }
}

private struct ProviderPromptRow: View {
    let prompt: ProviderPromptRowModel
    let octiconLoader: OcticonLoader
    var body: some View {
        HStack(alignment: .top, spacing: AppStyles.General.Spacing.standard) {
            PaneContextRowGlyph(icon: prompt.kindIcon, style: .warning, octiconLoader: octiconLoader)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                PaneContextDatedText(
                    body: prompt.summary.map { prompt.reasonText + ": " + $0 } ?? prompt.reasonText,
                    age: prompt.age, identifier: "pane-context.provider-prompt.\(prompt.sourcePaneId).\(prompt.ordinal)"
                )
                if let source = prompt.sourceLabel {
                    PaneContextSourceLabel(title: source, scope: "\(prompt.sourcePaneId).\(prompt.ordinal)")
                }
                Text("Answer in the agent's terminal").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PaneContextSourceLabel: View {
    let title: String
    let scope: String
    var body: some View {
        Text("Drawer · \(title)").font(.caption).foregroundStyle(.secondary).background {
            AccessibilityLabelBridge(
                identifier: "pane-context.message-source." + scope,
                label: "Drawer · \(title)", role: .staticText)
        }
    }
}

package struct MessageSenderLabel: View {
    private let sender: MessageSenderModel
    package init(sender: MessageSenderModel) { self.sender = sender }
    package var body: some View {
        switch sender {
        case .pane: Text("This pane").font(.caption).textSelection(.enabled)
        case .session(let provider, let sessionRef, _):
            Text("\(provider) · \(sessionRef)").font(.caption).textSelection(.enabled)
        }
    }
}
