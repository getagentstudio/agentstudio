import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Observation

@MainActor
extension WorkspaceSurfaceCoordinator {
    func restartPanePullRequestContextObservation() {
        panePullRequestContextObservationGeneration &+= 1
        lastPanePullRequestContext = nil
        guard paneContextService != nil else { return }
        observePanePullRequestContext(generation: panePullRequestContextObservationGeneration)
    }

    private func observePanePullRequestContext(generation: UInt64) {
        let captured = withObservationTracking {
            capturePanePullRequestContext(previous: lastPanePullRequestContext)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.panePullRequestContextObservationGeneration == generation else { return }
                self.observePanePullRequestContext(generation: generation)
            }
        }
        guard captured.changed else { return }
        lastPanePullRequestContext = captured.snapshot
        paneContextService?.submitPullRequestContext(captured.snapshot)
    }

    func capturePanePullRequestContext(previous: PanePullRequestContextSnapshot?)
        -> (snapshot: PanePullRequestContextSnapshot, changed: Bool)
    {
        let began = ContinuousClock.now
        var snapshot = PanePullRequestContextSnapshot()
        let graph = store.paneAtom.graphAtom
        for paneId in graph.paneIDs {
            snapshot.paneFactsByPaneId[paneId] = graph.paneStructuralFacts(paneId)
        }
        snapshot.windowPresentation =
            repositoryFactDemandOwningWindowId
            .flatMap(windowLifecycleStore.presentationFacts(for:)) ?? .hidden
        let tabId = store.tabLayoutAtom.activeTabId
        snapshot.activeLayoutPaneIds = Set(
            tabId.flatMap { store.tabLayoutAtom.canonicalActiveLayout(forTab: $0)?.paneIds } ?? [])
        snapshot.minimizedPaneIds = tabId.map { store.tabLayoutAtom.canonicalActiveMinimizedPaneIDs(forTab: $0) } ?? []
        snapshot.isManagementLayerActive = atom(\.managementLayer).isActive
        snapshot.zoom = tabId.flatMap { store.panePresentationAtom.zoomPresentation(forTab: $0) }
        let cache = atom(\.repoCache)
        snapshot.enrichmentBranchByWorktreeId = cache.worktreeEnrichmentSnapshot().mapValues {
            .init(repoId: $0.repoId, branch: $0.branch)
        }
        snapshot.pullRequestURLByBranchKey = cache.pullRequestFactsSnapshot().mapValues(\.exactOpenURL)
        let changed = previous != snapshot
        performanceTraceRecorder?.recordDuration(
            .panePullRequestContextCapture, duration: began.duration(to: ContinuousClock.now),
            attributes: [
                "agentstudio.pane_context.capture.outcome": .string(changed ? "changed" : "equal"),
                "agentstudio.pane_context.capture.pane_count": .int(snapshot.paneFactsByPaneId.count),
                "agentstudio.pane_context.capture.worktree_count": .int(snapshot.enrichmentBranchByWorktreeId.count),
                "agentstudio.pane_context.capture.pr_fact_count": .int(snapshot.pullRequestURLByBranchKey.count),
            ])
        return (snapshot, changed)
    }
}
