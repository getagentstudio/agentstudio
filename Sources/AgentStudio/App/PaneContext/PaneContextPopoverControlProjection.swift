import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents

enum PaneContextPopoverControlProjection {
    nonisolated static func controls() -> PaneContextPopoverControls {
        PaneContextPopoverControls(
            messages: control(.showPaneMessages, identifier: "pane-context.messages"),
            messageDetails: control(.showPaneMessageDetails, identifier: "pane-context.message-details"),
            answer: control(.answerPaneMessage, identifier: "pane-context.answer"),
            dismiss: control(.dismissPaneMessage, identifier: "pane-context.dismiss"),
            dismissAllNotices: control(.dismissAllPaneNotices, identifier: "pane-context.dismiss-all-notices"),
            markRead: control(.markPaneMessageRead, identifier: "pane-context.mark-read"),
            goToPane: control(.goToMessagePane, identifier: "pane-context.go-to-pane"),
            openFile: control(.openPaneMessageFile, identifier: "pane-context.open-file"),
            openPullRequest: control(.openPaneMessagePullRequest, identifier: "pane-context.open-pull-request"),
            moreMessages: control(.loadMorePaneMessages, identifier: "pane-context.more-messages"),
            moreSources: control(.loadMoreMessageSources, identifier: "pane-context.more-sources"),
            filters: [
                .init(
                    attentionType: nil, control: control(.showAllPaneMessages, identifier: "pane-context.filter-all")),
                .init(
                    attentionType: .needsApproval,
                    control: control(
                        .filterPaneMessages(.needsApproval), identifier: "pane-context.filter.needsApproval")),
                .init(
                    attentionType: .needsReply,
                    control: control(.filterPaneMessages(.needsReply), identifier: "pane-context.filter.needsReply")),
                .init(
                    attentionType: .attention,
                    control: control(.filterPaneMessages(.attention), identifier: "pane-context.filter.attention")),
                .init(
                    attentionType: .informational,
                    control: control(
                        .filterPaneMessages(.informational), identifier: "pane-context.filter.informational")),
            ])
    }

    nonisolated static func control(_ action: LocalActionSpec, identifier: String) -> PaneContextControlModel {
        let spec = action.actionSpec
        let icon: PaneContextControlModel.Icon
        switch spec.icon {
        case .system(let symbol): icon = .system(symbol.rawValue)
        case .octicon(let symbol): icon = .octicon(symbol.rawValue)
        }
        return PaneContextControlModel(
            identifier: identifier, label: spec.label, icon: icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: spec.label)))
    }

}
