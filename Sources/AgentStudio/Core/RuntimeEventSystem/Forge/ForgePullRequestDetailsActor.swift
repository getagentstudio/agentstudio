import AgentStudioInfrastructure
import Foundation

package actor ForgePullRequestDetailsActor {
    private struct ReadBatch {
        let identities: Set<ForgePullRequestIdentity>
        let startedAt: Duration
    }
    private enum Outcome: String {
        case inputChanged, inputEqual, noDemand, freshDeferred, coalesced, admitted
        case executionStarted, executionCompleted, executionFailed, published, equalSuppressed
        case deadlineScheduled, deadlineFired, deadlineCancelled, cancelled
    }

    // One PaneContextService consumes every health transition; shutdown closes the stream.
    package nonisolated let updates: AsyncStream<ForgePullRequestDetailsUpdate>
    private let continuation: AsyncStream<ForgePullRequestDetailsUpdate>.Continuation
    private let provider: any ForgePullRequestDetailsProviding
    private let clock: GitRefreshDeadlineClock
    private let wallNow: @Sendable () -> Date
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    private let wakes: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private var entries: [ForgePullRequestIdentity: ForgePullRequestDetailsEntry] = [:]
    private var demand: Set<ForgePullRequestIdentity> = []
    private var nextEligible: [ForgePullRequestIdentity: Duration] = [:]
    private var activeBatch: ReadBatch?
    private var worker: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration: UInt64 = 0
    private var isStopping = false
    private var shutdownTask: Task<Void, Never>?

    package init(
        provider: any ForgePullRequestDetailsProviding, clock: any Clock<Duration> & Sendable = ContinuousClock(),
        wallNow: @escaping @Sendable () -> Date = { Date() },
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        let channel = AsyncStream<ForgePullRequestDetailsUpdate>.makeStream(bufferingPolicy: .unbounded)
        updates = channel.stream
        continuation = channel.continuation
        self.provider = provider
        self.clock = erasePullRequestDetailsClock(clock)
        self.wallNow = wallNow
        self.performanceTraceRecorder = performanceTraceRecorder
        let hints = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakes = hints.stream
        wake = hints.continuation
    }

    package func setDemand(identities: Set<ForgePullRequestIdentity>) async {
        guard !isStopping else { return }
        record(identities == demand ? .inputEqual : .inputChanged, count: identities.count)
        demand = identities
        if worker == nil, !demand.isEmpty {
            worker = Task { [weak self] in await self?.runRequests() }
        }
        prepareBatch()
        await rescheduleDeadline()
        wake.yield(())
    }

    package func snapshot() -> [ForgePullRequestIdentity: ForgePullRequestDetailsEntry] { entries }

    private func prepareBatch() {
        guard !isStopping else { return }
        guard activeBatch == nil else {
            record(.coalesced, count: demand.count)
            return
        }
        guard !demand.isEmpty else {
            record(.noDemand, count: 0)
            return
        }
        let now = clock.now
        let eligible = demand.filter { nextEligible[$0].map { $0 <= now } ?? true }.sorted {
            if $0.host != $1.host { return $0.host < $1.host }
            if $0.owner != $1.owner { return $0.owner < $1.owner }
            if $0.repository != $1.repository { return $0.repository < $1.repository }
            return $0.number < $1.number
        }
        guard !eligible.isEmpty else {
            record(.freshDeferred, count: demand.count)
            return
        }
        let identities = Set(eligible.prefix(AppPolicies.ForgeRefresh.maximumBranchAliasesPerBatch))
        activeBatch = .init(identities: identities, startedAt: now)
        for identity in identities { publish(.refreshing(previous: entries[identity]?.lastGood), for: identity) }
        record(.admitted, count: identities.count)
    }

    private func runRequests() async {
        for await _ in wakes {
            guard !isStopping, !Task.isCancelled else { return }
            while let batch = activeBatch {
                record(.executionStarted, count: batch.identities.count)
                let result = await provider.pullRequestDetails(identities: batch.identities)
                guard !isStopping, !Task.isCancelled else { return }
                completeBatch(batch, results: result)
                // Re-admit each next batch against current demand, including after a hide.
                await rescheduleDeadline()
                prepareBatch()
            }
        }
    }

    private func completeBatch(
        _ batch: ReadBatch, results: [ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]
    ) {
        activeBatch = nil
        let now = clock.now
        let readAt = wallNow()
        var failures = 0
        for identity in batch.identities {
            switch results[identity] ?? .failed(.failed) {
            case .loaded(let details):
                nextEligible[identity] = now + AppPolicies.Forge.automaticRefreshMinimumInterval
                publish(.fresh(.init(details: details, readAt: readAt)), for: identity)
            case .failed(let failure):
                failures += 1
                let delay: Duration
                switch failure {
                case .rateLimited(let seconds):
                    delay = max(AppPolicies.ForgeRefresh.automaticFailureRetryFloor, .seconds(max(0, seconds ?? 0)))
                case .noAccess, .notFound, .offline, .failed:
                    delay = AppPolicies.ForgeRefresh.automaticFailureRetryFloor
                }
                nextEligible[identity] = now + delay
                publish(.failed(reason: failure.reason, previous: entries[identity]?.lastGood), for: identity)
            }
        }
        record(
            failures == 0 ? .executionCompleted : .executionFailed, count: batch.identities.count,
            duration: now - batch.startedAt)
    }

    private func publish(_ entry: ForgePullRequestDetailsEntry, for identity: ForgePullRequestIdentity) {
        guard entries[identity] != entry else {
            record(.equalSuppressed, count: 1)
            return
        }
        entries[identity] = entry
        continuation.yield(.init(identity: identity, entry: entry))
        record(.published, count: 1)
    }

    private func rescheduleDeadline() async {
        deadlineGeneration &+= 1
        let generation = deadlineGeneration
        let previous = deadlineTask
        deadlineTask = nil
        previous?.cancel()
        await previous?.value
        if previous != nil { record(.deadlineCancelled, count: 1) }
        guard !isStopping, generation == deadlineGeneration, activeBatch == nil,
            let deadline = demand.map({ nextEligible[$0] ?? clock.now }).min()
        else { return }
        let clock = self.clock
        deadlineTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.deadlineReached(generation: generation)
        }
        record(.deadlineScheduled, count: 1)
    }

    private func deadlineReached(generation: UInt64) {
        guard !isStopping, generation == deadlineGeneration else { return }
        deadlineTask = nil
        record(.deadlineFired, count: 1)
        prepareBatch()
        wake.yield(())
    }

    private func record(_ outcome: Outcome, count: Int, duration: Duration? = nil) {
        guard let performanceTraceRecorder else { return }
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.forge_details.outcome": .string(outcome.rawValue),
            "agentstudio.performance.forge_details.count": .int(count),
        ]
        if let duration {
            attributes["agentstudio.performance.elapsed_ms"] = .double(
                AgentStudioPerformanceTraceRecorder.milliseconds(from: duration))
        }
        performanceTraceRecorder.record(.forgePullRequestDetails, attributes: attributes)
    }

    package func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isStopping = true
        record(.cancelled, count: activeBatch?.identities.count ?? 0)
        wake.finish()
        let worker = self.worker
        let deadline = deadlineTask
        if deadline != nil { record(.deadlineCancelled, count: 1) }
        worker?.cancel()
        deadline?.cancel()
        let continuation = self.continuation
        let task = Task {
            await deadline?.value
            await worker?.value
            continuation.finish()
        }
        shutdownTask = task
        await task.value
        self.worker = nil
        deadlineTask = nil
        activeBatch = nil
    }
}

private func erasePullRequestDetailsClock<SourceClock: Clock & Sendable>(_ clock: SourceClock)
    -> GitRefreshDeadlineClock
where SourceClock.Duration == Duration { GitRefreshDeadlineClock(clock) }
