import AgentStudioCore
import AgentStudioTerminal
import Foundation

extension WorkspaceSurfaceCoordinator {
    /// The existing overlay's Restart click is the only caller. Ordinary repair and Close never enter here.
    func beginRestartIncompatibleTerminal(paneID: UUID) {
        guard incompatibleTerminalRestartTasksByPaneID[paneID] == nil,
            let plan = incompatibleTerminalPlansByPaneID[paneID]
        else { return }
        incompatibleTerminalRestartTasksByPaneID[paneID] = Task { [weak self] in
            guard let self else { return }
            defer { incompatibleTerminalRestartTasksByPaneID.removeValue(forKey: paneID) }
            do {
                try await restartIncompatibleTerminal(paneID: paneID, plan: plan)
            } catch {
                let failureName = (error as? ZmxSessionControlFailure)?.rawValue ?? String(reflecting: type(of: error))
                Self.logger.error(
                    "Incompatible terminal restart could not finish; preserving notice: \(failureName, privacy: .public)"
                )
            }
        }
    }

    func restartIncompatibleTerminal(paneID: UUID, plan: TerminalColdRestorePlan) async throws {
        guard let pane = store.paneAtom.pane(paneID), pane.terminalState?.zmxSessionID == plan.sessionID else { return }
        try await ZmxIncompatibleSessionStop.stop(
            sessionID: plan.sessionID, directory: sessionConfig.zmxDir, expectedIdentity: nil)
        try Task.checkCancellation()
        guard isCurrentTerminalPane(pane) else { return }
        try await store.recordTerminalSessionProtocolVersion(plan.sessionID, version: ZmxProtocol.version)
        guard isCurrentTerminalPane(pane) else { return }
        incompatibleTerminalPlansByPaneID.removeValue(forKey: paneID)
        coldRestartPlansByPaneID[paneID] = plan
        if createViewForRepair(for: pane) == nil {
            // The daemon has exited; retain the exact saved cold command for the next ordinary repair.
            _ = registerTerminalPlaceholderIfNeeded(for: pane, mode: .failedToStart)
        }
    }
}
