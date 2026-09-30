import AgentStudioAppIPC
import Foundation

/// Keeps the authorization-time samples pane-agent authorization reported, in
/// order, standing in for the App's performance recorder.
final class RecordingAgentAuthorizationTelemetry: AppIPCAgentAuthorizationTelemetry, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var outcomesStorage: [AppIPCAgentAuthorizationOutcome] = []

    nonisolated init() {}

    nonisolated var outcomes: [AppIPCAgentAuthorizationOutcome] {
        lock.withLock { outcomesStorage }
    }

    nonisolated func recordAgentAuthorization(elapsed: Duration, outcome: AppIPCAgentAuthorizationOutcome) {
        lock.withLock { outcomesStorage.append(outcome) }
    }
}
