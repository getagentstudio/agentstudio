import AgentStudioInfrastructure
import Foundation
import os

/// App-wide filesystem ingress actor keyed by worktree registration.
///
/// The actor owns filesystem path ingestion, deepest-root ownership routing for nested roots,
/// priority-aware flush ordering, and envelope emission onto `EventBus`.
package actor FilesystemActor {
    static let logger = Logger(subsystem: "com.agentstudio", category: "FilesystemActor")
    static let maxPathsPerFilesChangedEvent = 256

    struct SchedulingClock: Sendable {
        let now: @Sendable () -> Duration
        let sleep: @Sendable (Duration) async throws -> Void

        static func continuous() -> Self {
            let clock = ContinuousClock()
            let origin = clock.now
            return Self(
                now: { origin.duration(to: clock.now) },
                sleep: { duration in
                    try await AsyncDelay.taskSleep.wait(duration)
                }
            )
        }

        static func make<C: Clock>(clock: C) -> Self where C.Duration == Duration, C: Sendable {
            let origin = clock.now
            let delay = AsyncDelay.clock(clock)
            return Self(
                now: { origin.duration(to: clock.now) },
                sleep: { duration in
                    try await delay.wait(duration)
                }
            )
        }
    }

    struct RootState: Sendable {
        let repoId: UUID
        let rootPath: URL
        let canonicalRootPath: String
        var isActiveInApp: Bool
        var nextBatchSeq: UInt64
        var pathFilter: FilesystemPathFilter
    }

    struct PendingWorktreeChanges: Sendable {
        var projectedPaths: Set<String> = []
        var containsGitInternalChanges = false
        var suppressedIgnoredPathCount = 0
        var suppressedGitInternalPathCount = 0
        var firstPendingTimestamp: Duration?
        var lastPendingTimestamp: Duration?

        var hasPendingChanges: Bool {
            !projectedPaths.isEmpty
                || containsGitInternalChanges
                || suppressedGitInternalPathCount > 0
        }

        mutating func recordPendingChange(at timestamp: Duration) {
            if firstPendingTimestamp == nil {
                firstPendingTimestamp = timestamp
            }
            lastPendingTimestamp = timestamp
        }
    }

    let runtimeBus: EventBus<RuntimeEnvelope>
    let fseventStreamClient: any FSEventStreamClient
    let repositoryLocalActivityProjector: RepositoryLocalActivityProjector?
    let envelopeClock = ContinuousClock()
    let schedulingClock: SchedulingClock
    let watchedFolderScanScheduler: WatchedFolderScanScheduler
    let watchedFolderScanSubmission: WatchedFolderScanSubmissionPort
    let debounceWindow: Duration
    let maxFlushLatency: Duration
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    var roots: [UUID: RootState] = [:]
    var repositoryStableKeysByWorktreeId: [UUID: String] = [:]
    var rootOwnership = FilesystemRootOwnership(canonicalRootsByWorktree: [:])
    var rootOwnershipRevision: UInt64 = 0
    var pendingChangesByWorktreeId: [UUID: PendingWorktreeChanges] = [:]
    var pendingActivityCheckpoint = FilesystemPendingActivityCheckpoint()
    var activityCheckpointRevision: UInt64 = 0
    var pendingCoarseActivityCoverageLossRepositoryStableKeys: Set<String> = []
    private var activePaneWorktreeId: UUID?
    var nextEnvelopeSequence: UInt64 = 0

    var watchedFolderScanState = FilesystemWatchedFolderScanState()

    private var ingressTask: Task<Void, Never>?
    private let ingressTerminalStream: AsyncStream<FSEventStreamRuntimeTerminal>
    private let ingressTerminalContinuation: AsyncStream<FSEventStreamRuntimeTerminal>.Continuation
    private var didReportIngressTerminal = false
    private var drainTask: Task<Void, Never>?
    var lastRecordedLogicalDebtSnapshot: FilesystemLogicalDebtSnapshot?
    var logicalDebtSnapshotPublicationRevision: UInt64 = 0
    var hasBegunShutdown = false
    private var isPreparingActivityShutdown = false

    package init(
        bus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        fseventStreamClient: any FSEventStreamClient = DarwinFSEventStreamClient(),
        repositoryLocalActivityProjector: RepositoryLocalActivityProjector? = nil,
        watchedFolderScanScheduler: WatchedFolderScanScheduler = .production(),
        watchedFolderScanSubmission: WatchedFolderScanSubmissionPort = .direct,
        debounceWindow: Duration = AppPolicies.GitRefresh.filesystemDebounceWindow,
        maxFlushLatency: Duration = AppPolicies.GitRefresh.filesystemMaxFlushLatency,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) {
        let (ingressTerminalStream, ingressTerminalContinuation) =
            AsyncStream<FSEventStreamRuntimeTerminal>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        self.runtimeBus = bus
        self.fseventStreamClient = fseventStreamClient
        self.repositoryLocalActivityProjector = repositoryLocalActivityProjector
        self.watchedFolderScanScheduler = watchedFolderScanScheduler
        self.watchedFolderScanSubmission = watchedFolderScanSubmission
        schedulingClock = .continuous()
        self.debounceWindow = debounceWindow
        self.maxFlushLatency = maxFlushLatency
        self.performanceTraceRecorder = performanceTraceRecorder
        self.ingressTerminalStream = ingressTerminalStream
        self.ingressTerminalContinuation = ingressTerminalContinuation
    }

    init<C: Clock>(
        bus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        fseventStreamClient: any FSEventStreamClient = DarwinFSEventStreamClient(),
        repositoryLocalActivityProjector: RepositoryLocalActivityProjector? = nil,
        watchedFolderScanScheduler: WatchedFolderScanScheduler = .production(),
        sleepClock: C,
        debounceWindow: Duration = AppPolicies.GitRefresh.filesystemDebounceWindow,
        maxFlushLatency: Duration = AppPolicies.GitRefresh.filesystemMaxFlushLatency,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) where C.Duration == Duration, C: Sendable {
        let (ingressTerminalStream, ingressTerminalContinuation) =
            AsyncStream<FSEventStreamRuntimeTerminal>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        self.runtimeBus = bus
        self.fseventStreamClient = fseventStreamClient
        self.repositoryLocalActivityProjector = repositoryLocalActivityProjector
        self.watchedFolderScanScheduler = watchedFolderScanScheduler
        self.watchedFolderScanSubmission = .direct
        schedulingClock = .make(clock: sleepClock)
        self.debounceWindow = debounceWindow
        self.maxFlushLatency = maxFlushLatency
        self.performanceTraceRecorder = performanceTraceRecorder
        self.ingressTerminalStream = ingressTerminalStream
        self.ingressTerminalContinuation = ingressTerminalContinuation
    }

    isolated deinit {
        ingressTask?.cancel()
        drainTask?.cancel()
        watchedFolderScanState.resultDrainState.task?.cancel()
        watchedFolderScanState.fallbackTask?.cancel()
        watchedFolderScanState.manualRefreshState.task?.cancel()
        if !hasBegunShutdown {
            Self.logger.warning("FilesystemActor deinitialized without explicit shutdown()")
        }
    }

    package func register(worktreeId: UUID, repoId: UUID, rootPath: URL) async {
        _ = await registerForObservation(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath
        )
    }

    package func registerForObservation(
        worktreeId: UUID,
        repoId: UUID,
        rootPath: URL
    ) async -> FSEventStreamRegistrationOutcome {
        await register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath,
            revokesActivityAuthority: true
        )
    }

    @discardableResult
    func register(
        worktreeId: UUID,
        repoId: UUID,
        rootPath: URL,
        revokesActivityAuthority: Bool
    ) async -> FSEventStreamRegistrationOutcome {
        guard !hasBegunShutdown else {
            return .unavailable(.clientShutdown)
        }
        startIngressTaskIfNeeded()

        let canonicalRootPath = FilesystemRootOwnership.canonicalRootPath(for: rootPath)
        if let existing = roots[worktreeId],
            existing.repoId == repoId,
            existing.canonicalRootPath == canonicalRootPath
        {
            return .observing
        }
        let pathFilter = await FilesystemPathFilter.loadOffExecutor(forRootPath: rootPath)

        guard !hasBegunShutdown else {
            return .unavailable(.clientShutdown)
        }
        let existing = roots[worktreeId]
        let registrationOutcome = fseventStreamClient.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath
        )
        guard registrationOutcome == .observing else {
            return registrationOutcome
        }
        if revokesActivityAuthority,
            existing?.repoId != repoId || existing?.rootPath != rootPath,
            let repositoryStableKey = repositoryStableKeysByWorktreeId[worktreeId]
        {
            await repositoryLocalActivityProjector?.revokeAuthority(
                for: [repositoryStableKey]
            )
            guard !hasBegunShutdown else {
                return .unavailable(.clientShutdown)
            }
        }
        roots[worktreeId] = RootState(
            repoId: repoId,
            rootPath: rootPath,
            canonicalRootPath: canonicalRootPath,
            isActiveInApp: existing?.isActiveInApp ?? false,
            nextBatchSeq: existing?.nextBatchSeq ?? 0,
            pathFilter: pathFilter
        )
        if existing?.canonicalRootPath != canonicalRootPath {
            rebuildRootOwnership()
        }
        pendingChangesByWorktreeId[worktreeId] = pendingChangesByWorktreeId[worktreeId] ?? PendingWorktreeChanges()
        await emitFilesystemEvent(
            worktreeId: worktreeId,
            repoId: repoId,
            timestamp: envelopeClock.now,
            rootPathHint: rootPath,
            event: .worktreeRegistered(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
        )
        return .observing
    }

    package func unregister(worktreeId: UUID) async {
        await unregister(worktreeId: worktreeId, revokesActivityAuthority: true)
    }

    func unregister(
        worktreeId: UUID,
        revokesActivityAuthority: Bool
    ) async {
        if revokesActivityAuthority,
            roots[worktreeId] != nil,
            let repositoryStableKey = repositoryStableKeysByWorktreeId[worktreeId]
        {
            await repositoryLocalActivityProjector?.revokeAuthority(
                for: [repositoryStableKey]
            )
        }
        let removedRoot = roots.removeValue(forKey: worktreeId)
        pendingChangesByWorktreeId.removeValue(forKey: worktreeId)
        if activePaneWorktreeId == worktreeId {
            activePaneWorktreeId = nil
        }
        fseventStreamClient.unregister(worktreeId: worktreeId)
        guard let removedRoot else { return }
        rebuildRootOwnership()
        await emitFilesystemEvent(
            worktreeId: worktreeId,
            repoId: removedRoot.repoId,
            timestamp: envelopeClock.now,
            rootPathHint: removedRoot.rootPath,
            event: .worktreeUnregistered(worktreeId: worktreeId, repoId: removedRoot.repoId)
        )
    }

    /// Test seam for deterministic ingress without OS-level FSEvents.
    package func enqueueRawPaths(worktreeId: UUID, paths: [String]) async {
        await ingestRawPaths(
            worktreeId: worktreeId,
            paths: paths,
            requiresFullGitRefresh: false
        )
    }

    package func setActivity(worktreeId: UUID, isActiveInApp: Bool) {
        guard var root = roots[worktreeId] else {
            Self.logger.debug(
                "Ignored setActivity for unregistered worktree \(worktreeId.uuidString, privacy: .public)"
            )
            return
        }
        root.isActiveInApp = isActiveInApp
        roots[worktreeId] = root
    }

    package func setActivePaneWorktree(worktreeId: UUID?) {
        activePaneWorktreeId = worktreeId
    }

    package func setRepositoryFactAttention(
        activePaneWorktreeId: UUID?,
        openWorktreeIds: Set<UUID>
    ) {
        self.activePaneWorktreeId = activePaneWorktreeId
        for worktreeId in roots.keys {
            guard var root = roots[worktreeId] else { continue }
            root.isActiveInApp = openWorktreeIds.contains(worktreeId)
            roots[worktreeId] = root
        }
    }

    package func start() async {
        // Start shared ingress before registration. Later ingress owners call this idempotently.
        startIngressTaskIfNeeded()
    }

    package func runtimeTerminals() -> AsyncStream<FSEventStreamRuntimeTerminal> {
        ingressTerminalStream
    }

    package func shutdown() async {
        guard !hasBegunShutdown else { return }
        isPreparingActivityShutdown = true
        fseventStreamClient.beginActivityShutdown()
        let activityDrainTask = drainTask
        drainTask?.cancel()
        drainTask = nil
        if let activityDrainTask {
            await activityDrainTask.value
        }
        await checkpointRepositoryLocalActivity()
        hasBegunShutdown = true
        watchedFolderScanState.isShuttingDown = true
        let activeIngressTask = ingressTask
        let activeDrainTask = drainTask
        let activeWatchedFolderResultDrainTask = watchedFolderScanState.resultDrainState.task
        let activeFallbackTask = watchedFolderScanState.fallbackTask
        let activeManualWatchedFolderRefreshTask = watchedFolderScanState.manualRefreshState.task

        ingressTask?.cancel()
        ingressTask = nil
        drainTask?.cancel()
        drainTask = nil
        watchedFolderScanState.fallbackTask?.cancel()
        watchedFolderScanState.fallbackTask = nil
        cancelManualWatchedFolderRefreshForShutdown()

        // Keep the sole result consumer alive while scheduler shutdown drains
        // running, pending, and leased result custody.
        await watchedFolderScanScheduler.shutdown()

        if let activeIngressTask {
            await activeIngressTask.value
        }
        if let activeDrainTask {
            await activeDrainTask.value
        }
        if let activeWatchedFolderResultDrainTask {
            await activeWatchedFolderResultDrainTask.value
        }
        watchedFolderScanState.resultDrainState = .idle
        if let activeFallbackTask {
            await activeFallbackTask.value
        }
        if let activeManualWatchedFolderRefreshTask {
            _ = await activeManualWatchedFolderRefreshTask.value
        }

        roots.removeAll(keepingCapacity: false)
        rootOwnership = FilesystemRootOwnership(canonicalRootsByWorktree: [:])
        pendingChangesByWorktreeId.removeAll(keepingCapacity: false)
        watchedFolderScanState = FilesystemWatchedFolderScanState()
        watchedFolderScanState.isShuttingDown = true
        activePaneWorktreeId = nil
        fseventStreamClient.shutdown()
        ingressTerminalContinuation.finish()
    }

    private func rebuildRootOwnership() {
        rootOwnership = FilesystemRootOwnership(
            canonicalRootsByWorktree: roots.mapValues(\.canonicalRootPath)
        )
        rootOwnershipRevision &+= 1
    }
}

