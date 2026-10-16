import AgentStudioInfrastructure
import Foundation
import Synchronization

package enum PaneActivityClockQuiescence: Sendable, Equatable {
    case quiescent
    case shutDown
}

/// Orders both activity sources before one thin, acknowledged MainActor publication.
package actor PaneActivityClock {
    private struct MailboxBatch: Sendable {
        let occurrences: [UUID: PaneActivityOccurrence]
        let retirements: [UUID]

        var isEmpty: Bool {
            occurrences.isEmpty && retirements.isEmpty
        }
    }

    private struct Mailbox: Sendable {
        var accepting = true
        var occurrences: [UUID: PaneActivityOccurrence] = [:]
        var retirements: [UUID] = []

        mutating func take() -> MailboxBatch {
            let batch = MailboxBatch(occurrences: occurrences, retirements: retirements)
            occurrences.removeAll(keepingCapacity: true)
            retirements.removeAll(keepingCapacity: true)
            return batch
        }

        var isEmpty: Bool {
            occurrences.isEmpty && retirements.isEmpty
        }
    }

    private struct PendingPublication: Sendable {
        let occurrence: PaneActivityOccurrence
        let eligibleAt: ContinuousClock.Instant
    }

    nonisolated private let mailbox = Mutex(Mailbox())
    nonisolated private let wakeContinuation: AsyncStream<Void>.Continuation
    private let wakeStream: AsyncStream<Void>
    private let publishInterval: Duration
    private let delay: AsyncDelay
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let sink: @MainActor @Sendable ([PaneActivityTimeMutation]) async -> Void
    nonisolated private let submissionObserver: @Sendable (PaneActivityOccurrence) -> Void

    private var drainTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration = 0
    private var lastAdmittedByPaneId: [UUID: ContinuousClock.Instant] = [:]
    private var lastPublishedByPaneId: [UUID: ContinuousClock.Instant] = [:]
    private var pendingByPaneId: [UUID: PendingPublication] = [:]
    private var retiredPaneIds: Set<UUID> = []
    private var settledWaiters: [UUID: CheckedContinuation<PaneActivityClockQuiescence, Error>] = [:]
    private var settledRegistrationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var isApplying = false
    private var isShutDown = false

    package init(
        publishInterval: Duration = AppPolicies.Panes.activityTimePublishInterval,
        clock: (any Clock<Duration> & Sendable)? = nil,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        submissionObserver: @escaping @Sendable (PaneActivityOccurrence) -> Void = { _ in },
        sink: @escaping @MainActor @Sendable ([PaneActivityTimeMutation]) async -> Void
    ) {
        let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeStream = wake.stream
        wakeContinuation = wake.continuation
        self.publishInterval = publishInterval
        delay = clock.map(AsyncDelay.clock) ?? .taskSleep
        self.monotonicNow = monotonicNow
        self.sink = sink
        self.submissionObserver = submissionObserver
    }

    /// The caller never awaits the clock actor or a MainActor sink.
    nonisolated package func submit(_ occurrence: PaneActivityOccurrence) {
        submissionObserver(occurrence)
        let accepted = mailbox.withLock { state in
            guard state.accepting else { return false }
            if let existing = state.occurrences[occurrence.paneId],
                existing.orderingInstant >= occurrence.orderingInstant
            {
                return false
            }
            state.occurrences[occurrence.paneId] = occurrence
            return true
        }
        if accepted { wakeContinuation.yield() }
    }

    /// Retirement shares ingress with occurrences so an older pending set cannot pass a remove.
    nonisolated package func retire(_ paneIds: [UUID]) {
        let accepted = mailbox.withLock { state in
            guard state.accepting else { return false }
            state.retirements.append(contentsOf: paneIds)
            return !paneIds.isEmpty
        }
        if accepted { wakeContinuation.yield() }
    }

    package func start() {
        guard drainTask == nil, !isShutDown else { return }
        drainTask = Task { await drainLoop() }
    }

    package func pendingDeadline() -> Bool {
        !pendingByPaneId.isEmpty
    }

    /// Read-only observation for proof: waits until settled() has registered the requested waiters.
    /// Available in all builds, not DEBUG-gated. It does not affect admission, publication, or
    /// the clock's quiescence decision.
    func waitForSettledWaiterCount(_ count: Int) async {
        guard settledWaiters.count < count, !isShutDown else { return }
        await withCheckedContinuation { continuation in
            settledRegistrationWaiters.append((count, continuation))
        }
    }

    package func settled() async throws -> PaneActivityClockQuiescence {
        if isShutDown { return .shutDown }
        start()
        if isQuiescent { return .quiescent }
        let waiterId = UUIDv7.generate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isShutDown {
                    continuation.resume(returning: .shutDown)
                } else if isQuiescent {
                    continuation.resume(returning: .quiescent)
                } else {
                    settledWaiters[waiterId] = continuation
                    resumeSettledRegistrationWaiters()
                }
            }
        } onCancel: {
            Task { await self.cancelSettledWaiter(waiterId) }
        }
    }

    package func shutdown() async {
        guard !isShutDown else {
            await drainTask?.value
            return
        }
        isShutDown = true
        mailbox.withLock { state in
            state.accepting = false
            _ = state.take()
        }
        deadlineTask?.cancel()
        deadlineTask = nil
        pendingByPaneId.removeAll()
        for waiter in settledWaiters.values {
            waiter.resume(returning: .shutDown)
        }
        settledWaiters.removeAll()
        for (_, waiter) in settledRegistrationWaiters { waiter.resume() }
        settledRegistrationWaiters.removeAll()
        wakeContinuation.finish()
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
    }

    private var isQuiescent: Bool {
        !isApplying && pendingByPaneId.isEmpty && mailbox.withLock { $0.isEmpty }
    }

    private func drainLoop() async {
        for await _ in wakeStream {
            if isShutDown { break }
            await drainMailbox()
        }
    }

    private func drainMailbox() async {
        while !isShutDown {
            let input = mailbox.withLock { $0.take() }
            var changes: [PaneActivityTimeMutation] = []
            for paneId in input.retirements where retiredPaneIds.insert(paneId).inserted {
                pendingByPaneId.removeValue(forKey: paneId)
                lastAdmittedByPaneId.removeValue(forKey: paneId)
                lastPublishedByPaneId.removeValue(forKey: paneId)
                changes.append(.remove(paneId))
            }
            for occurrence in input.occurrences.values {
                guard !retiredPaneIds.contains(occurrence.paneId) else { continue }
                if let latest = lastAdmittedByPaneId[occurrence.paneId],
                    occurrence.orderingInstant <= latest
                {
                    continue
                }
                lastAdmittedByPaneId[occurrence.paneId] = occurrence.orderingInstant
                if let lastPublished = lastPublishedByPaneId[occurrence.paneId],
                    occurrence.orderingInstant < lastPublished.advanced(by: publishInterval)
                {
                    pendingByPaneId[occurrence.paneId] = PendingPublication(
                        occurrence: occurrence,
                        eligibleAt: lastPublished.advanced(by: publishInterval)
                    )
                } else {
                    pendingByPaneId.removeValue(forKey: occurrence.paneId)
                    lastPublishedByPaneId[occurrence.paneId] = monotonicNow()
                    changes.append(.set(occurrence.paneId, occurrence.activityTime))
                }
            }
            let now = monotonicNow()
            let duePublications = pendingByPaneId.filter { $0.value.eligibleAt <= now }
            for (paneId, pending) in duePublications {
                pendingByPaneId.removeValue(forKey: paneId)
                lastPublishedByPaneId[paneId] = now
                changes.append(.set(paneId, pending.occurrence.activityTime))
            }
            if input.isEmpty && changes.isEmpty { break }
            if !changes.isEmpty {
                isApplying = true
                await sink(changes)
                isApplying = false
            }
        }
        scheduleDeadline()
        resumeSettledWaitersIfQuiescent()
    }

    private func scheduleDeadline() {
        deadlineGeneration += 1
        let generation = deadlineGeneration
        deadlineTask?.cancel()
        deadlineTask = nil
        guard !isShutDown, let earliest = pendingByPaneId.values.map(\.eligibleAt).min() else {
            return
        }
        let remaining = max(.zero, monotonicNow().duration(to: earliest))
        let delay = delay
        deadlineTask = Task { [weak self] in
            do {
                try await delay.wait(remaining)
                await self?.deadlineElapsed(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func deadlineElapsed(generation: Int) async {
        guard generation == deadlineGeneration, !isShutDown else { return }
        deadlineTask = nil
        wakeContinuation.yield()
    }

    private func resumeSettledWaitersIfQuiescent() {
        guard isQuiescent else { return }
        for waiter in settledWaiters.values {
            waiter.resume(returning: .quiescent)
        }
        settledWaiters.removeAll()
    }

    private func cancelSettledWaiter(_ waiterId: UUID) {
        settledWaiters.removeValue(forKey: waiterId)?.resume(throwing: CancellationError())
    }

    private func resumeSettledRegistrationWaiters() {
        let ready = settledRegistrationWaiters.filter { $0.0 <= settledWaiters.count }
        settledRegistrationWaiters.removeAll { $0.0 <= settledWaiters.count }
        for (_, waiter) in ready { waiter.resume() }
    }
}
