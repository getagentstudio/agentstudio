import Foundation
import Synchronization

final class PaneContextTestWallDate: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