extension FilesystemActor {
    func startIngressTaskIfNeeded() {
        guard !hasBegunShutdown else { return }
        guard ingressTask == nil else { return }
        let stream = fseventStreamClient.events()
        ingressTask = Task { [weak self] in
            for await ingressItem in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard case .batch(let batch) = ingressItem else {
                    switch ingressItem {
                    case .activityObservations(let activityBatch):
                        await self.ingestSharedActivityObservations(activityBatch)
                        await self.consumeActivityOverflowRecoveries()
                    case .activityProcessingFence(let fenceID):
                        await self.consumeActivityOverflowRecoveries()
                        self.fseventStreamClient.acknowledgeActivityProcessingFence(fenceID)
                    case .batch:
                        break
                    }
                    continue
                }
                if await self.isWatchedFolderBatch(batch.worktreeId) {
                    await self.handleWatchedFolderFSEvent(batch)
                } else {
                    await self.ingestRawPaths(
                        worktreeId: batch.worktreeId,
                        paths: batch.paths,
                        requiresFullGitRefresh: batch.requiresFullGitRefresh,
                        activityParticipant: batch.participant,
                        activityObservations: batch.observations,
                        shouldScheduleAndRecord: false
                    )
                }
                guard !Task.isCancelled else { break }
                guard await self.acceptsIngressWork else { break }
                await self.consumeOverflowRecoveries()
                await self.consumeActivityOverflowRecoveries()
            }
            guard !Task.isCancelled else { return }
            await self?.reportIngressTerminalIfNeeded()
        }
    }

    private func reportIngressTerminalIfNeeded() {
        guard !hasBegunShutdown, !didReportIngressTerminal else { return }
        didReportIngressTerminal = true
        ingressTerminalContinuation.yield(.eventsEnded)
    }

    private var acceptsIngressWork: Bool {
        !hasBegunShutdown
    }

    private func consumeOverflowRecoveries() async {
        guard !hasBegunShutdown else { return }
        for recovery in fseventStreamClient.consumeOverflowRecoveries() {
            guard !hasBegunShutdown else { break }
            let isWatchedFolderRecovery = isWatchedFolderBatch(recovery.worktreeId)
            let preservesWatchedFolderScope =
                isWatchedFolderRecovery
                && recovery.requiresWatchedFolderScan == false
            performanceTraceRecorder?.record(
                .filesystemStageOutcome,
                attributes: [
                    "agentstudio.performance.filesystem.stage": .string("overflow_recovery"),
                    "agentstudio.performance.filesystem.outcome": .string(
                        recovery.paths == nil && !preservesWatchedFolderScope
                            ? "overflow_coarse" : "overflow_scoped"),
                ]
            )
            if isWatchedFolderRecovery {
                if let paths = recovery.paths {
                    let retainedBatch = FSEventBatch(
                        worktreeId: recovery.worktreeId, paths: paths.sorted(),
                        observations: recovery.observations,
                        requiresFullGitRefresh: recovery.requiresFullGitRefresh)
                    await handleWatchedFolderFSEvent(retainedBatch, shouldRecordLogicalDebt: false)
                } else if recovery.requiresWatchedFolderScan || recovery.requiresFullGitRefresh {
                    await handleCoarseWatchedFolderFSEvent(
                        worktreeId: recovery.worktreeId, shouldRecordLogicalDebt: false)
                }
                continue
            }
            if let paths = recovery.paths {
                let batch = FSEventBatch(
                    worktreeId: recovery.worktreeId,
                    paths: paths.sorted()
                )
                await ingestRawPaths(
                    worktreeId: recovery.worktreeId,
                    paths: batch.paths,
                    requiresFullGitRefresh: recovery.requiresFullGitRefresh,
                    shouldScheduleAndRecord: false
                )
                continue
            }
            guard pendingChangesByWorktreeId[recovery.worktreeId] != nil else { continue }
            var pendingChanges = pendingChangesByWorktreeId[recovery.worktreeId] ?? PendingWorktreeChanges()
            if recovery.requiresFullGitRefresh {
                pendingChanges.containsGitInternalChanges = true
            }
            pendingChanges.projectedPaths.insert(".")
            pendingChanges.recordPendingChange(at: schedulingClock.now())
            pendingChangesByWorktreeId[recovery.worktreeId] = pendingChanges
        }
        guard !hasBegunShutdown else { return }
        scheduleDrainIfNeeded()
        await recordLogicalDebtSnapshotIfChanged()
    }

    func scheduleDrainIfNeeded() {
        guard !hasBegunShutdown else { return }
        guard !isPreparingActivityShutdown else { return }
        guard drainTask == nil else { return }
        guard hasPendingPaths else { return }

        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingChanges()
            await self.recordLogicalDebtSnapshotIfChanged()
        }
    }

    private func drainPendingChanges() async {
        defer {
            drainTask = nil
            if hasPendingPaths {
                scheduleDrainIfNeeded()
            }
        }

        while !Task.isCancelled {
            let now = schedulingClock.now()
            if activityCheckpointIsDue(now: now) {
                await checkpointRepositoryLocalActivity()
                continue
            }
            if let worktreeId = nextWorktreeToFlush(now: now) {
                await flush(worktreeId: worktreeId)
                continue
            }

            guard hasPendingPaths else {
                return
            }

            guard let nextDeadline = nextFlushDeadline(now: now) else {
                await Task.yield()
                continue
            }

            let sleepDuration = nextDeadline - now
            if sleepDuration > .zero {
                do {
                    try await schedulingClock.sleep(sleepDuration)
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.warning(
                        "Unexpected filesystem drain sleep failure: \(String(describing: error), privacy: .public)"
                    )
                    continue
                }
                guard !Task.isCancelled else { return }
            } else {
                await Task.yield()
            }
        }
    }

    private var hasPendingPaths: Bool {
        pendingActivityCheckpoint.isPending
            || pendingChangesByWorktreeId.values.contains(where: \.hasPendingChanges)
    }

    var pendingWorktreeLogicalDebtCount: Int {
        pendingChangesByWorktreeId.values.count(where: \.hasPendingChanges)
    }

    var drainTaskLogicalDebtCount: Int {
        drainTask == nil ? 0 : 1
    }

    private func nextWorktreeToFlush(now: Duration) -> UUID? {
        let candidates =
            pendingChangesByWorktreeId
            .compactMap { worktreeId, pendingChanges -> UUID? in
                guard pendingChanges.hasPendingChanges else { return nil }
                guard roots[worktreeId] != nil else { return nil }
                guard isFlushDue(pendingChanges, now: now) else { return nil }
                return worktreeId
            }

        return candidates.min { lhs, rhs in
            let lhsPriority = priorityKey(for: lhs)
            let rhsPriority = priorityKey(for: rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            let lhsRoot = roots[lhs]?.canonicalRootPath ?? ""
            let rhsRoot = roots[rhs]?.canonicalRootPath ?? ""
            if lhsRoot != rhsRoot {
                return lhsRoot < rhsRoot
            }
            return lhs.uuidString < rhs.uuidString
        }
    }

    private func nextFlushDeadline(now: Duration) -> Duration? {
        let pathDeadline =
            pendingChangesByWorktreeId
            .compactMap { worktreeId, pendingChanges -> Duration? in
                guard pendingChanges.hasPendingChanges else { return nil }
                guard roots[worktreeId] != nil else { return nil }
                guard let deadline = flushDeadline(for: pendingChanges) else { return nil }
                return deadline > now ? deadline : now
            }
            .min()
        let activityDeadline = activityCheckpointDeadline()
        return [pathDeadline, activityDeadline].compactMap { $0 }.min()
    }

    private func priorityKey(for worktreeId: UUID) -> Int {
        guard let root = roots[worktreeId] else { return Int.max }
        if root.isActiveInApp {
            if activePaneWorktreeId == worktreeId {
                return 0
            }
            return 1
        }
        return 2
    }

    private func isFlushDue(_ pendingChanges: PendingWorktreeChanges, now: Duration) -> Bool {
        guard let firstPendingTimestamp = pendingChanges.firstPendingTimestamp,
            let lastPendingTimestamp = pendingChanges.lastPendingTimestamp
        else {
            return true
        }

        let debounceDeadline = lastPendingTimestamp + debounceWindow
        let maxLatencyDeadline = firstPendingTimestamp + maxFlushLatency
        return now >= debounceDeadline || now >= maxLatencyDeadline
    }

    private func flushDeadline(for pendingChanges: PendingWorktreeChanges) -> Duration? {
        guard let firstPendingTimestamp = pendingChanges.firstPendingTimestamp,
            let lastPendingTimestamp = pendingChanges.lastPendingTimestamp
        else {
            return nil
        }
        let debounceDeadline = lastPendingTimestamp + debounceWindow
        let maxLatencyDeadline = firstPendingTimestamp + maxFlushLatency
        return min(debounceDeadline, maxLatencyDeadline)
    }

    private func flush(worktreeId: UUID) async {
        guard var root = roots[worktreeId] else {
            pendingChangesByWorktreeId.removeValue(forKey: worktreeId)
            return
        }
        guard let pendingChanges = pendingChangesByWorktreeId[worktreeId], pendingChanges.hasPendingChanges else {
            return
        }

        pendingChangesByWorktreeId[worktreeId] = PendingWorktreeChanges()

        let orderedPaths = pendingChanges.projectedPaths.sorted()
        let pathChunks =
            orderedPaths.isEmpty
            ? [[]]
            : Self.chunkPaths(
                orderedPaths,
                maxChunkSize: Self.maxPathsPerFilesChangedEvent
            )
        for pathChunk in pathChunks {
            root.nextBatchSeq += 1
            let batchSeq = root.nextBatchSeq
            let timestamp = envelopeClock.now
            let changeset = FileChangeset(
                worktreeId: worktreeId,
                repoId: root.repoId,
                rootPath: root.rootPath,
                paths: pathChunk,
                containsGitInternalChanges: pendingChanges.containsGitInternalChanges,
                suppressedIgnoredPathCount: pendingChanges.suppressedIgnoredPathCount,
                suppressedGitInternalPathCount: pendingChanges.suppressedGitInternalPathCount,
                timestamp: timestamp,
                batchSeq: batchSeq
            )

            await emitFilesystemEvent(
                worktreeId: worktreeId,
                repoId: root.repoId,
                timestamp: timestamp,
                rootPathHint: root.rootPath,
                event: .filesChanged(changeset: changeset)
            )
        }
        roots[worktreeId] = root
    }

    nonisolated private static func chunkPaths(
        _ paths: [String],
        maxChunkSize: Int
    ) -> [[String]] {
        guard !paths.isEmpty else { return [] }
        guard maxChunkSize > 0 else { return [paths] }

        var chunks: [[String]] = []
        chunks.reserveCapacity((paths.count + maxChunkSize - 1) / maxChunkSize)

        var index = 0
        while index < paths.count {
            let upperBound = min(index + maxChunkSize, paths.count)
            chunks.append(Array(paths[index..<upperBound]))
            index = upperBound
        }

        return chunks
    }

    private func emitFilesystemEvent(
        worktreeId: UUID,
        repoId: UUID,
        timestamp: ContinuousClock.Instant,
        rootPathHint: URL? = nil,
        event: FilesystemEvent
    ) async {
        nextEnvelopeSequence += 1
        let runtimeEnvelope: RuntimeEnvelope
        switch event {
        case .worktreeRegistered(let registeredWorktreeId, let registeredRepoId, let rootPath):
            runtimeEnvelope = .system(
                SystemEnvelope(
                    source: .builtin(.filesystemWatcher),
                    seq: nextEnvelopeSequence,
                    timestamp: timestamp,
                    event: .topology(
                        .worktreeRegistered(
                            worktreeId: registeredWorktreeId,
                            repoId: registeredRepoId,
                            rootPath: rootPath
                        )
                    )
                )
            )
        case .worktreeUnregistered(let unregisteredWorktreeId, let unregisteredRepoId):
            runtimeEnvelope = .system(
                SystemEnvelope(
                    source: .builtin(.filesystemWatcher),
                    seq: nextEnvelopeSequence,
                    timestamp: timestamp,
                    event: .topology(
                        .worktreeUnregistered(
                            worktreeId: unregisteredWorktreeId,
                            repoId: unregisteredRepoId
                        )
                    )
                )
            )
        case .filesChanged:
            runtimeEnvelope = .worktree(
                WorktreeEnvelope(
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: nextEnvelopeSequence,
                    timestamp: timestamp,
                    repoId: repoId,
                    worktreeId: worktreeId,
                    event: .filesystem(event)
                )
            )
        case .gitSnapshotChanged, .diffAvailable, .branchChanged:
            runtimeEnvelope = .worktree(
                WorktreeEnvelope(
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: nextEnvelopeSequence,
                    timestamp: timestamp,
                    repoId: repoId,
                    worktreeId: worktreeId,
                    event: .gitWorkingDirectory(gitWorkingDirectoryEvent(from: event))
                )
            )
        }

        let droppedCount = (await runtimeBus.post(runtimeEnvelope)).droppedCount
        if droppedCount > 0 {
            Self.logger.warning(
                "Filesystem event delivery dropped for \(droppedCount, privacy: .public) subscriber(s); seq=\(self.nextEnvelopeSequence, privacy: .public)"
            )
        }
        Self.logger.debug(
            """
            Posted filesystem event for worktree \(worktreeId.uuidString, privacy: .public); \
            event=\(String(describing: event), privacy: .public)
            """
        )
        _ = rootPathHint
    }

    // MARK: - Watched Folder Scanning

    private func emitRepoDiscovered(
        repoPath: URL,
        parentPath: URL,
        linkedWorktrees: LinkedWorktreeInfo = .notScanned
    ) async {
        nextEnvelopeSequence += 1
        let envelope = RuntimeEnvelope.system(
            SystemEnvelope(
                source: .builtin(.filesystemWatcher),
                seq: nextEnvelopeSequence,
                timestamp: envelopeClock.now,
                event: .topology(
                    .repoDiscovered(
                        repoPath: repoPath,
                        parentPath: parentPath,
                        linkedWorktrees: linkedWorktrees,
                        stableIdentity: .prepare(repoPath: repoPath, linkedWorktrees: linkedWorktrees)
                    )
                )
            )
        )
        let droppedCount = (await runtimeBus.post(envelope)).droppedCount
        if droppedCount > 0 {
            Self.logger.warning(
                "Repo discovered event delivery dropped for \(droppedCount, privacy: .public) subscriber(s); repoPath=\(repoPath.path, privacy: .public)"
            )
        }
    }

    func emitReposDiscovered(
        parentPath: URL,
        repositories: [DiscoveredRepoTopologyInfo]
    ) async {
        guard !repositories.isEmpty else { return }
        nextEnvelopeSequence += 1
        let envelope = RuntimeEnvelope.system(
            SystemEnvelope(
                source: .builtin(.filesystemWatcher),
                seq: nextEnvelopeSequence,
                timestamp: envelopeClock.now,
                event: .topology(
                    .reposDiscovered(
                        parentPath: parentPath,
                        repositories: repositories
                    )
                )
            )
        )
        let droppedCount = (await runtimeBus.post(envelope)).droppedCount
        if droppedCount > 0 {
            Self.logger.warning(
                "Repos discovered event delivery dropped for \(droppedCount, privacy: .public) subscriber(s); parentPath=\(parentPath.path, privacy: .public)"
            )
        }
    }

    func emitRemovedClones(noLongerReferencedByAnyWatchedFolder clonePaths: Set<URL>) async {
        for repoPath in clonePaths.sorted(by: Self.sortByPath) {
            guard !isReferencedByAnyWatchedFolder(repoPath) else { continue }
            await emitRepoRemoved(repoPath: repoPath)
        }
    }

    private func emitRepoRemoved(repoPath: URL) async {
        nextEnvelopeSequence += 1
        let envelope = RuntimeEnvelope.system(
            SystemEnvelope(
                source: .builtin(.filesystemWatcher),
                seq: nextEnvelopeSequence,
                timestamp: envelopeClock.now,
                event: .topology(.repoRemoved(repoPath: repoPath))
            )
        )
        let droppedCount = (await runtimeBus.post(envelope)).droppedCount
        if droppedCount > 0 {
            Self.logger.warning(
                "Repo removed event delivery dropped for \(droppedCount, privacy: .public) subscriber(s); repoPath=\(repoPath.path, privacy: .public)"
            )
        }
    }

    func isReferencedByAnyWatchedFolder(_ repoPath: URL) -> Bool {
        watchedFolderScanState.inventoryBySourceID.values.contains { inventory in
            inventory.repoGroups.contains { $0.clonePath == repoPath }
        }
    }

    static func normalizeRepoScanGroups(
        _ groups: [RepoScanner.RepoScanGroup]
    ) -> [RepoScanner.RepoScanGroup] {
        groups
            .map { group in
                RepoScanner.RepoScanGroup(
                    clonePath: group.clonePath.standardizedFileURL,
                    linkedWorktreePaths: group.linkedWorktreePaths
                        .map(\.standardizedFileURL)
                        .sorted(by: Self.sortByPath)
                )
            }
            .sorted(by: Self.sortByClonePath)
    }

    static func sortByClonePath(
        _ lhs: RepoScanner.RepoScanGroup,
        _ rhs: RepoScanner.RepoScanGroup
    ) -> Bool {
        sortByPath(lhs.clonePath, rhs.clonePath)
    }

    static func sortByPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    static func sortWorktreeIds(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    // MARK: - Git Event Projection

    private func gitWorkingDirectoryEvent(from event: FilesystemEvent) -> GitWorkingDirectoryEvent {
        switch event {
        case .gitSnapshotChanged(let snapshot):
            return .snapshotChanged(snapshot: snapshot)
        case .branchChanged(let worktreeId, let repoId, let from, let to):
            return .branchChanged(worktreeId: worktreeId, repoId: repoId, from: from, to: to)
        case .diffAvailable(let diffId, let worktreeId, let repoId):
            return .diffAvailable(diffId: diffId, worktreeId: worktreeId, repoId: repoId)
        case .worktreeRegistered, .worktreeUnregistered, .filesChanged:
            preconditionFailure("Unsupported filesystem event for git working directory projection")
        }
    }
}
