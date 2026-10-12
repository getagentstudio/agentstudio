import AgentStudioTestSupport
import Foundation

@testable import AgentStudioCore

struct GitProjectorPacingDeadlineObservation {
    let scheduledStart: Duration
    let registeredSleep: TestPushClock.Instant
}

func observeGitProjectorPacingDeadline(
    _ projector: GitWorkingDirectoryProjector, clock: TestPushClock
) async -> GitProjectorPacingDeadlineObservation {
    let scheduledStart = await projector.nextAutomaticStartAt
    let delay = scheduledStart - (await projector.deadlineClock.now)
    let registeredSleep = await clock.waitForPendingSleep(deadline: clock.now.advanced(by: delay))
    return GitProjectorPacingDeadlineObservation(scheduledStart: scheduledStart, registeredSleep: registeredSleep)
}
