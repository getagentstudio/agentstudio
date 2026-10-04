import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

/// Records the canonical pane each session registration resolved, so the
/// registration tests can prove targeting without a Sessions database.
actor RecordingSessionsPort: AppIPCSessionsPort {
    private(set) var eventPaneIds: [UUID] = []
    private(set) var eventProvenances: [IPCSessionEventProvenance] = []
    private(set) var queryPaneIds: [UUID] = []

    func recordProviderEvent(
        paneId: UUID,
        params: IPCSessionEventParams,
        provenance: IPCSessionEventProvenance
    ) async throws -> IPCSessionEventResult {
        eventPaneIds.append(paneId)
        eventProvenances.append(provenance)
        return IPCSessionEventResult(
            paneId: paneId,
            disposition: .unknownCapability,
            correlationId: params.correlationId
        )
    }

    func readSessionState(
        paneId: UUID,
        params: IPCSessionQueryParams
    ) async throws -> IPCSessionQueryResult {
        queryPaneIds.append(paneId)
        return IPCSessionQueryResult(
            paneId: paneId,
            sourceHealth: .unbound,
            session: nil
        )
    }
}
