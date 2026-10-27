import AgentStudioInfrastructure
import Foundation
import Synchronization

/// A service-lifetime commit token, independent of persisted and rendered revisions.
package struct PaneContextSourceInvalidation: Equatable, Sendable {
    package let sourcePaneId: PaneId
    package let generation: UInt64
}

package protocol PaneContextInvalidationReading: Sendable {
    func invalidations(for sources: Set<PaneId>) async -> AsyncStream<PaneContextSourceInvalidation>
    func invalidationGenerations(for sources: Set<PaneId>) async -> [PaneId: UInt64]
}

final class PaneContextInvalidationSubscriber: Sendable {
    let sources: Set<PaneId>
    let continuation: AsyncStream<PaneContextSourceInvalidation>.Continuation
    private let ended = Mutex(false)

    init(sources: Set<PaneId>, continuation: AsyncStream<PaneContextSourceInvalidation>.Continuation) {
        self.sources = sources
        self.continuation = continuation
    }
    var isEnded: Bool { ended.withLock { $0 } }
    func didEnd() { ended.withLock { $0 = true } }
}

extension PaneContextService {
    /// Subscribe before capturing tokens and reading detail so no intervening commit is lost.
    package func invalidations(for sources: Set<PaneId>) -> AsyncStream<PaneContextSourceInvalidation> {
        let channel = AsyncStream<PaneContextSourceInvalidation>.makeStream(bufferingPolicy: .unbounded)
        guard !isStopping else {
            channel.continuation.finish()
            return channel.stream
        }
        pruneInvalidationSubscribers()
        let subscriber = PaneContextInvalidationSubscriber(sources: sources, continuation: channel.continuation)
        invalidationSubscribers[UUIDv7.generate()] = subscriber
        channel.continuation.onTermination = { [weak subscriber] _ in subscriber?.didEnd() }
        return channel.stream
    }

    package func invalidationGenerations(for sources: Set<PaneId>) -> [PaneId: UInt64] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0, invalidationGenerationBySource[$0] ?? 0) })
    }

    /// Called immediately after a successful SQL mutation, before any awaited effect.
    func recordInvalidations(_ sources: Set<PaneId>) {
        pruneInvalidationSubscribers()
        for source in sources {
            let generation = (invalidationGenerationBySource[source] ?? 0) &+ 1
            invalidationGenerationBySource[source] = generation
            let change = PaneContextSourceInvalidation(sourcePaneId: source, generation: generation)
            for subscriber in invalidationSubscribers.values where subscriber.sources.contains(source) {
                subscriber.continuation.yield(change)
            }
        }
    }

    private func pruneInvalidationSubscribers() {
        invalidationSubscribers = invalidationSubscribers.filter { !$0.value.isEnded }
    }

    func finishInvalidations() {
        let subscribers = invalidationSubscribers
        invalidationSubscribers.removeAll()
        for subscriber in subscribers.values { subscriber.continuation.finish() }
    }
}
