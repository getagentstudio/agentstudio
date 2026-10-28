import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents

enum PaneContextPopoverControlProjection {
    nonisolated static func controls() -> PaneContextPopoverControls {
        PaneContextPopoverControls(
            messages: control(.showPaneMessages, identifier: "pane-context.messages"),
            submit: control(.submitPaneMessageAnswer, identifier: "pane-context.submit"),
            dismiss: control(.dismissPaneMessage, identifier: "pane-context.dismiss"),
            dismissAllNotices: control(.dismissAllPaneNotices, identifier: "pane-context.dismiss-all-notices"),
            goToPane: control(.goToMessagePane, identifier: "pane-context.go-to-pane"),
            openFile: control(.openPaneMessageFile, identifier: "pane-context.open-file"),
            openPullRequest: control(.openPaneMessagePullRequest, identifier: "pane-context.open-pull-request"),
            moreMessages: control(.loadMorePaneMessages, identifier: "pane-context.more-messages"),
            moreSources: control(.loadMoreMessageSources, identifier: "pane-context.more-sources"))
    }

    nonisolated static func control(_ action: LocalActionSpec, identifier: String) -> PaneContextControlModel {
        let spec = action.actionSpec
        return PaneContextControlModel(
            identifier: identifier, label: spec.label, icon: icon(spec.icon),
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: spec.label)))
    }

    nonisolated static func icon(_ icon: CommandIcon) -> PaneContextControlModel.Icon {
        switch icon {
        case .system(let symbol): .system(symbol.rawValue)
        case .octicon(let symbol): .octicon(symbol.rawValue)
        }
    }

}
