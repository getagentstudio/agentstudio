import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import Foundation

/// App composes Feature-owned keyed facts; consumers never reach across Features.
@MainActor
struct PaneContextUIReaders {
    let sessionStatusForPane: @MainActor (PaneId) -> PaneAgentStatusPresentation?
    let contextDisplayForPane: @MainActor (PaneId) -> PaneContextDisplay?
    let isDrawerPane: @MainActor (PaneId) -> Bool
    let readSessionStatus: @MainActor (PaneId) async throws -> SessionsStatusReadResult
    let scopeForPane: @MainActor (PaneId) -> [PaneId]
    let popoverBindings: PaneContextPopoverHostBindings
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    init(
        sessionStatus: SessionStatusAtom, presentation: PaneContextPresentationAtom,
        pane: @escaping @MainActor (PaneId) -> Pane?,
        readSessionStatus: @escaping @MainActor (PaneId) async throws -> SessionsStatusReadResult = { _ in .unbound },
        popoverBindings: PaneContextPopoverHostBindings,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        self.popoverBindings = popoverBindings
        self.performanceTraceRecorder = performanceTraceRecorder
        self.readSessionStatus = readSessionStatus
        isDrawerPane = { pane($0)?.parentPaneId != nil }
        scopeForPane = { owner in
            [owner] + (pane(owner)?.drawer?.paneIds ?? []).map { PaneId(existingUUID: $0) }
        }
        sessionStatusForPane = { sessionStatus.value(for: $0) }
        contextDisplayForPane = { presentation.value(for: $0) }

    }

}
