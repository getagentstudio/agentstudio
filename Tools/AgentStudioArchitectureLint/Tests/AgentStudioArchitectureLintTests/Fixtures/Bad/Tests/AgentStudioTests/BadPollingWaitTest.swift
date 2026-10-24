import Foundation

struct BadPollingWaitTest {
    func waitsUntilDeadline(condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if condition() {
                return
            }
            await Task.yield()
        }
    }

    func waitsForIterationBudget(condition: () -> Bool) async {
        for _ in 0..<20_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
    }

    func waitsBySleepingOnAClock(clock: any Clock<Duration>, condition: () -> Bool) async throws {
        repeat {
            try await clock.sleep(for: .milliseconds(5))
        } while !condition()
    }

    /// Clock-only: `Date.now` is a wall-clock read even though the type name
    /// does not contain `clock`.
    func waitsUntilDateNowDeadline(condition: () -> Bool) {
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            if condition() {
                return
            }
        }
    }

    /// Clock-only: `.now` on a `ContinuousClock` binding is a wall-clock read
    /// even when the local name does not contain `clock`.
    func waitsUntilBoundClockDeadline(condition: () -> Bool) {
        let ticker = ContinuousClock()
        let deadline = ticker.now.advanced(by: .seconds(10))
        while ticker.now < deadline {
            if condition() {
                return
            }
        }
    }

    func waitsForFixedTurnCount() async {
        for _ in 0..<300 { await Task.yield() }
    }

    func waitsWithTurnBudget(maxTurns: Int, condition: () -> Bool) async {
        for _ in 0..<maxTurns where !condition() {
            await Task.yield()
        }
    }
}
