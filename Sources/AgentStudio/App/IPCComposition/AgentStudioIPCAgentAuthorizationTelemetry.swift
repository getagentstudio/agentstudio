import AgentStudioAppIPC
import AgentStudioInfrastructure
import Foundation

/// Records each pane-agent authorization decision on the performance recorder
/// as `performance.ipc.agent_authorization`, with its outcome as the one
/// controlled attribute.
struct AgentStudioIPCAgentAuthorizationTelemetry: AppIPCAgentAuthorizationTelemetry {
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    func recordAgentAuthorization(elapsed: Duration, outcome: AppIPCAgentAuthorizationOutcome) {
        performanceTraceRecorder?.recordDuration(
            .ipcAgentAuthorization,
            duration: elapsed,
            attributes: ["agentstudio.performance.ipc.agent_authorization.outcome": .string(outcome.rawValue)]
        )
    }
}
