import Foundation

package enum ArrangementTableSection: Equatable, Sendable {
    case unsectioned
}

package enum ArrangementPaneStatus: Equatable, Sendable {
    case hidden
    case unavailable
    case agent(ArrangementPaneStatusLabel)
}

package struct ArrangementPaneStatusLabel: Equatable, Sendable {
    package let kind: StatusLine.Kind
    package let label: String
    package let detail: String
    package let icon: CommandIcon
}

package struct ArrangementTableProjection: Equatable, Sendable {
    package let panes: [PaneVisibilityInfo]
    package let arrangements: [ArrangementInfo]
    package let zoomMode: ArrangementPanelZoomMode?
}

package struct ArrangementTableInput: Sendable {
    struct PaneSource: Sendable {
        let state: PaneGraphState
        let display: PaneContextDisplay?
        let session: PaneAgentStatusPresentation?
        let repository: Repo?
        let worktree: Worktree?
        let repositoryUnavailable: Bool
        let worktreeUnavailable: Bool
        let enrichment: WorktreeEnrichment?
    }

    let graph: TabGraphState?
    let activeArrangementId: UUID?
    let sources: [UUID: PaneSource]
    let zoom: ZoomPresentation?
    var shellExecutablePath: String?
}

package enum ArrangementTableProjector {
    @concurrent nonisolated package static func project(_ input: ArrangementTableInput) async throws
        -> ArrangementTableProjection
    {
        guard let graph = input.graph,
            let active = graph.arrangements.first(where: { $0.id == input.activeArrangementId })
                ?? graph.arrangements.first(where: \.isDefault)
        else { return .init(panes: [], arrangements: [], zoomMode: nil) }
        var rows: [PaneVisibilityInfo] = []
        for paneId in active.layout.paneIds {
            try Task.checkCancellation()
            guard let source = input.sources[paneId], !source.state.isDrawerChild else { continue }
            rows.append(
                projectPaneRow(
                    source, minimized: active.minimizedPaneIds.contains(paneId), shell: input.shellExecutablePath))
        }
        let arrangements = graph.arrangements.map {
            ArrangementInfo(
                id: $0.id, name: $0.name, role: $0.isDefault ? .defaultArrangement : .userLayout,
                isActive: $0.id == active.id)
        }
        let zoomMode = input.zoom.map { zoom in
            ArrangementDerived.zoomMode(
                presentation: zoom,
                sourceIdentity: input.sources[zoom.sourcePaneId].map { source in
                    let context = validatedAssociation(source)
                    return ArrangementDerived.zoomSourceIdentity(
                        for: source.state.pane(isDrawerExpanded: false),
                        workspaceContext: ArrangementDerived.zoomSourceWorkspaceContext(
                            resolvedContext: context, worktreeEnrichment: source.enrichment))
                })
        }
        return .init(panes: rows, arrangements: arrangements, zoomMode: zoomMode)
    }

    private static func projectPaneRow(_ source: ArrangementTableInput.PaneSource, minimized: Bool, shell: String?)
        -> PaneVisibilityInfo
    {
        let state = source.state
        let context = validatedAssociation(source)
        let title: String
        switch state.content {
        case .terminal:
            title = PaneContextPresentationRules.displayTitle(
                raw: state.metadata.title, agentTitle: source.display?.agentTitle,
                cwd: state.metadata.facets.cwd, shell: shell)
        case .webview, .bridgePanel, .codeViewer, .unsupported:
            title = state.metadata.title
        }
        let branch = context.flatMap { _ in source.enrichment }.map {
            let name = $0.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "detached HEAD" : name
        }
        let status: ArrangementPaneStatus
        if minimized {
            status = .hidden
        } else if let line = PaneContextPresentationRules.statusLine(source.session) {
            let statusKind =
                line.kind == .needsYou
                ? AgentSessionStatus.needsYou(source.session?.compactPrompt?.reason ?? .blocked)
                : source.session?.status ?? .unknown
            let spec = LocalActionSpec.compactPaneSessionStatus(statusKind).actionSpec
            status = .agent(.init(kind: line.kind, label: spec.label, detail: line.text, icon: spec.icon))
        } else {
            status = .unavailable
        }
        return PaneVisibilityInfo(
            id: state.id, title: title, isMinimized: minimized,
            supportsZoom: ZoomCommandCapabilityPolicy.isPaneContentEligible(state.content),
            paneIcon: .pane,
            agentLine: source.display?.agentLine?.summary, worktreeName: context?.worktree.name,
            branchName: branch, worktreePath: context?.worktree.path.path, agentStatus: status)
    }

    private static func validatedAssociation(_ source: ArrangementTableInput.PaneSource) -> (
        repo: Repo, worktree: Worktree
    )? {
        guard !source.repositoryUnavailable, !source.worktreeUnavailable,
            let repo = source.repository, let worktree = source.worktree,
            repo.id == source.state.metadata.facets.repoId,
            worktree.id == source.state.metadata.facets.worktreeId, worktree.repoId == repo.id
        else { return nil }
        return (repo, worktree)
    }
}
