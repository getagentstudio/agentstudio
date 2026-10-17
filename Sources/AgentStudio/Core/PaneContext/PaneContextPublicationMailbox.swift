import Synchronization

package enum PaneContextPublication: Sendable, Equatable {
    case set(PaneContextDisplay)
    case remove
}

package struct PaneContextPublicationCounts: Sendable, Equatable {
    package let computed: Int
    package let suppressed: Int
    package let coalesced: Int
}

/// Equality is against the desired value, including values still in flight.
package final class PaneContextPublicationMailbox: Sendable {
    private struct MailboxState {
        var accepting = true
        var pending: [PaneId: PaneContextPublication] = [:]
        var desired: [PaneId: PaneContextDisplay] = [:]
        var retired = Set<PaneId>()
        var computed = 0
        var suppressed = 0
        var coalesced = 0

        mutating func offer(_ display: PaneContextDisplay, for paneId: PaneId) -> Bool {
            guard accepting, !retired.contains(paneId) else { return false }
            computed += 1
            guard desired[paneId] != display else {
                suppressed += 1
                return false
            }
            desired[paneId] = display
            if pending[paneId] != nil { coalesced += 1 }
            pending[paneId] = .set(display)
            return true
        }

        mutating func retire(_ paneId: PaneId) -> Bool {
            guard accepting, retired.insert(paneId).inserted else { return false }
            remove(paneId)
            return true
        }

        @discardableResult
        mutating func remove(_ paneId: PaneId) -> Bool {
            guard accepting else { return false }
            desired.removeValue(forKey: paneId)
            pending[paneId] = .remove
            return true
        }
    }

    private let state = Mutex(MailboxState())
    package let wakes: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private let isPresent: @Sendable (PaneId) -> Bool

    package init(isPresent: @escaping @Sendable (PaneId) -> Bool) {
        self.isPresent = isPresent
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakes = channel.stream
        wakeContinuation = channel.continuation
    }

    @discardableResult
    package func offer(_ display: PaneContextDisplay, for paneId: PaneId) -> Bool {
        let accepted = state.withLock { mailbox in
            guard isPresent(paneId) else { return false }
            return mailbox.offer(display, for: paneId)
        }
        if accepted { wakeContinuation.yield(()) }
        return accepted
    }

    package func retire(_ paneId: PaneId) {
        let accepted = state.withLock { $0.retire(paneId) }
        if accepted { wakeContinuation.yield(()) }
    }

    func removeAbsent(_ paneId: PaneId) {
        let accepted = state.withLock { mailbox in
            guard !isPresent(paneId) else { return false }
            return mailbox.remove(paneId)
        }
        if accepted { wakeContinuation.yield(()) }
    }

    package func reconcile(_ displays: [PaneId: PaneContextDisplay]) {
        let accepted = state.withLock { mailbox in
            let liveDisplays = displays.filter { isPresent($0.key) }
            var changed = false
            let missing = Set(mailbox.desired.keys).subtracting(liveDisplays.keys)
            for paneId in missing { changed = mailbox.remove(paneId) || changed }
            for (paneId, display) in liveDisplays { changed = mailbox.offer(display, for: paneId) || changed }
            return changed
        }
        if accepted { wakeContinuation.yield(()) }
    }

    package func takeBatch() -> [PaneId: PaneContextPublication] {
        state.withLock { mailbox in
            defer { mailbox.pending.removeAll(keepingCapacity: true) }
            return mailbox.pending
        }
    }

    package func counts() -> PaneContextPublicationCounts {
        state.withLock { .init(computed: $0.computed, suppressed: $0.suppressed, coalesced: $0.coalesced) }
    }

    func desiredDisplay(for paneId: PaneId) -> PaneContextDisplay? {
        state.withLock { $0.desired[paneId] }
    }

    package func close() {
        state.withLock {
            $0.accepting = false
            $0.pending.removeAll()
        }
        wakeContinuation.finish()
    }
}

package actor PaneContextPublicationLane {
    package nonisolated let mailbox: PaneContextPublicationMailbox
    private let sink: @MainActor @Sendable ([PaneId: PaneContextPublication]) async -> Void
    private var wakeDrain: Task<Void, Never>?
    private var applying: Task<Void, Never>?
    private var isClosed = false
    private let measurement: PaneContextPresentationApplyMeasurement
    private let probe: @Sendable (PaneContextPresentationApplySnapshot) -> Void
    private var totalHeld: Duration = .zero
    private var maximumHeld: Duration = .zero

    package init(
        mailbox: PaneContextPublicationMailbox,
        sink: @escaping @MainActor @Sendable ([PaneId: PaneContextPublication]) async -> Void,
        measurement: PaneContextPresentationApplyMeasurement = .init(),
        probe: @escaping @Sendable (PaneContextPresentationApplySnapshot) -> Void = { _ in }
    ) {
        self.mailbox = mailbox
        self.sink = sink
        self.measurement = measurement
        self.probe = probe
    }

    package func start() {
        guard wakeDrain == nil, !isClosed else { return }
        wakeDrain = Task {
            for await _ in mailbox.wakes {
                guard !isClosed, !Task.isCancelled else { return }
                await publishPending()
            }
        }
    }

    package func publishPending() async {
        guard !isClosed else { return }
        if let applying {
            await applying.value
            return
        }
        let task = Task { await drainMailbox() }
        applying = task
        await task.value
    }

    private func drainMailbox() async {
        defer { applying = nil }
        while !isClosed, !Task.isCancelled {
            let batch = mailbox.takeBatch()
            guard !batch.isEmpty else { return }
            await sink(batch)
            let held = measurement.takeHeldDuration()
            totalHeld += held
            maximumHeld = max(maximumHeld, held)
            probe(
                .init(
                    counts: mailbox.counts(), batchSize: batch.count, heldDuration: held,
                    totalHeldDuration: totalHeld, maximumHeldDuration: maximumHeld))
        }
    }

    package func shutdown() async {
        guard !isClosed else {
            await applying?.value
            return
        }
        isClosed = true
        mailbox.close()
        wakeDrain?.cancel()
        applying?.cancel()
        await wakeDrain?.value
        await applying?.value
        wakeDrain = nil
    }
}
