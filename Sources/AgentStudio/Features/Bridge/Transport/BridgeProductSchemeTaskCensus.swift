import Foundation
import Synchronization

/// Records whether the transports behind the metadata stream are still live.
///
/// This exists because "a metadata producer lease exists" is not the same fact as
/// "the viewer is still streaming", and until now only the first was recorded. A
/// consumer that stops streaming cancels its reply task from
/// `AsyncThrowingStream.Continuation.onTermination`, which is synchronous and
/// fire-and-forget: the task's retirement state is written several hops later.
/// Between those two moments the lease is registered with no retirement recorded,
/// which is indistinguishable from a genuinely live stream unless the teardown
/// itself is recorded somewhere. That is what this census is for.
///
/// It is a nonisolated lock box rather than actor state because `onTermination`
/// is a synchronous closure and the router that owns it is an actor.
package final class BridgeProductSchemeTaskCensus: Sendable {
    private struct Population {
        var started: Set<UUID> = []
        var terminated: Set<UUID> = []
    }

    private let population = Mutex(Population())
    private let didMarkTerminated: (@Sendable (UUID) async -> Void)?

    /// - Parameter didMarkTerminated: production passes nothing, and then
    ///   `holdsTerminationObserver` is false and the termination path stays
    ///   exactly as synchronous as it is today. A test supplies this to hold the
    ///   window open between the mark and the retirement write, which is
    ///   otherwise too narrow to observe deterministically.
    package init(didMarkTerminated: (@Sendable (UUID) async -> Void)? = nil) {
        self.didMarkTerminated = didMarkTerminated
    }

    /// Whether anyone asked to observe terminations. False in production, which
    /// is what keeps the cancellation path free of an added suspension.
    package var holdsTerminationObserver: Bool { didMarkTerminated != nil }

    func start(_ id: UUID) {
        population.withLock { population in
            _ = population.started.insert(id)
        }
    }

    func markTerminated(_ id: UUID) {
        population.withLock { population in
            guard population.started.contains(id) else { return }
            _ = population.terminated.insert(id)
        }
    }

    func finish(_ id: UUID) {
        population.withLock { population in
            population.started.remove(id)
            population.terminated.remove(id)
        }
    }

    /// True when no started stream task can still produce a frame.
    ///
    /// An EMPTY census reads `true` on purpose. The bootstrap gate consults this
    /// only when a metadata lease exists with no retirement recorded, so an empty
    /// census at that moment means the stream's task has already run `finish`,
    /// i.e. the transport is gone and only the retirement write is outstanding —
    /// the same disposition as "started and terminated".
    var everyStartedStreamTaskTerminated: Bool {
        population.withLock { $0.started.isSubset(of: $0.terminated) }
    }

    func isTerminated(_ id: UUID) -> Bool {
        population.withLock { $0.terminated.contains(id) }
    }

    /// Awaited only when an observer was supplied, so a test can suspend the
    /// reply task's cancellation at exactly the point where the census says
    /// "terminated" and the retirement write has not happened.
    func awaitTerminationObserver(_ id: UUID) async {
        await didMarkTerminated?(id)
    }
}
