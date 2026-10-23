import AgentStudioInfrastructure
import Foundation

extension PaneCLIOutboxDrain {
    /// Always read once for warm panes. Cold readiness bounds subsequent retries,
    /// and its earlier immutable decision is never changed by a late read.
    func drainForLaunch<ReadinessClock: Clock<Duration>>(
        storeURL: URL, readiness: RestoreResumeReadiness<ReadinessClock>, clock: ReadinessClock,
        reportSink: (@Sendable (DrainReport) -> Void)? = nil
    ) async {
        await readiness.beginRead()
        while !Task.isCancelled {
            let report = await drain(storeURL: storeURL)
            reportSink?(report)
            guard !Task.isCancelled else { break }
            await readiness.record(report.readOutcome)
            guard case .incomplete = report.readOutcome, await readiness.isPending else { return }
            let retryAt = clock.now.advanced(by: AppPolicies.Restore.closedAppReadRetryDelay)
            do { try await clock.sleep(until: retryAt, tolerance: nil) } catch { break }
        }
        await readiness.record(.unreadable(.cancelled))
    }
}
