import AgentStudioCore
import AgentStudioSessions
import Foundation

@testable import AgentStudio

/// Canonical-only helper tests carry an unopened seam; no UI demand, worker or observer starts.
@MainActor
func makePaneContextMetadataTestReaders(
    sessionStatus: SessionStatusAtom, presentation: PaneContextPresentationAtom,
    pane: @escaping @MainActor (PaneId) -> Pane?,
    readSessionStatus: @escaping @MainActor (PaneId) async throws -> SessionsStatusReadResult = { _ in .unbound }
) -> PaneContextUIReaders {
    let owners = PaneContextTestSourceOwners(
        sessionStatus: sessionStatus, presentation: presentation,
        pane: pane, serviceProvider: { nil })
    let bindings = owners.bindings(clock: ContinuousClock(), wallNow: Date.init)
    return PaneContextUIReaders(
        sessionStatus: sessionStatus, presentation: presentation, pane: pane,
        readSessionStatus: readSessionStatus, popoverBindings: bindings)
}
