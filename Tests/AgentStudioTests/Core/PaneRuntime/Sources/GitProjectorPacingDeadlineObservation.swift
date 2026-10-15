import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation

@testable import AgentStudioCore

struct GitProjectorPacingDeadlineObservation {
    let scope: GitProjectorScope
    let scheduledStart: Duration
    let registeredSleep: TestPushClock.Instant
}

/// The caller holds every status computation and keeps virtual time frozen,
/// so no completion or due timer can replace this scope while its sleep arms.
func observeHeldGitProjectorPacingDeadline(
    _ projector: isolated GitWorkingDirectoryProjector,
    scope: GitProjectorScope,
    clock: TestPushClock
) async throws -> GitProjectorPacingDeadlineObservation {
    guard case .deadline(let worktreeId, .governorPacing, _) = scope else {
        throw GitProjectorPacingObservationError.notGovernorScope
    }
    let slot = GitProjectorDeadlineFactSlot(
        worktreeId: worktreeId, sourceKind: GitRefreshDeadlineKind.automatic.rawValue)
    guard projector.deadlineFactScopeBySlot[slot] == scope else {
        throw GitProjectorPacingObservationError.replacedScope
    }
    guard let deadline = projector.automaticRefreshDeadlineByWorktreeId[worktreeId],
        projector.deadlineQueue.first?.deadline == deadline,
        projector.deadlineTask != nil
    else {
        throw GitProjectorPacingObservationError.notArmedAlarm
    }
    let scheduledStart = projector.nextAutomaticStartAt
    let registeredInstant = clock.now.advanced(by: deadline - projector.deadlineClock.now)
    let registeredSleep = await clock.waitForPendingSleep(deadline: registeredInstant)
    return GitProjectorPacingDeadlineObservation(
        scope: scope, scheduledStart: scheduledStart, registeredSleep: registeredSleep)
}

private enum GitProjectorPacingObservationError: Error {
    case notGovernorScope
    case replacedScope
    case notArmedAlarm
}

/// Holds the owner's real sleep before the underlying clock registers it.
struct GitProjectorHeldDeadlineClock: Clock {
    typealias Instant = TestPushClock.Instant
    typealias Duration = Swift.Duration

    let clock: TestPushClock
    let registration: HeldStep<Instant>

    var now: Instant { clock.now }
    var minimumResolution: Duration { clock.minimumResolution }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await registration.arrive(deadline)
        try await clock.sleep(until: deadline, tolerance: tolerance)
    }
}

func armHeldGitProjectorPacingDeadline(
    _ projector: isolated GitWorkingDirectoryProjector, worktreeId: UUID
) {
    projector.nextAutomaticStartAt = .milliseconds(10)
    projector.setRefreshDeadline(
        .milliseconds(11), kind: .automatic, worktreeId: worktreeId, factKind: .governorPacing)
    projector.rescheduleDeadlineTask()
}
