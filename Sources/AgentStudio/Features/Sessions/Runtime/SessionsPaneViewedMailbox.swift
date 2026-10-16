import Foundation
import Synchronization

package struct SessionsPaneViewedBatch: Sendable {
    let views: [SessionsPaneViewedOccurrence]
    let retiredPaneIds: [UUID]
}

package struct SessionsPaneViewedOccurrence: Sendable, Equatable {
    package let paneId: UUID
    package let viewedAt: ContinuousClock.Instant
}

/// Focus-success and retirement ingress. MainActor only appends under the mutex;
/// the Sessions consumer makes every ordering and status decision.
package final class SessionsPaneViewedMailbox: Sendable {
    private struct MailboxState {
        var accepting = true
        var views: [SessionsPaneViewedOccurrence] = []
        var retirements: [UUID] = []
    }
    private let state = Mutex(MailboxState())
    package let wakes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    package init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakes = stream.stream
        continuation = stream.continuation
    }

    package func noteViewed(_ paneId: UUID, viewedAt: ContinuousClock.Instant = ContinuousClock.now) {
        state.withLock { if $0.accepting { $0.views.append(.init(paneId: paneId, viewedAt: viewedAt)) } }
        continuation.yield()
    }

    package func retire(_ paneIds: [UUID]) {
        state.withLock { if $0.accepting { $0.retirements.append(contentsOf: paneIds) } }
        continuation.yield()
    }

    func takeBatch() -> SessionsPaneViewedBatch {
        state.withLock {
            let batch = SessionsPaneViewedBatch(views: $0.views, retiredPaneIds: $0.retirements)
            $0.views.removeAll(keepingCapacity: true)
            $0.retirements.removeAll(keepingCapacity: true)
            return batch
        }
    }

    func close() {
        state.withLock { $0.accepting = false }
        continuation.finish()
    }
}
