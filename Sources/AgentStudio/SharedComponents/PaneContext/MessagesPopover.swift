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
    private let width: CGFloat
    private let paneId: UUID
    private let model: MessagesPopoverModel
    private let controls: PaneContextPopoverControls
    private let octiconLoader: OcticonLoader
    private let location: PaneContextPopoverLocation
    private let feedback: String?
    private let actions: MessagesPopoverActions

    package init(
        paneId: UUID, model: MessagesPopoverModel, controls: PaneContextPopoverControls, octiconLoader: OcticonLoader,
        location: PaneContextPopoverLocation, feedback: String? = nil,
        width: CGFloat = AppStyles.Components.PaneContext.messagesPopoverIdealWidth, actions: MessagesPopoverActions
    ) {
        self.width = width
        self.paneId = paneId
        self.model = model
        self.controls = controls
        self.octiconLoader = octiconLoader
        self.location = location
        self.feedback = feedback
        self.actions = actions
    }

    package var body: some View {
        PaneContextPopoverPanel(
            width: width, contentSpacing: AppStyles.Components.PaneContext.messageSectionSpacing, separatesFooter: true
        ) {
            messagesHeader
        } content: {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Color.clear.frame(height: 0).id(PaneContextPopoverPanelAnchor.top).accessibilityHidden(true)
                if let feedback {
                    PaneContextPopoverNote(feedback).padding(
                        .bottom, AppStyles.Components.PaneContext.messageSectionSpacing)
                }
                ForEach(model.groups, id: \.kind) { group in
                    Section {
                        // Rebind rows eagerly so settling an ask retires its old form controls.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(group.items) { item in
                                messageItem(item)
                                    .padding(.bottom, spacing(after: item, in: group))
                            }
                            if group.omittedPromptCount > 0 {
                                Text("+\(group.omittedPromptCount) more not shown").font(.caption).foregroundStyle(
                                    .secondary
                                )
                                .background {
                                    AccessibilityLabelBridge(
                                        identifier: "pane-context.omitted-prompts",
                                        label: "+\(group.omittedPromptCount) more not shown", role: .staticText)
                                }
                                .padding(.bottom, spacing(after: group))
                            }
                        }
                    } header: {
                        sectionHeader(group)
                    }
                }
                ForEach(model.pages.indices, id: \.self) { index in
                    PaneContextActionButton(
                        controls.moreMessages, role: .utility(octiconLoader),
                        scope: model.pages[index].sourcePaneId.uuidString
                    ) {
                        actions.moreMessages(model.pages[index])
                    }
                    .padding(.top, AppStyles.Components.PaneContext.messageSectionSpacing)
                }
                if let after = model.nextSourcesAfter {
                    PaneContextActionButton(controls.moreSources, role: .utility(octiconLoader)) {
                        actions.moreSources(after)
                    }
                    .padding(.top, AppStyles.Components.PaneContext.messageSectionSpacing)
                }
            }
        } footer: {
            HStack {
                if model.hasNotices {
                    PaneContextActionButton(
                        controls.dismissAllNotices, role: .utility(octiconLoader), action: actions.dismissAllNotices)
                }
                Spacer()
                PaneContextActionButton(controls.goToPane, role: .utility(octiconLoader)) { actions.goToPane(paneId) }
            }
            .background {
                AccessibilityLabelBridge(identifier: "pane-context.messages-footer", label: "", role: .group)
            }
        }
    }

    @ViewBuilder private func messageItem(_ item: MessagesListItemModel) -> some View {
        switch item {
        case .message(let row):
            MessagePopoverRow(
                row: row, controls: controls, octiconLoader: octiconLoader, location: location, actions: actions
            )
            .id(row.key)
        case .providerPrompt(let prompt):
            ProviderPromptRow(prompt: prompt, octiconLoader: octiconLoader)
        }
    }

    private func sectionHeader(_ group: MessagesGroupModel) -> some View {
        PopoverPanelSectionHeader(group.kind.title, variant: .content(count: headerCount(group)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppStyles.General.Spacing.loose)
            .background(AppStyles.Components.PaneContext.pinnedHeaderBackground)
            .id(group.kind)
            .background {
                AccessibilityLabelBridge(
                    identifier: "pane-context.group." + group.kind.rawValue,
                    label: group.kind.title + (headerCount(group).map { " \($0)" } ?? ""), role: .staticText)
            }
    }

    private func spacing(after item: MessagesListItemModel, in group: MessagesGroupModel) -> CGFloat {
        if item.id != group.items.last?.id { return AppStyles.Components.PaneContext.messageRowSpacing }
        return group.omittedPromptCount > 0 ? AppStyles.General.Spacing.loose : spacing(after: group)
    }

    private func spacing(after group: MessagesGroupModel) -> CGFloat {
        group.kind == model.groups.last?.kind ? 0 : AppStyles.Components.PaneContext.messageSectionSpacing
    }

    private func headerCount(_ group: MessagesGroupModel) -> Int? {
        switch group.header {
        case .plain: nil
        case .kindChip(let model, _): model.count
        }
    }

    private var messagesHeader: some View {
        HStack(spacing: AppStyles.General.Spacing.standard) {
            Text(controls.messages.label)
                .font(.system(size: AppStyles.General.Typography.textBase, weight: .semibold))
                .foregroundStyle(.primary)
            if model.unreadCount > 0 {
                Text(String(model.unreadCount))
                    .font(.system(size: AppStyles.General.Typography.textBase))
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
        HStack(alignment: .top, spacing: AppStyles.General.Spacing.loose) {
            PaneContextRowGlyph(icon: row.kindIcon, style: glyphStyle, octiconLoader: octiconLoader)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                PaneContextMessageText(
                    body: row.body, explanation: row.why, age: row.age,
                    identifier: "pane-context.message-text." + row.key.controlScope)
                if let source = row.sourceLabel {
                    PaneContextSourceLabel(title: source, scope: row.key.controlScope)
                }
                if let settledLabel = row.settledLabel {
                    Text(settledLabel).font(.system(size: AppStyles.General.Typography.textSm)).foregroundStyle(
                        .secondary
                    ).background {
                        AccessibilityLabelBridge(
                            identifier: "pane-context.settled." + row.key.controlScope,
                            label: settledLabel, role: .staticText)
                    }
                }
                rowActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if showsDismissInRowHead {
                    dismiss
                } else {
                    Color.clear.frame(height: AppStyles.General.Button.compact).accessibilityHidden(true)
                }
            }
            .frame(width: AppStyles.General.Button.compact)
            .offset(y: -AppStyles.General.Spacing.tight)
        }
        .opacity(row.isDimmed ? AppStyles.General.Foreground.dim : 1)
    }

    @ViewBuilder private var rowActions: some View {
        switch row.availability {
        case .none: EmptyView()
        case .noticeActions:
            if location.presentation(for: .noticeActions) == .inline {
                PaneContextFlowLayout {
                    ForEach(row.actions.indices, id: \.self) { index in
                        let action = row.actions[index]
                        PaneContextActionButton(
                            control(for: action), role: .utility(octiconLoader),
                            scope: row.key.controlScope + ".\(index)"
                        ) {
                            actions.runAction(row.id, row.sourcePaneId, action)
                        }
                    }
                }
            }
        case .askForm:
            if case .ask(_, let form, _, _) = row.shape {
                if location.presentation(for: .answer(form)) == .inline {
                    AskAnswerForm(
                        form: form, submitControl: controls.submit, scope: row.key.controlScope, layout: .messages
                    ) {
                        actions.answer(row.id, row.sourcePaneId, $0)
                    }
                    .padding(.top, AppStyles.Components.PaneContext.formTopSpacing - AppStyles.General.Spacing.standard)
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
        PaneContextActionButton(controls.dismiss, role: .rowDismiss(octiconLoader), scope: row.key.controlScope) {
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
        HStack(alignment: .top, spacing: AppStyles.General.Spacing.loose) {
            PaneContextRowGlyph(icon: prompt.kindIcon, style: .warning, octiconLoader: octiconLoader)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                PaneContextMessageText(
                    body: prompt.summary.map { prompt.reasonText + ": " + $0 } ?? prompt.reasonText,
                    age: prompt.age, identifier: "pane-context.provider-prompt.\(prompt.sourcePaneId).\(prompt.ordinal)"
                )
                if let source = prompt.sourceLabel {
                    PaneContextSourceLabel(title: source, scope: "\(prompt.sourcePaneId).\(prompt.ordinal)")
                }
                Text("Answer in the agent's terminal").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: AppStyles.General.Button.compact).accessibilityHidden(true)
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
