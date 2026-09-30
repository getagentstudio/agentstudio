import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Reads an agent's own pane from the current pane graph: the bound pane and,
/// when it is a main-layout pane, its drawer children. A drawer terminal owns
/// only itself. One pane lookup per request; no I/O.
@MainActor
final class WorkspaceOwnPaneScopePort: AppIPCOwnPaneScopePort, @unchecked Sendable {
    private let workspaceStore: WorkspaceStore
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    init(
        workspaceStore: WorkspaceStore,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.performanceTraceRecorder = performanceTraceRecorder
    }

    /// The only synchronous, MainActor-held work inside `AppIPCPaneAgentAuthorization.authorize`;
    /// everything else it awaits happens off this actor. Measured separately from that
    /// call's overall elapsed time so a MainActor stall here is distinguishable from
    /// scheduling delay. No pane identity is attached — see the OTLP export scrub rule.
    func ownPaneScope(boundPaneId: UUID) -> AppIPCOwnPaneScope? {
        let clock = ContinuousClock()
        let started = clock.now
        defer {
            performanceTraceRecorder?.recordDuration(
                .ipcAgentAuthorizationMainActorHeld,
                duration: started.duration(to: clock.now)
            )
        }
        guard let pane = workspaceStore.paneAtom.pane(boundPaneId) else { return nil }
        return AppIPCOwnPaneScope(
            boundPaneId: boundPaneId,
            isDrawerTerminal: pane.isDrawerChild,
            drawerChildPaneIds: Set(pane.drawer?.paneIds ?? [])
        )
    }
}
