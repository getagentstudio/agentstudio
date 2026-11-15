import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation

enum RepoExplorerMessageDeadlineClockFact: Equatable, Sendable {
    case requested(Duration)
    case registered(TestPushClock.Instant)
    case ended(cancelled: Bool)
    case retired
}

/// One logical clock drives both captured references and the actual deadline sleep.
final class RepoExplorerMessageDeadlineTestClock: Sendable {
    let facts: FactRecorder<Int, RepoExplorerMessageDeadlineClockFact>
    let controlled: TestPushClock
    let origin: TestPushClock.Instant
    private let continuousOrigin: ContinuousClock.Instant
    private let wallOrigin: Date

    init(wallNow: Date) {
        let facts = FactRecorder<Int, RepoExplorerMessageDeadlineClockFact>(
            vocabulary: .init(
                describeScope: { "sidebar deadline clock \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .retired }))
        let controlled = TestPushClock(pendingSleepFactSink: { event in
            if case .registrationSettled(let deadline, _) = event {
                facts.append(scope: 0, fact: .registered(deadline))
            }
        })
        self.facts = facts
        self.controlled = controlled
        origin = controlled.now
        continuousOrigin = ContinuousClock.now
        wallOrigin = wallNow
    }

    var continuousNow: ContinuousClock.Instant {
        continuousOrigin.advanced(by: origin.duration(to: controlled.now))
    }

    var wallNow: Date {
        let elapsed = origin.duration(to: controlled.now).components
        return wallOrigin.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    var delay: AsyncDelay {
        AsyncDelay { [self] duration in
            facts.append(scope: 0, fact: .requested(duration))
            do {
                try await controlled.sleep(for: duration)
                facts.append(scope: 0, fact: .ended(cancelled: false))
            } catch {
                facts.append(scope: 0, fact: .ended(cancelled: true))
                throw error
            }
        }
    }

    func expectRegistration(after delay: Duration, at elapsed: Duration) async throws {
        try await facts.expectNext(in: 0, .requested(delay))
        // A cancelled/erroring producer emits ended instead, so this wait fails
        // immediately for that outcome rather than waiting only for success.
        try await facts.expectNext(in: 0, .registered(origin.advanced(by: elapsed)))
    }
}
