import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

package enum ArrangementTableSection: Hashable, Sendable {
    case repository(UUID)
    case other

    package var accessibilityKey: String {
        switch self {
        case .repository(let id): "repository-\(id.uuidString)"
        case .other: "other"
        }
    }
}

package struct ArrangementPaneGroup: Equatable, Identifiable, Sendable {
    package let id: ArrangementTableSection
    package let title: String
    package let icon: AppEntityIcon?
    package var panes: [PaneVisibilityInfo]

    package init(id: ArrangementTableSection, title: String, icon: AppEntityIcon? = nil, panes: [PaneVisibilityInfo]) {
        self.id = id
        self.title = title
        self.icon = icon
        self.panes = panes
    }
}

package enum ArrangementPaneStatus: Equatable, Sendable {
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
    package var groups: [ArrangementPaneGroup] = []
    package var nextAgeChange: Date?
    package var tableMetrics: ArrangementTableMetrics = .minimum

    package static func == (lhs: Self, rhs: Self) -> Bool {
        // The worker still re-arms a changed deadline when paint is equal.
        lhs.panes == rhs.panes && lhs.arrangements == rhs.arrangements && lhs.zoomMode == rhs.zoomMode
            && lhs.groups == rhs.groups && lhs.tableMetrics == rhs.tableMetrics
    }
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
    var referenceDate: Date = .now
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
                    source, minimized: active.minimizedPaneIds.contains(paneId), shell: input.shellExecutablePath,
                    now: input.referenceDate))
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
        return .init(
            panes: rows, arrangements: arrangements, zoomMode: zoomMode,
            groups: groupedPanes(rows),
            nextAgeChange: active.layout.paneIds.compactMap { paneId -> Date? in
                guard let source = input.sources[paneId], !source.state.isDrawerChild,
                    let line = source.display?.agentLine
                else { return nil }
                return PaneContextPresentationRules.age(referenceDate: line.updatedAt, now: input.referenceDate)
                    .nextChange
            }.min(),
            tableMetrics: ArrangementTableMetrics.measuring(rows))
    }

    private static func projectPaneRow(
        _ source: ArrangementTableInput.PaneSource, minimized: Bool, shell: String?, now: Date
    )
        -> PaneVisibilityInfo
    {
        let state = source.state
        let context = validatedAssociation(source)
        let repository = validatedRepository(source)
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
        if let line = PaneContextPresentationRules.statusLine(source.session) {
            let statusKind =
                line.kind == .needsYou
                ? AgentSessionStatus.needsYou(source.session?.compactPrompt?.reason ?? .blocked)
                : source.session?.status ?? .unknown
            let spec = LocalActionSpec.compactPaneSessionStatus(statusKind).actionSpec
            status = .agent(
                .init(
                    kind: line.kind, label: spec.label, detail: line.text,
                    icon: LocalActionSpec.arrangementPaneStatusMark(line.kind).actionSpec.icon))
        } else {
            status = .unavailable
        }
        let providerName = source.session.flatMap { session -> String? in
            guard case .agent = status,
                session.evidence == .verifiedLive || session.evidence == .verifiedEnded
            else { return nil }
            return session.provider.map { LocalActionSpec.arrangementAgentProvider($0).actionSpec.label }
        }
        let detail: ArrangementPaneDetailLine?
        if let line = source.display?.agentLine {
            detail = .agentLine(
                .init(
                    summary: line.summary,
                    ageText: PaneContextPresentationRules.agentLineAge(referenceDate: line.updatedAt, now: now)))
        } else {
            detail = state.metadata.note.map(ArrangementPaneDetailLine.note)
        }
        let chips =
            providerName == nil
            ? []
            : PaneContextPresentationRules.kindChips(
                source.display?.includingDrawers.kinds ?? .zero)
        return PaneVisibilityInfo(
            id: state.id, title: title, isMinimized: minimized,
            supportsZoom: ZoomCommandCapabilityPolicy.isPaneContentEligible(state.content),
            paneIcon: LocalActionSpec.arrangementPaneKind(state.content, repositoryLinked: repository != nil)
                .actionSpec.icon,
            detailLine: detail, repositoryName: repository?.name, branchName: branch, agentStatus: status,
            section: repository.map { .repository($0.id) } ?? .other, providerName: providerName,
            messageChips: chips.map {
                let model = PaneMessageKindChipProjection.model($0)
                return .init(model: model, control: PaneMessageKindChipProjection.readout(model))
            })
    }

    static func groupedPanes(_ panes: [PaneVisibilityInfo]) -> [ArrangementPaneGroup] {
        var groups: [ArrangementPaneGroup] = []
        var indexByKey: [ArrangementTableSection: Int] = [:]
        var other: [PaneVisibilityInfo] = []
        for pane in panes {
            guard case .repository = pane.section, let repositoryName = pane.repositoryName else {
                other.append(pane)
                continue
            }
            if let index = indexByKey[pane.section] {
                groups[index].panes.append(pane)
            } else {
                indexByKey[pane.section] = groups.count
                groups.append(
                    .init(
                        id: pane.section, title: repositoryName,
                        icon: .coloredRepo(colorHex: AppStyles.Shell.Sidebar.accentPaletteHexes[0]), panes: [pane]))
            }
        }
        if !other.isEmpty {
            groups.append(
                .init(
                    id: .other, title: LocalActionSpec.arrangementOtherGroup.actionSpec.label, panes: other))
        }
        return groups
    }

    private static func validatedRepository(_ source: ArrangementTableInput.PaneSource) -> Repo? {
        guard !source.repositoryUnavailable, let repo = source.repository,
            repo.id == source.state.metadata.facets.repoId
        else { return nil }
        return repo
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
