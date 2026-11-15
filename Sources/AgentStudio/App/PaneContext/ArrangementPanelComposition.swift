import AgentStudioCore
import AgentStudioInfrastructure

extension ArrangementPanelSources {
    @MainActor init(
        store: WorkspaceStore, repoCache: RepoCacheAtom, readers: PaneContextUIReaders?,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        self.init(
            store: store, repoCache: repoCache,
            contextDisplay: { pane in readers?.contextDisplayForPane(pane) },
            sessionStatus: { pane in readers?.sessionStatusForPane(pane) },
            performanceTraceRecorder: performanceTraceRecorder ?? readers?.performanceTraceRecorder)
    }
}
