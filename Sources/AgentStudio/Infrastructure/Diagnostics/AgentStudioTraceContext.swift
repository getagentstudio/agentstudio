import Tracing

extension ServiceContext {
    var agentStudioCorrelationID: String? {
        get {
            self[AgentStudioCorrelationIDKey.self]
        }
        set {
            self[AgentStudioCorrelationIDKey.self] = newValue
        }
    }

    /// Restore R3 cost telemetry (GREEN STOP resolution): a caller scopes
    /// this around a `DefaultProcessExecutor.execute` call to name which
    /// restore phase owns that process's cost. `ProcessExecution` captures
    /// the value once, at construction, and never reads `ServiceContext`
    /// again — Dispatch callbacks have no task-local context to read from.
    /// Unscoped callers (every other `ProcessExecutor` use) see `nil` here
    /// and pay nothing.
    var agentStudioRestorePerformancePhase: AgentStudioPerformanceTraceRecorder.Event? {
        get {
            self[AgentStudioRestorePerformancePhaseKey.self]
        }
        set {
            self[AgentStudioRestorePerformancePhaseKey.self] = newValue
        }
    }
}

private enum AgentStudioCorrelationIDKey: ServiceContextKey {
    typealias Value = String
    static let nameOverride: String? = "agentstudio-correlation-id"
}

private enum AgentStudioRestorePerformancePhaseKey: ServiceContextKey {
    typealias Value = AgentStudioPerformanceTraceRecorder.Event
    static let nameOverride: String? = "agentstudio-restore-performance-phase"
}

extension AgentStudioPerformanceTraceRecorder {
    /// Scopes `phase` into `ServiceContext.current` for `operation`, so a
    /// nested `DefaultProcessExecutor.execute` call — which captures the
    /// context once at construction, before any Dispatch-queue hop — knows
    /// which restore phase owns its cost. Callers outside this target use
    /// this instead of importing `Tracing` directly: `ServiceContext` stays
    /// an Infrastructure-internal mechanism, not a cross-target contract.
    package static func withRestorePhaseScope<T>(
        _ phase: Event, operation: () async throws -> T
    ) async rethrows -> T {
        var context = ServiceContext.current ?? .topLevel
        context.agentStudioRestorePerformancePhase = phase
        return try await ServiceContext.withValue(context, operation: operation)
    }
}
