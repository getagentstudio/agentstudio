import Foundation

extension AgentStudioPerformanceTraceRecorder {
    /// Only synchronous owner work belongs in a slice. Suspensions and executor
    /// queue waits stay outside; main-thread allowances have their own events.
    package static func measureRestoreSlice<Output>(
        _ event: Event, recorder: AgentStudioPerformanceTraceRecorder?, operation: () throws -> Output
    ) rethrows -> Output {
        guard let recorder, recorder.isEnabled else { return try operation() }
        let start = ContinuousClock.now
        let executedOnMainThread = Thread.isMainThread
        defer {
            recorder.recordRestorePhaseDuration(
                event, duration: start.duration(to: .now), executedOnMainThread: executedOnMainThread)
        }
        return try operation()
    }

    package func recordRestorePhaseDuration(_ event: Event, duration: Duration, executedOnMainThread: Bool) {
        recordDuration(
            event, duration: duration,
            attributes: [
                "agentstudio.performance.restore.execution.count": .int(1),
                "agentstudio.performance.restore.main_thread.execution.count": .int(executedOnMainThread ? 1 : 0),
                "agentstudio.performance.restore.main_thread.elapsed_ms": .double(
                    executedOnMainThread ? Self.milliseconds(from: duration) : 0),
            ])
    }
}
