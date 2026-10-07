import Foundation
import Synchronization

package final class PaneContextTestTime: Sendable {
    private let clock: TestPushClock
    private let origin: TestPushClock.Instant
    private let offset = Mutex<TimeInterval>(0)

    package init(clock: TestPushClock) {
        self.clock = clock
        origin = clock.now
    }

    package var now: Date {
        let elapsed = origin.duration(to: clock.now).components
        return Date(timeIntervalSince1970: 1_800_000_000 + Double(elapsed.seconds) + offset.withLock { $0 })
    }

    package func shiftWallTime(by seconds: TimeInterval) {
        offset.withLock { $0 += seconds }
    }
}
