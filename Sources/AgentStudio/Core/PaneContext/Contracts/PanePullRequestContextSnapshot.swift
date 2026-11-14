import Foundation

/// A complete latest-state capture. All joins and visibility decisions belong to the service.
package struct PanePullRequestContextSnapshot: Equatable, Sendable {
    package struct EnrichmentBranch: Equatable, Sendable {
        package let repoId: UUID
        package let branch: String
        package init(repoId: UUID, branch: String) {
            self.repoId = repoId
            self.branch = branch
        }
    }
    package var paneFactsByPaneId: [UUID: PaneStructuralFacts] = [:]
    package var windowPresentation: WindowPresentationFacts = .hidden
    package var activeLayoutPaneIds: Set<UUID> = []
    package var minimizedPaneIds: Set<UUID> = []
    package var isManagementLayerActive = false
    package var zoom: ZoomPresentation?
    package var enrichmentBranchByWorktreeId: [UUID: EnrichmentBranch] = [:]
    package var pullRequestURLByBranchKey: [RepoBranchKey: URL?] = [:]

    package init() {}

    var mainPaneIds: Set<UUID> {
        Set(
            paneFactsByPaneId.compactMap { id, facts in
                if case .layout = facts.placement { return id }
                return nil
            })
    }

    var visibleMainPaneIds: Set<UUID> {
        guard windowPresentation.isVisible, !windowPresentation.isOccluded, !windowPresentation.isMiniaturized
        else { return [] }
        var candidates: Set<UUID>
        if let zoom {
            candidates = [zoom.sourcePaneId]
            if case .retainedVisible(let companion) = zoom.viewerPresentation { candidates.insert(companion) }
        } else {
            candidates = activeLayoutPaneIds
            if !isManagementLayerActive { candidates.subtract(minimizedPaneIds) }
        }
        return candidates.intersection(mainPaneIds).filter { paneFactsByPaneId[$0]?.residency.isActive == true }
    }

    func worktreePullRequest(for paneId: UUID) -> ForgePullRequestIdentity? {
        guard let facts = paneFactsByPaneId[paneId], case .layout = facts.placement,
            let worktree = facts.worktreeID, let branch = enrichmentBranchByWorktreeId[worktree],
            let key = RepoBranchKey(repoId: branch.repoId, branch: branch.branch),
            let capturedURL = pullRequestURLByBranchKey[key], let url = capturedURL,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host?.lowercased() == "github.com"
        else { return nil }
        let segments = components.path.split(separator: "/")
        guard segments.count >= 4, segments[2] == "pull", let number = Int(segments[3]) else { return nil }
        return try? ForgePullRequestIdentity(
            host: "github.com", owner: String(segments[0]).lowercased(),
            repository: String(segments[1]).lowercased(), number: number)
    }
}
