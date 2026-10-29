import AgentStudioInfrastructure
import Foundation

/// Read-only composition ports. Capture copies keyed owner values; the projector interprets them.
@MainActor
package struct ArrangementPanelSources {
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let contextDisplay: @MainActor (PaneId) -> PaneContextDisplay?
    let sessionStatus: @MainActor (PaneId) -> PaneAgentStatusPresentation?
    let shellExecutablePath: String?
    let recorder: AgentStudioPerformanceTraceRecorder?

    package init(
        store: WorkspaceStore, repoCache: RepoCacheAtom,
        contextDisplay: @escaping @MainActor (PaneId) -> PaneContextDisplay? = { _ in nil },
        sessionStatus: @escaping @MainActor (PaneId) -> PaneAgentStatusPresentation? = { _ in nil },
        shellExecutablePath: String? = nil,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        self.store = store
        self.repoCache = repoCache
        self.contextDisplay = contextDisplay
        self.sessionStatus = sessionStatus
        self.shellExecutablePath = shellExecutablePath
        recorder = performanceTraceRecorder
    }

    func capture(tabId: UUID) -> ArrangementTableInput {
        let graph = store.tabGraphAtom.tabState(tabId)
        var sources: [UUID: ArrangementTableInput.PaneSource] = [:]
        for paneId in graph?.paneIDs ?? [] {
            guard let state = store.paneGraphAtom.paneState(paneId) else { continue }
            let repoId = state.metadata.facets.repoId
            let worktreeId = state.metadata.facets.worktreeId
            let repository: Repo?
            let repositoryUnavailable: Bool
            if let repoId {
                repository = store.repositoryTopologyAtom.repo(repoId)
                repositoryUnavailable = store.repositoryTopologyAtom.isRepoUnavailable(repoId)
            } else {
                repository = nil
                repositoryUnavailable = false
            }
            let worktree: Worktree?
            let worktreeUnavailable: Bool
            let enrichment: WorktreeEnrichment?
            if let worktreeId {
                worktree = store.repositoryTopologyAtom.worktree(worktreeId)
                worktreeUnavailable = store.repositoryTopologyAtom.isWorktreeUnavailable(worktreeId)
                enrichment = repoCache.worktreeEnrichment(for: worktreeId)
            } else {
                worktree = nil
                worktreeUnavailable = false
                enrichment = nil
            }
            sources[paneId] = .init(
                state: state, display: contextDisplay(.init(existingUUID: paneId)),
                session: sessionStatus(.init(existingUUID: paneId)), repository: repository, worktree: worktree,
                repositoryUnavailable: repositoryUnavailable, worktreeUnavailable: worktreeUnavailable,
                enrichment: enrichment)
        }
        return .init(
            graph: graph, activeArrangementId: store.arrangementCursorAtom.activeArrangementId(forTab: tabId),
            sources: sources, zoom: store.panePresentationAtom.zoomPresentation(forTab: tabId),
            shellExecutablePath: shellExecutablePath)
    }
}
