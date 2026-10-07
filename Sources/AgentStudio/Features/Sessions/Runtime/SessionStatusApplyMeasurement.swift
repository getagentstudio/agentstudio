import Synchronization

/// The sink captures only its synchronous assignment time. Awaiting MainActor
/// and unrelated suspension time never enter this value.
package final class SessionStatusApplyMeasurement: Sendable {
    private let heldDuration = Mutex<Duration>(.zero)
    package init() {}
    package func recordHeldDuration(_ duration: Duration) { heldDuration.withLock { $0 = duration } }
    func takeHeldDuration() -> Duration { heldDuration.withLock { $0 } }
}

package struct SessionStatusApplySnapshot: Sendable {
    package let counts: SessionStatusPublicationCounts
    package let batchSize: Int
    package let heldDuration: Duration
    package let totalHeldDuration: Duration
    package let maximumHeldDuration: Duration
}
