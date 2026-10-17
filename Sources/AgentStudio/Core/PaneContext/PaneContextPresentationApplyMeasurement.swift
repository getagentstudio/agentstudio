import Synchronization

/// The sink reports assignment occupancy, excluding executor wait or suspension.
package final class PaneContextPresentationApplyMeasurement: Sendable {
    private let heldDuration = Mutex<Duration>(.zero)

    package init() {}

    package func recordHeldDuration(_ duration: Duration) { heldDuration.withLock { $0 = duration } }

    func takeHeldDuration() -> Duration { heldDuration.withLock { $0 } }
}

package struct PaneContextPresentationApplySnapshot: Sendable {
    package let counts: PaneContextPublicationCounts
    package let batchSize: Int
    package let heldDuration: Duration
    package let totalHeldDuration: Duration
    package let maximumHeldDuration: Duration
}
