import AgentStudioInfrastructure
import Foundation

/// Mirrors GitRefreshDeadlineClock's origin-relative absolute deadline representation.
struct TerminalActivityDeadlineClock: Sendable {
    private let nowValue: @Sendable () -> Duration
    private let sleepUntilValue: @Sendable (Duration) async throws -> Void

    init(_ clock: (any Clock<Duration> & Sendable)?) {
        if let clock {
            self.init(sourceClock: clock)
        } else {
            let clock = ContinuousClock()
            let origin = clock.now
            self.init(
                nowValue: { origin.duration(to: clock.now) },
                sleepUntilValue: { deadline in
                    // Keep production on the existing nanosecond Task.sleep path;
                    // generic clock sleeps have caused Swift runtime crashes here.
                    let remaining = max(.zero, deadline - origin.duration(to: clock.now))
                    try await Task.sleep(nanoseconds: remaining.nanosecondsForTaskSleep)
                })
        }
    }

    private init(
        nowValue: @escaping @Sendable () -> Duration,
        sleepUntilValue: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.nowValue = nowValue
        self.sleepUntilValue = sleepUntilValue
    }

    private init<SourceClock: Clock & Sendable>(sourceClock: SourceClock)
    where SourceClock.Duration == Duration {
        let origin = sourceClock.now
        nowValue = { origin.duration(to: sourceClock.now) }
        sleepUntilValue = { deadline in
            try await sourceClock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
        }
    }

    var now: Duration { nowValue() }

    func sleep(until deadline: Duration) async throws {
        try await sleepUntilValue(deadline)
    }
}
