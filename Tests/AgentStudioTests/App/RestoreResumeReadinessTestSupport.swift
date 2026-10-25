import AgentStudioInfrastructure
import Testing

@testable import AgentStudio

/// The startup operation's return closes the wait on both success and failure.
/// An unfixed publisher fails immediately, then cancels and joins its waiter.
@MainActor
func withPendingColdReadinessWait(
    _ appDelegate: AppDelegate, operation: @MainActor () async throws -> Void
) async throws {
    let readiness = appDelegate.restoreResumeReadiness
    let waiter = Task { await readiness.wait(paneId: UUIDv7.generate()) }
    do {
        try await operation()
        let missingOutcome = await readiness.isPending
        #expect(!missingOutcome, "startup exited without publishing a cold-readiness result")
        if missingOutcome { waiter.cancel() }
        #expect(await waiter.value == .unavailable)
        await readiness.shutdown()
    } catch {
        waiter.cancel()
        await readiness.shutdown()
        _ = await waiter.value
        throw error
    }
}
