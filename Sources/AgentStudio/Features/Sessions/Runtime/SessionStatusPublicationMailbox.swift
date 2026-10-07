import AgentStudioCore
import Foundation
import Synchronization

package enum SessionStatusPublication: Sendable, Equatable {
    case set(AgentSessionStatus)
    case remove
}

/// Latest desired values, including removals, survive an in-flight sink call.
package final class SessionStatusPublicationMailbox: Sendable {
    private struct MailboxState {
        var accepting = true
        var pending: [PaneId: SessionStatusPublication] = [:]
        var lastDesired: [PaneId: AgentSessionStatus] = [:]
        var retired: Set<PaneId> = []
        var computed = 0
        var suppressed = 0
        var coalesced = 0
    }
    private let state = Mutex(MailboxState())
    package let wakes: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    package init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakes = stream.stream
        wakeContinuation = stream.continuation
    }

    @discardableResult
    package func offer(_ status: AgentSessionStatus, for paneId: PaneId) -> Bool {
        let accepted = state.withLock { mailbox in
            guard mailbox.accepting, !mailbox.retired.contains(paneId) else { return false }
            mailbox.computed += 1
            guard mailbox.lastDesired[paneId] != status else {
                mailbox.suppressed += 1
                return false
            }
            mailbox.lastDesired[paneId] = status
            if mailbox.pending[paneId] != nil { mailbox.coalesced += 1 }
            mailbox.pending[paneId] = .set(status)
            return true
        }
        if accepted { wakeContinuation.yield() }
        return accepted
    }

    package func retire(_ paneId: PaneId) {
        let accepted = state.withLock { mailbox in
            guard mailbox.accepting, mailbox.retired.insert(paneId).inserted else { return false }
            mailbox.lastDesired.removeValue(forKey: paneId)
            mailbox.pending[paneId] = .remove
            return true
        }
        if accepted { wakeContinuation.yield() }
    }

    package func takeBatch() -> [PaneId: SessionStatusPublication] {
        state.withLock { mailbox in
            defer { mailbox.pending.removeAll(keepingCapacity: true) }
            return mailbox.pending
        }
    }

    package func close() {
        state.withLock {
            $0.accepting = false
            $0.pending.removeAll()
        }
        wakeContinuation.finish()
    }

    package func counts() -> SessionStatusPublicationCounts {
        state.withLock { .init(computed: $0.computed, suppressed: $0.suppressed, coalesced: $0.coalesced) }
    }
}

package struct SessionStatusPublicationCounts: Sendable {
    package let computed: Int
    package let suppressed: Int
    package let coalesced: Int
}

package actor SessionStatusPublicationLane {
    package nonisolated let mailbox: SessionStatusPublicationMailbox
    private let sink: @MainActor @Sendable ([PaneId: SessionStatusPublication]) async -> Void
    private var drainTask: Task<Void, Never>?
    private var isApplying = false
    private var isClosed = false
    private let measurement: SessionStatusApplyMeasurement
    private let probe: @Sendable (SessionStatusApplySnapshot) -> Void
    private var totalHeld: Duration = .zero
    private var maximumHeld: Duration = .zero

    package init(
        mailbox: SessionStatusPublicationMailbox,
        sink: @escaping @MainActor @Sendable ([PaneId: SessionStatusPublication]) async -> Void,
        measurement: SessionStatusApplyMeasurement = .init(),
        probe: @escaping @Sendable (SessionStatusApplySnapshot) -> Void = { _ in }
    ) {
        self.mailbox = mailbox
        self.sink = sink
        self.measurement = measurement
        self.probe = probe
    }

    package func publishPending() async {
        guard !isApplying, !isClosed else { return }
        isApplying = true
        defer { isApplying = false }
        while !isClosed {
            let batch = mailbox.takeBatch()
            guard !batch.isEmpty else { break }
            await sink(batch)
            let held = measurement.takeHeldDuration()
            totalHeld += held
            maximumHeld = max(maximumHeld, held)
            probe(
                .init(
                    counts: mailbox.counts(), batchSize: batch.count, heldDuration: held, totalHeldDuration: totalHeld,
                    maximumHeldDuration: maximumHeld))
        }
    }

    package func start() {
        guard drainTask == nil, !isClosed else { return }
        drainTask = Task {
            for await _ in mailbox.wakes {
                if isClosed { break }
                await publishPending()
            }
        }
    }

    package func shutdown() async {
        isClosed = true
        mailbox.close()
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
    }
}
