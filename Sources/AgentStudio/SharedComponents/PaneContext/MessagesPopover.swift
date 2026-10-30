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
    package let dismissPopover: @MainActor () -> Void
    package let captureBodyGeometry: @MainActor (PaneContextTextBodyKey, PaneContextMessageBodyGeometry) -> Void
    package init(
        answer: @escaping @MainActor (UUID, UUID, AskFormDraft) -> Void,
        dismiss: @escaping @MainActor (UUID, UUID) -> Void,
        dismissAllNotices: @escaping @MainActor () -> Void,
        runAction: @escaping @MainActor (UUID, UUID, MessageActionModel) -> Void,
        goToPane: @escaping @MainActor (UUID) -> Void,
        moreMessages: @escaping @MainActor (MessagePageCursorModel) -> Void,
        moreSources: @escaping @MainActor (UUID) -> Void,
        dismissPopover: @escaping @MainActor () -> Void,
        captureBodyGeometry: @escaping @MainActor (PaneContextTextBodyKey, PaneContextMessageBodyGeometry) -> Void
    ) {
        self.answer = answer
        self.dismiss = dismiss
        self.dismissAllNotices = dismissAllNotices
        self.runAction = runAction
        self.goToPane = goToPane
        self.moreMessages = moreMessages
        self.moreSources = moreSources
        self.dismissPopover = dismissPopover
        self.captureBodyGeometry = captureBodyGeometry
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
    private let interactions: MessagesPopoverBindings
    private let messageApplication: PaneContextMessageTextApplication?
    private let onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)?
    @Binding private var selectedFilter: Int
    @Binding private var selectedDetails: PaneContextMessageTextValue?

    package init(
        paneId: UUID, model: MessagesPopoverModel, controls: PaneContextPopoverControls, octiconLoader: OcticonLoader,
        location: PaneContextPopoverLocation, feedback: String? = nil,
        width: CGFloat = AppStyles.Components.PaneContext.messagesPopoverIdealWidth, actions: MessagesPopoverActions,
        interactions: MessagesPopoverBindings,
        messageApplication: PaneContextMessageTextApplication? = nil,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil
    ) {
        self.width = width
        self.paneId = paneId
        self.model = model
        self.controls = controls
        self.octiconLoader = octiconLoader
        self.location = location
        self.feedback = feedback
        self.actions = actions
        self.interactions = interactions
        self._selectedFilter = interactions.selectedFilter
        self._selectedDetails = interactions.details
        self.messageApplication = messageApplication
        self.onHeightWrite = onHeightWrite
    }

    package var body: some View {
        PopoverDetailSplit(
            isPresented: selectedDetails != nil, title: selectedDetails?.detailsTitle ?? controls.showDetails.label,
            width: AppStyles.Components.PaneContext.messageDetailsWidth,
            maximumHeight: AppStyles.Components.PaneContext.popoverMaximumHeight,
            identifier: "pane-context.details-panel",
            onExit: exitDetails
        ) {
            primaryPanel
        } detail: {
            if let selectedDetails {
                VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                    Text(selectedDetails.bodyText.paint).font(selectedDetails.bodyFont.paintFont)
                        .lineSpacing(selectedDetails.bodyFont.lineSpacing)
                        .background {
                            AccessibilityLabelBridge(
                                identifier: "pane-context.details-text", label: selectedDetails.body, role: .staticText)
                        }
                    if let explanation = selectedDetails.explanation {
                        Text(explanation).font(.system(size: AppStyles.General.Typography.textSm)).foregroundStyle(
                            .secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        } close: {
            PaneContextActionButton(controls.closeDetails, role: .rowDismiss(octiconLoader)) { selectedDetails = nil }
        }
    }

    private func exitDetails() {
        if selectedDetails != nil { selectedDetails = nil } else { actions.dismissPopover() }
    }

    private var primaryPanel: some View {
        PopoverPanel(
            width: width, maximumHeight: AppStyles.Components.PaneContext.popoverMaximumHeight,
            contentSpacing: AppStyles.Components.PaneContext.messageSectionSpacing,
            identifier: "pane-context.popover-panel", onHeightWrite: onHeightWrite,
            openingContentIsReady: model.filters[selectedFilter].bodyLayoutsAreReady,
            centersContent: model.filters[selectedFilter].noLoadedContent != nil
        ) {
            messagesHeader
        } content: {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: AppStyles.Components.PaneContext.messageSectionSpacing) {
                    if let feedback { PaneContextPopoverNote(feedback) }
                    ForEach(model.filters[selectedFilter].groups, id: \.kind) { group in
                        VStack(alignment: .leading, spacing: AppStyles.General.Spacing.loose) {
                            PopoverPanelSectionHeader(group.kind.title, variant: .content(count: headerCount(group)))
                                .background {
                                    AccessibilityLabelBridge(
                                        identifier: "pane-context.group." + group.kind.rawValue,
                                        label: group.kind.title + (headerCount(group).map { " \($0)" } ?? ""),
                                        role: .staticText
                                    )
                                }
                            VStack(alignment: .leading, spacing: AppStyles.Components.PaneContext.messageRowSpacing) {
                                ForEach(group.items) { item in
                                    switch item {
                                    case .message(let row):
                                        MessagePopoverRow(
                                            row: row, controls: controls, octiconLoader: octiconLoader,
                                            location: location, actions: actions,
                                            messageApplication: messageApplication,
                                            draft: interactions.draft(row.key),
                                            isDetailsSelected: selectedDetails?.key == .message(row.key),
                                            onDetails: { selectedDetails = $0 }
                                        )
                                        .id(row.key)
                                    case .providerPrompt(let prompt):
                                        ProviderPromptRow(
                                            prompt: prompt, octiconLoader: octiconLoader,
                                            messageApplication: messageApplication,
                                            isDetailsSelected: selectedDetails?.key == prompt.textBodyKey,
                                            onDetails: { selectedDetails = $0 },
                                            onBodyGeometry: actions.captureBodyGeometry
                                        )
                                    }
                                }
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
                            }
                        }
                        .id(group.kind)
                    }
                    ForEach(model.pages.indices, id: \.self) { index in
                        PaneContextActionButton(
                            controls.moreMessages, role: .utility(octiconLoader),
                            scope: model.pages[index].sourcePaneId.uuidString
                        ) {
                            actions.moreMessages(model.pages[index])
                        }
                    }
                    if let after = model.nextSourcesAfter {
                        PaneContextActionButton(controls.moreSources, role: .utility(octiconLoader)) {
                            actions.moreSources(after)
                        }
                    }
                }
                if let status = model.filters[selectedFilter].noLoadedContent {
                    CenteredEmptyState(status.label, identifier: status.identifier)
                }
            }
            .id(PaneContextPopoverPanelAnchor.top)
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

    private func headerCount(_ group: MessagesGroupModel) -> Int? {
        switch group.header {
        case .plain: nil
        case .kindChip(let model, _): model.count
        }
    }

    private var messagesHeader: some View {
        HStack(spacing: AppStyles.General.Spacing.standard) {
            Text(controls.messages.label)
                .background {
                    AccessibilityLabelBridge(
                        identifier: "pane-context.messages-title", label: controls.messages.label, role: .staticText)
                }
                .font(.system(size: AppStyles.General.Typography.textBase, weight: .semibold))
                .foregroundStyle(.primary)
            if model.unreadCount > 0 {
                Text(String(model.unreadCount))
                    .font(.system(size: AppStyles.General.Typography.textBase))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: AppStyles.General.Spacing.standard) {
                ForEach(MessagesFilterModel.chipMemberships, id: \.self) { membership in
                    let filter = model.filters[membership]
                    Toggle(
                        isOn: .init(
                            get: { selectedFilter & membership != 0 },
                            set: { selected in
                                selectedFilter = selected ? selectedFilter | membership : selectedFilter & ~membership
                            }
                        )
                    ) {
                        SidebarChip(
                            icon: filter.control.icon.chipIcon,
                            octiconLoader: octiconLoader, text: filter.control.label,
                            style: filter.kind?.style ?? .neutral,
                            isSelected: selectedFilter & membership != 0, paint: .popover)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .controlHelp(filter.control.tooltip)
                    .accessibilityHidden(true)
                    .background {
                        AccessibilityPressBridge(
                            identifier: filter.control.identifier, label: filter.control.accessibilityLabel,
                            isSelected: selectedFilter & membership != 0, help: filter.control.tooltip.text,
                            action: { selectedFilter ^= membership })
                    }
                }
            }
            .fixedSize()

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
    let messageApplication: PaneContextMessageTextApplication?
    @Binding var draft: AskFormDraft
    let isDetailsSelected: Bool
    let onDetails: @MainActor (PaneContextMessageTextValue) -> Void
    @State private var bodyGeometry: PaneContextMessageBodyGeometry?

    private var hasInlineForm: Bool {
        guard case .askForm = row.availability, case .ask(_, let form, _, _) = row.shape else { return false }
        return location.presentation(for: .answer(form)) == .inline
    }

    private var formDetails: AskAnswerForm.DetailsAction? {
        guard case .ready(let prepared, _, let control?, _) = row.bodyLayout, prepared == bodyGeometry else {
            return nil
        }
        let value = PaneContextMessageTextValue(row: row)
        return .init(
            control: control, scope: value.key.textIdentifier, octiconLoader: octiconLoader,
            isSelected: isDetailsSelected, perform: { onDetails(value) })
    }

    var body: some View {
        let textValue = PaneContextMessageTextValue(row: row)
        HStack(alignment: .top, spacing: AppStyles.General.Spacing.loose) {
            PaneContextRowGlyph(icon: row.kindIcon, style: glyphStyle, octiconLoader: octiconLoader)
                .background {
                    AccessibilityLabelBridge(
                        identifier: "pane-context.message-glyph." + row.key.controlScope,
                        label: "", exposesAccessibility: false)
                }
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                PaneContextMessageText(
                    value: textValue, application: messageApplication, octiconLoader: octiconLoader,
                    isDetailsSelected: isDetailsSelected, showsBodyDetails: !hasInlineForm,
                    onDetails: { onDetails(textValue) },
                    onBodyGeometry: { key, geometry in
                        if bodyGeometry != geometry { bodyGeometry = geometry }
                        actions.captureBodyGeometry(key, geometry)
                    })
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
        .opacity(textValue.isRead ? AppStyles.General.Foreground.dim : 1)
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
                        form: form, draft: $draft, submitControl: controls.submit, scope: row.key.controlScope,
                        layout: .messages,
                        choicePrompt: controls.chooseOption, requiredField: controls.requiredField,
                        details: formDetails
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
    let messageApplication: PaneContextMessageTextApplication?
    let isDetailsSelected: Bool
    let onDetails: @MainActor (PaneContextMessageTextValue) -> Void
    let onBodyGeometry: @MainActor (PaneContextTextBodyKey, PaneContextMessageBodyGeometry) -> Void
    var body: some View {
        let textValue = PaneContextMessageTextValue(prompt: prompt)
        HStack(alignment: .top, spacing: AppStyles.General.Spacing.loose) {
            PaneContextRowGlyph(icon: prompt.kindIcon, style: .warning, octiconLoader: octiconLoader)
            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.standard) {
                PaneContextMessageText(
                    value: textValue, application: messageApplication, octiconLoader: octiconLoader,
                    isDetailsSelected: isDetailsSelected,
                    onDetails: { onDetails(textValue) }, onBodyGeometry: onBodyGeometry)
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
