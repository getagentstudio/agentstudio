import AgentStudioProgrammaticControl
import Foundation

extension AppIPCBuiltInMethodRegistrations {
    @MainActor
    static func paneListResponse(inputs: AppIPCBuiltInRegistrationInputs, principal: IPCPrincipal?) throws
        -> IPCPaneListResult
    {
        let scope = ownActivityScope(inputs: inputs, principal: principal)
        let result = try inputs.ports.queryPort.listPanes()
        return IPCPaneListResult(
            panes: result.panes.map { pane in
                visibleActivity(pane, principal: principal, scope: scope)
            })
    }

    @MainActor
    static func currentPaneResponse(inputs: AppIPCBuiltInRegistrationInputs, principal: IPCPrincipal?) throws
        -> IPCPaneSnapshotResult
    {
        let scope = ownActivityScope(inputs: inputs, principal: principal)
        let result = try inputs.ports.queryPort.currentPane()
        return IPCPaneSnapshotResult(
            pane: visibleActivity(result.pane, principal: principal, scope: scope),
            tab: result.tab, workspace: result.workspace)
    }

    @MainActor
    static func paneSnapshotResponse(
        paneId: UUID, inputs: AppIPCBuiltInRegistrationInputs, principal: IPCPrincipal?
    ) throws -> IPCPaneSnapshotResult {
        let scope = ownActivityScope(inputs: inputs, principal: principal)
        let result = try inputs.ports.queryPort.snapshotPane(
            paneId, ownPaneAssertion: AppIPCOwnPaneAssertion(principal: principal))
        return IPCPaneSnapshotResult(
            pane: visibleActivity(result.pane, principal: principal, scope: scope),
            tab: result.tab, workspace: result.workspace)
    }

    @MainActor
    private static func ownActivityScope(inputs: AppIPCBuiltInRegistrationInputs, principal: IPCPrincipal?)
        -> AppIPCOwnPaneScope?
    {
        guard case .spawnedPaneAgent(let rawPaneId, _)? = principal?.kind,
            let paneId = UUID(uuidString: rawPaneId)
        else { return nil }
        return inputs.ports.ownPaneScopePort.ownPaneScope(boundPaneId: paneId)
    }

    private static func visibleActivity(
        _ pane: IPCPaneSummary, principal: IPCPrincipal?, scope: AppIPCOwnPaneScope?
    ) -> IPCPaneSummary {
        let activity: IPCPaneActivity?
        switch (principal?.kind, principal?.accessMode) {
        case (.automationClient?, .automationSameUser?), (.unsafeDebugClient?, .unsafeDebug?):
            activity = pane.activity
        case (.spawnedPaneAgent?, _):
            switch scope?.membership(of: pane.id) {
            case .boundPane?, .ownDrawerChild?: activity = pane.activity
            case .outside?, nil: activity = nil
            }
        default: activity = nil
        }
        return IPCPaneSummary(
            id: pane.id, ordinal: pane.ordinal, contentKind: pane.contentKind, residency: pane.residency,
            tabId: pane.tabId, repoId: pane.repoId, worktreeId: pane.worktreeId, isActive: pane.isActive,
            isDrawerChild: pane.isDrawerChild, activity: activity)
    }
}
