import AgentStudioInfrastructure
import Foundation

package enum ArrangementTableSection: Hashable, Sendable {
    case worktree(UUID)
    case other

    package var accessibilityKey: String {
        switch self {
        case .worktree(let id): "worktree-\(id.uuidString)"
        case .other: "other"
        }
    }
}

package struct ArrangementPaneGroup: Equatable, Identifiable, Sendable {
    package let id: ArrangementTableSection
    package let title: String
    package let detail: String?
    package let fullPath: String?
    package var panes: [PaneVisibilityInfo]

    package init(
        id: ArrangementTableSection, title: String, detail: String? = nil, fullPath: String? = nil,
        panes: [PaneVisibilityInfo]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.fullPath = fullPath
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
                    !active.minimizedPaneIds.contains(paneId), source.state.metadata.note == nil,
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
            status = .agent(.init(kind: line.kind, label: spec.label, detail: line.text, icon: spec.icon))
        } else {
            status = .unavailable
        }
        return PaneVisibilityInfo(
            id: state.id, title: title, isMinimized: minimized,
            supportsZoom: ZoomCommandCapabilityPolicy.isPaneContentEligible(state.content),
            paneIcon: LocalActionSpec.arrangementPaneKind(state.content).actionSpec.icon,
            agentLine: source.display?.agentLine.map { line in
                .init(
                    summary: line.summary,
                    ageText: PaneContextPresentationRules.agentLineAge(referenceDate: line.updatedAt, now: now))
            },
            paneNote: state.metadata.note,
            cwdPath: context == nil ? state.metadata.facets.cwd.map { AppDataPaths.displayPath(for: $0) } : nil,
            repositoryName: !source.repositoryUnavailable && source.repository?.id == state.metadata.facets.repoId
                ? source.repository?.name : nil,
            worktreeName: context?.worktree.name,
            branchName: branch, worktreePath: context?.worktree.path.path, agentStatus: status,
            section: context.map { .worktree($0.worktree.id) } ?? .other,
            providerName: source.session.flatMap { session in
                guard case .agent = status,
                    session.evidence == .verifiedLive || session.evidence == .verifiedEnded
                else { return nil }
                return session.provider.map { LocalActionSpec.arrangementAgentProvider($0).actionSpec.label }
            })
    }

    static func groupedPanes(_ panes: [PaneVisibilityInfo]) -> [ArrangementPaneGroup] {
        var groups: [ArrangementPaneGroup] = []
        var indexByKey: [ArrangementTableSection: Int] = [:]
        var other: [PaneVisibilityInfo] = []
        for pane in panes {
            if pane.section == .other {
                other.append(pane)
                continue
            }
            if let index = indexByKey[pane.section] {
                groups[index].panes.append(pane)
            } else {
                indexByKey[pane.section] = groups.count
                let missing = LocalActionSpec.arrangementValueUnavailable.actionSpec.label
                groups.append(
                    .init(
                        id: pane.section, title: pane.worktreeName ?? missing,
                        detail: "\(pane.repositoryName ?? missing) • \(pane.branchName ?? missing)",
                        fullPath: pane.worktreePath, panes: [pane]))
            }
        }
        if !other.isEmpty {
            groups.append(
                .init(id: .other, title: LocalActionSpec.arrangementOtherGroup.actionSpec.label, panes: other))
        }
        return groups
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
