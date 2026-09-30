import AgentStudioInfrastructure
import Foundation
import os

/// Event-driven projector that derives local git state from filesystem facts.
///
/// Input:
/// - `.filesystem(.worktreeRegistered)`
/// - `.filesystem(.worktreeUnregistered)`
/// - `.filesystem(.filesChanged)`
///
/// Output:
/// - `.filesystem(.gitSnapshotChanged)`
/// - `.filesystem(.branchChanged)` (optional derivative fact)
package actor GitWorkingDirectoryProjector {
    static let logger = Logger(subsystem: "com.agentstudio", category: "GitWorkingDirectoryProjector")

    let runtimeBus: EventBus<RuntimeEnvelope>
    let runtimeEnvelopePoster: any RuntimeEnvelopePosting
    /// Not `private` so the pathspec-status extension can dispatch scoped and full
    /// status reads (see `GitWorkingDirectoryProjector+PathspecStatus`).
    let gitWorkingTreeProvider: any GitWorkingTreeStatusProvider
    let envelopeClock: ContinuousClock
    let deadlineClock: GitRefreshDeadlineClock
    let coalescingWindow: Duration
    let delay: AsyncDelay
    let refreshPolicy: AppPolicies.GitRefresh.Policy
    private let subscriptionBufferLimit: Int
    let performanceTraceRecorder: (any GitProjectorPerformanceRecording)?
    let factSink: GitProjectorFactSink?
    let remoteReferenceOriginHandler: (@Sendable (UUID, String?, RepositoryObservationLifetime?) async -> Void)?
    /// Cheap filesystem existence check used to quarantine dead-path worktrees at
    /// admission (see `GitWorkingDirectoryProjector+PathQuarantine`). Injected so
    /// the projector stays inert in unit tests that register synthetic paths; the
    /// production composition root wires the live `FileManager` probe.
    let pathExistenceProbe: @Sendable (URL) -> Bool

    private var subscriptionTask: Task<Void, Never>?
    var subscriptionHandle: EventBusSubscription<RuntimeEnvelope>?
    var subscriptionLifetime: UInt64 = 0
    var lastEmittedDroppedEnvelopeCount: UInt64 = 0
    var isStarting = false
    var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    var shutdownInProgress = false
    var outstandingDrainTasks: [UInt64: Task<Void, Never>] = [:]
    var deadlineTask: Task<Void, Never>?
    var deadlineTaskGeneration: UInt64 = 0
    var deadlineQueue = GitRefreshDeadlineQueue()
    var nextDeadlineFactGeneration: UInt64 = 0
    var deadlineFactScopeBySlot: [GitProjectorDeadlineFactSlot: GitProjectorScope] = [:]
    var capacityCompletionTask: Task<Void, Never>?
    var worktreeTasks: [UUID: Task<Void, Never>] = [:]
    var openRefreshFactScopeByWorktreeId: [UUID: GitProjectorScope] = [:]
    private var worktreeTaskGenerationByWorktreeId: [UUID: UInt64] = [:]
    private var nextWorktreeTaskGeneration: UInt64 = 0
    var immediateRefreshWorktreeIds: Set<UUID> = []
    var explicitRefreshWorktreeIds: Set<UUID> = []
    var tierEligibleWorktreeIds: Set<UUID> = []
    var admittedDemandTierByWorktreeId: [UUID: GitDemandTier] = [:]
    var admissionStartedAtByWorktreeId: [UUID: ContinuousClock.Instant] = [:]
    var visibleSidebarStripeCursor: Int = 0
    var visibilityAdmissionTask: Task<Void, Never>?
    var nextVisibilityAdmissionFactGeneration: UInt64 = 0
    var activeVisibilityAdmissionFactGeneration: UInt64?
    var visibilityAdmissionFactScopesByWorktreeId: [UUID: GitProjectorScope] = [:]
    var lastProcessedSidebarVisibleWorktreeIds: Set<UUID> = []
    var pendingVisibilityDeltaWorktreeIds: Set<UUID> = []
    var coalescingWorktreeIds: Set<UUID> = []
    var pendingByWorktreeId: [UUID: FileChangeset] = [:]
    var observedIntakeFactScopes: Set<GitProjectorScope> = []
    var closedIntakeFactScopes: Set<GitProjectorScope> = []
    var intakeFactRegistrationByWorktreeId: [UUID: UInt64] = [:]
    var nextIntakeFactRegistrationByWorktreeId: [UUID: UInt64] = [:]
    var refreshAttribution = GitRefreshAttributionState()
    var capacityRetryWorktreeIds: Set<UUID> = []
    var capacityRetryReasonByWorktreeId: [UUID: GitWorkingTreeStatusUnavailableReason] = [:]
    var capacityFactEpisodeByWorktreeId: [UUID: UInt64] = [:]
    var capacityFactOpenEpisodeByWorktreeId: [UUID: UInt64] = [:]
    /// Capacity-deferred attempts whose automatic start spacing was already paid.
    /// Admission consumes membership only when resuming that exact retained attempt.
    var capacityRearmedWorktreeIds: Set<UUID> = []
    var capacityFallbackDeadlineByWorktreeId: [UUID: Duration] = [:]
    var suppressedWorktreeIds: Set<UUID> = []
    private var suppressedWorktreeOrder: [UUID] = []
    var rootPathByWorktreeId: [UUID: URL] = [:]
    var observationLifetimesByWorktreeID: [UUID: WorktreeObservationLifetime] = [:]
    private(set) var latestTopologyAssertion: FilesystemTopologyAssertion?
    var activeWorktreeIds: Set<UUID> = []
    var activePaneWorktreeId: UUID?
    var sidebarVisibleWorktreeIds: Set<UUID> = []
    var automaticEligibleWorktreeIds: Set<UUID>?
    var backgroundOnlyAutomaticWorktreeIds: Set<UUID> = []
    var inactiveAutomaticSourceStartCount: UInt64 = 0
    var repoIdByWorktreeId: [UUID: UUID] = [:]
    var lastKnownOriginByRepoId: [UUID: String] = [:]
    var originResolutionByRepoId: [UUID: GitOriginResolution] = [:]
    var remoteReferenceAcceptanceByRepoId: [UUID: RemoteReferenceAcceptance] = [:]
    var remoteReferenceAuthorityRevisionByRepoId: [UUID: UInt64] = [:]
    var lastEmittedSnapshotByWorktreeId: [UUID: GitWorkingTreeSnapshot] = [:]
    /// Last successful full status entry set per worktree. Its presence marks a
    /// fold-capable cache: a scoped compute folds into it (see
    /// `GitWorkingDirectoryProjector+PathspecStatus`). Not `private` so that
    /// extension can read it.
    var lastStatusEntriesByWorktreeId: [UUID: [GitWorkingTreeStatusEntry]] = [:]
    var lastAcceptedStatusFactsByWorktreeId: [UUID: GitWorkingTreeStatusFacts] = [:]
    var exactCleanAuthorityByWorktreeId: [UUID: GitCleanContinuityAuthority] = [:]
    var lastAcceptedLineDetailByWorktreeId: [UUID: GitWorkingTreeLineDetail] = [:]
    var lastAcceptedLineDetailAtByWorktreeId: [UUID: Duration] = [:]
    var lastAcceptedStatusAtByWorktreeId: [UUID: Duration] = [:]
    var automaticRefreshDeadlineByWorktreeId: [UUID: Duration] = [:]
    var lastAutomaticStartAtByWorktreeId: [UUID: Duration] = [:]
    var lastAutomaticCompletionAtByWorktreeId: [UUID: Duration] = [:]
    var lastAutomaticDutyByWorktreeId: [UUID: Duration] = [:]
    var nextAutomaticStartAt: Duration = .zero
    var nextPeriodicBatchSeqByWorktreeId: [UUID: UInt64] = [:]
    var statusBackoffFailureCountByWorktreeId: [UUID: Int] = [:]
    var backoffFactEpisodeByWorktreeId: [UUID: UInt64] = [:]
    var backoffFactOpenEpisodeByWorktreeId: [UUID: UInt64] = [:]
    var openStatusBackoffWorktreeIds: Set<UUID> = []
    var deferredStatusBackoffChangesetByWorktreeId: [UUID: FileChangeset] = [:]
    var statusFailureDeadlineByWorktreeId: [UUID: Duration] = [:]
    var consecutiveStatusFailureCountByWorktreeId: [UUID: Int] = [:]
    /// Registered worktrees whose root path has vanished from disk. They are
    /// skipped at admission and periodic re-enqueue without further stat calls
    /// until an event-driven re-arm clears the mark
    /// (see `GitWorkingDirectoryProjector+PathQuarantine`).
    var quarantinedWorktreeIds: Set<UUID> = []
    var quarantineFactEpisodeByWorktreeId: [UUID: UInt64] = [:]
    /// Exact root paths already validated for work currently crossing physical
    /// provider admission. Capacity-only rejection retains the validation for its
    /// retry; every other completion or lifecycle replacement clears it.
    var validatedRootPathByWorktreeId: [UUID: URL] = [:]
    var unchangedStatusResultCountByWorktreeId: [UUID: Int] = [:]
    var nextEnvelopeSequence: UInt64 = 0
    var lastRecordedLogicalDebtSnapshot: GitLogicalDebtSnapshot?
    var aggregatePerformance = GitWorkingDirectoryPerformanceAccumulator()
    var explicitRepositoryUpdateAttemptsById: [UUID: GitExplicitRepositoryUpdateAttempt] = [:]
    var remoteReferenceRecomputationAttemptsByAuthorityRevision: [UInt64: GitRemoteReferenceRecomputationAttempt] = [:]
    var remoteReferenceRecomputationLeasesByAuthorityRevision: [UInt64: RepositoryFactSourceUpdateLease] = [:]
    var remoteReferenceRecomputationRepositoryIdByAuthorityRevision: [UInt64: UUID] = [:]
    var isShuttingDown = false
    var lastClosedFactLifetime: UInt64?

    var queuedLogicalDebtCount: Int {
        pendingByWorktreeId.count
    }

    var retryPendingLogicalDebtCount: Int {
        capacityRetryWorktreeIds.count + openStatusBackoffWorktreeIds.count
    }

    var runningLogicalDebtCount: Int {
        worktreeTasks.count
    }

    package init(
        bus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        gitWorkingTreeProvider: any GitWorkingTreeStatusProvider,
        envelopeClock: ContinuousClock = ContinuousClock(),
        coalescingWindow: Duration,
        sleepClock: (any Clock<Duration> & Sendable)? = nil,
        refreshPolicy: AppPolicies.GitRefresh.Policy = AppPolicies.GitRefresh.defaultPolicy,
        subscriptionBufferLimit: Int = 256,
        performanceTraceRecorder: (any GitProjectorPerformanceRecording)? = nil,
        factSink: GitProjectorFactSink? = nil,
        runtimeEnvelopePoster: (any RuntimeEnvelopePosting)? = nil,
        remoteReferenceOriginHandler: (@Sendable (UUID, String?, RepositoryObservationLifetime?) async -> Void)? = nil,
        pathExistenceProbe: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) {
        self.runtimeBus = bus
        self.runtimeEnvelopePoster = runtimeEnvelopePoster ?? bus
        self.gitWorkingTreeProvider = gitWorkingTreeProvider
        self.envelopeClock = envelopeClock
        if let sleepClock {
            self.deadlineClock = GitRefreshDeadlineClock(sleepClock)
        } else {
            self.deadlineClock = GitRefreshDeadlineClock(ContinuousClock())
        }
        self.coalescingWindow = coalescingWindow
        delay = sleepClock.map(AsyncDelay.clock) ?? .taskSleep
        self.refreshPolicy = refreshPolicy
        self.subscriptionBufferLimit = subscriptionBufferLimit
        self.performanceTraceRecorder = performanceTraceRecorder
        self.factSink = factSink
        self.remoteReferenceOriginHandler = remoteReferenceOriginHandler
        self.pathExistenceProbe = pathExistenceProbe
    }

    isolated deinit {
        subscriptionTask?.cancel()
        deadlineTask?.cancel()
        capacityCompletionTask?.cancel()
        visibilityAdmissionTask?.cancel()
        for task in worktreeTasks.values {
            task.cancel()
        }
        worktreeTasks.removeAll(keepingCapacity: false)
        worktreeTaskGenerationByWorktreeId.removeAll(keepingCapacity: false)
        consecutiveStatusFailureCountByWorktreeId.removeAll(keepingCapacity: false)
    }

    package func start() async {
        guard subscriptionTask == nil, !isStarting, !shutdownInProgress else { return }
        isStarting = true
        isShuttingDown = false
        let stream = await runtimeBus.subscribe(
            policy: .lossyNewest(subscriptionBufferLimit),
            subscriberName: "GitWorkingDirectoryProjector",
            factInterest: .matching([.systemTopology, .worktreeFilesystem])
        )
        isStarting = false
        let shouldCancelForShutdown = isShuttingDown
        subscriptionLifetime &+= 1
        let lifetime = subscriptionLifetime
        subscriptionHandle = stream
        if factSink != nil { lastEmittedDroppedEnvelopeCount = 0 }
        subscriptionTask = Task { [weak self] in
            for await runtimeEnvelope in stream {
                guard !Task.isCancelled else { break }
                guard let self else { return }
                await self.handleAndRecordRuntimeEnvelope(runtimeEnvelope, lifetime: lifetime)
            }
            await self?.subscriptionStreamDidEnd(lifetime: lifetime)
        }

        resumeShutdownsWaitingForSubscriptionStart()
        if shouldCancelForShutdown {
            subscriptionTask?.cancel()
            return
        }

        rescheduleDeadlineTask()
    }

    package func shutdown() async {
        guard !shutdownInProgress else { return }
        shutdownInProgress = true
        isShuttingDown = true
        await waitForSubscriptionStartBeforeShutdown()
        let subscription = subscriptionTask
        subscriptionTask?.cancel()
        subscriptionTask = nil
        let deadline = deadlineTask
        deadlineTask?.cancel()
        deadlineTask = nil
        let capacityCompletion = capacityCompletionTask
        capacityCompletionTask?.cancel()
        capacityCompletionTask = nil
        let visibilityAdmission = visibilityAdmissionTask
        visibilityAdmissionTask?.cancel()
        visibilityAdmissionTask = nil

        let tasksToAwait = Array(outstandingDrainTasks.values)
        for task in tasksToAwait {
            task.cancel()
        }
        worktreeTasks.removeAll(keepingCapacity: false)
        worktreeTaskGenerationByWorktreeId.removeAll(keepingCapacity: false)

        if let subscription {
            await subscription.value
        }
        if let deadline {
            await deadline.value
        }
        if let capacityCompletion {
            await capacityCompletion.value
        }
        if let visibilityAdmission {
            await visibilityAdmission.value
        }
        for task in tasksToAwait {
            await task.value
        }
        for worktreeId in Array(openRefreshFactScopeByWorktreeId.keys) {
            closeRefreshFact(worktreeId: worktreeId, outcome: .shutdown)
        }
        settleAllRepositoryRecomputations(.cancelled)
        for (worktreeId, rootPath) in rootPathByWorktreeId {
            (gitWorkingTreeProvider as? any GitExactCleanStatusProviding)?.retireExactCleanAuthority(
                worktreeId: worktreeId,
                rootPath: rootPath
            )
        }
        exactCleanAuthorityByWorktreeId.removeAll(keepingCapacity: false)
        flushAggregatePerformanceSnapshot()
        clearRefreshSchedulingStateAfterShutdown()
        suppressedWorktreeIds.removeAll(keepingCapacity: false)
        suppressedWorktreeOrder.removeAll(keepingCapacity: false)
        rootPathByWorktreeId.removeAll(keepingCapacity: false)
        latestTopologyAssertion = nil
        activeWorktreeIds.removeAll(keepingCapacity: false)
        activePaneWorktreeId = nil
        sidebarVisibleWorktreeIds.removeAll(keepingCapacity: false)
        automaticEligibleWorktreeIds = nil
        backgroundOnlyAutomaticWorktreeIds.removeAll(keepingCapacity: false)
        inactiveAutomaticSourceStartCount = 0
        repoIdByWorktreeId.removeAll(keepingCapacity: false)
        lastKnownOriginByRepoId.removeAll(keepingCapacity: false)
        originResolutionByRepoId.removeAll(keepingCapacity: false)
        remoteReferenceAcceptanceByRepoId.removeAll(keepingCapacity: false)
        remoteReferenceAuthorityRevisionByRepoId.removeAll(keepingCapacity: false)
        lastEmittedSnapshotByWorktreeId.removeAll(keepingCapacity: false)
        lastStatusEntriesByWorktreeId.removeAll(keepingCapacity: false)
        lastAcceptedStatusFactsByWorktreeId.removeAll(keepingCapacity: false)
        lastAcceptedLineDetailByWorktreeId.removeAll(keepingCapacity: false)
        lastAcceptedLineDetailAtByWorktreeId.removeAll(keepingCapacity: false)
        lastAcceptedStatusAtByWorktreeId.removeAll(keepingCapacity: false)
        consecutiveStatusFailureCountByWorktreeId.removeAll(keepingCapacity: false)
        nextPeriodicBatchSeqByWorktreeId.removeAll(keepingCapacity: false)
        emitUnreportedDroppedEnvelopeFacts(lifetime: subscriptionLifetime)
        subscriptionHandle = nil
        shutdownInProgress = false
        if let factSink, lastClosedFactLifetime != subscriptionLifetime {
            lastClosedFactLifetime = subscriptionLifetime
            factSink(.lifetime(subscriptionLifetime), .shutdownCompleted)
        }
    }

    private func handleAndRecordRuntimeEnvelope(_ envelope: RuntimeEnvelope, lifetime: UInt64) {
        let disposition = handleIncomingRuntimeEnvelope(envelope)
        didHandleRuntimeEnvelope(lifetime: lifetime, seq: envelope.seq, disposition: disposition)
    }

    private func handleIncomingRuntimeEnvelope(_ envelope: RuntimeEnvelope) -> GitProjectorEnvelopeDisposition {
        switch envelope {
        case .system(let systemEnvelope):
            guard systemEnvelope.source == .builtin(.filesystemWatcher) else { return .ignored }
            guard case .topology(let topologyEvent) = systemEnvelope.event else { return .ignored }
            switch topologyEvent {
            case .worktreeRegistered(let worktreeId, let repoId, let rootPath):
                let context = WorktreeFilesystemContext(repoId: repoId, rootPath: rootPath)
                guard acceptsLifecycleRegistration(worktreeId: worktreeId, context: context) else { return .ignored }
                applyRegistration(
                    worktreeId: worktreeId,
                    context: context,
                    timestamp: systemEnvelope.timestamp
                )
            case .worktreeUnregistered(let worktreeId, let repoId):
                guard latestTopologyAssertion == nil else { return .ignored }
                applyUnregistration(worktreeId: worktreeId, repoId: repoId)
            case .repoDiscovered, .reposDiscovered, .repoRemoved, .watchedFolderReconciled:
                return .ignored
            }
        case .worktree(let worktreeEnvelope):
            guard worktreeEnvelope.source == .system(.builtin(.filesystemWatcher)) else { return .ignored }
            guard case .filesystem(.filesChanged(let changeset)) = worktreeEnvelope.event else { return .ignored }
            let worktreeId = changeset.worktreeId
            observeIntakeFact(worktreeId: worktreeId, batchSeq: changeset.batchSeq)
            guard !suppressedWorktreeIds.contains(worktreeId) else {
                closeIntakeFactOnce(
                    worktreeId: worktreeId, batchSeq: changeset.batchSeq, fact: .changesetDropped(.stale))
                return .ignored
            }
            guard acceptsFilesystemChanges(changeset) else {
                closeIntakeFactOnce(
                    worktreeId: worktreeId, batchSeq: changeset.batchSeq, fact: .changesetDropped(.stale))
                return .ignored
            }
            if exactCleanAuthorityByWorktreeId.removeValue(forKey: worktreeId) != nil {
                recordExactCleanMutationInvalidatedTelemetry()
            }
            guard Self.shouldRefresh(for: changeset) else {
                aggregatePerformance.increment(\.suppressedInput)
                flushAggregatePerformanceSnapshotIfNeeded()
                closeIntakeFactOnce(
                    worktreeId: worktreeId, batchSeq: changeset.batchSeq, fact: .changesetDropped(.equal))
                return .ignored
            }
            guard admitFileChangeAfterQuarantine(worktreeId: worktreeId, rootPath: changeset.rootPath) else {
                closeIntakeFactOnce(
                    worktreeId: worktreeId, batchSeq: changeset.batchSeq, fact: .changesetDropped(.stale))
                return .ignored
            }
            repoIdByWorktreeId[worktreeId] = changeset.repoId
            if openStatusBackoffWorktreeIds.contains(worktreeId) {
                recordRequiredIntent(changeset: changeset, triggerSource: .filesystemChange)
                _ = deferChangesetIfStatusBackoffOpen(changeset)
                return .routed
            }
            if capacityRetryWorktreeIds.contains(worktreeId) {
                recordRequiredIntent(changeset: changeset, triggerSource: .filesystemChange)
                _ = deferChangesetIfCapacityRetryPending(changeset)
                return .routed
            }
            // A queued immediate full refresh covers changes observed before
            // it starts. Once its task is running, retain one merged pending
            // invalidation so later mutations cannot disappear behind it.
            if !immediateRefreshWorktreeIds.contains(worktreeId)
                || worktreeTasks[worktreeId] != nil
            {
                pendingByWorktreeId[worktreeId] = mergeTrackedChangesets(
                    pendingByWorktreeId[worktreeId],
                    with: changeset
                )
                recordRequiredIntent(changeset: changeset, triggerSource: .filesystemChange)
                refreshAttribution.triggerSourceByWorktreeId[worktreeId] = .filesystemChange
            } else if let coveringChangeset = pendingByWorktreeId[worktreeId] {
                recordRequiredIntent(
                    changeset: coveringChangeset,
                    triggerSource: .filesystemChange
                )
                closeIntakeFactOnce(worktreeId: worktreeId, batchSeq: changeset.batchSeq, fact: .changesetAccepted)
            }
            grantDemandEligibility(worktreeId: worktreeId)
            admitPendingWorktrees()
        case .pane:
            return .ignored
        }
        return .routed
    }

    package func assertTopology(_ assertion: FilesystemTopologyAssertion) {
        guard shouldApplyTopologyAssertion(assertion) else { return }

        let changedLifetimes = Set(
            assertion.worktreeLifetimes.keys.filter {
                observationLifetimesByWorktreeID[$0] != assertion.worktreeLifetimes[$0]
            })
        observationLifetimesByWorktreeID = assertion.worktreeLifetimes
        latestTopologyAssertion = assertion
        for worktreeID in changedLifetimes {
            guard let context = assertion.contextsByWorktreeId[worktreeID] else { continue }
            originResolutionByRepoId[context.repoId] = .awaitingResolution
        }

        let desiredWorktreeIds = Set(assertion.contextsByWorktreeId.keys)
        let removedWorktreeIds = Set(rootPathByWorktreeId.keys).subtracting(desiredWorktreeIds)
        for worktreeId in removedWorktreeIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            applyUnregistration(
                worktreeId: worktreeId,
                repoId: repoIdByWorktreeId[worktreeId] ?? worktreeId
            )
        }

        for (worktreeId, context) in assertion.contextsByWorktreeId.sorted(by: { lhs, rhs in
            lhs.key.uuidString < rhs.key.uuidString
        }) {
            let currentContext = registeredContext(for: worktreeId)
            let lifetimeChanged = changedLifetimes.contains(worktreeId)
            guard currentContext != context || lifetimeChanged else { continue }
            applyRegistration(
                worktreeId: worktreeId,
                context: context,
                timestamp: envelopeClock.now,
                forceRefresh: lifetimeChanged
            )
        }
    }

    package func refreshRegisteredWorktreesImmediately() {
        for worktreeId in rootPathByWorktreeId.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            exactCleanAuthorityByWorktreeId.removeValue(forKey: worktreeId)
            enqueueImmediateRefreshIfRegistered(
                worktreeId: worktreeId,
                triggerSource: .visibilityChange,
                isExplicit: true
            )
        }
    }

    package func refreshRegisteredWorktreesIntersecting(_ watchedPaths: [URL]) {
        let canonicalWatchedPaths = watchedPaths.map { watchedPath in
            FilesystemRootOwnership.canonicalRootPath(for: watchedPath)
        }
        for (worktreeId, rootPath) in rootPathByWorktreeId.sorted(by: { lhs, rhs in
            lhs.key.uuidString < rhs.key.uuidString
        }) {
            let canonicalRootPath = FilesystemRootOwnership.canonicalRootPath(for: rootPath)
            guard
                canonicalWatchedPaths.contains(where: { watchedPath in
                    Self.pathsIntersect(canonicalRootPath, watchedPath)
                })
            else { continue }
            exactCleanAuthorityByWorktreeId.removeValue(forKey: worktreeId)
            enqueueImmediateRefreshIfRegistered(
                worktreeId: worktreeId,
                triggerSource: .visibilityChange,
                isExplicit: true
            )
        }
    }

    func startDrainTask(worktreeId: UUID) {
        nextWorktreeTaskGeneration &+= 1
        let taskGeneration = nextWorktreeTaskGeneration
        worktreeTaskGenerationByWorktreeId[worktreeId] = taskGeneration
        let lifetime = observationLifetimesByWorktreeID[worktreeId]
        let refreshFactScope = openRefreshFactScopeByWorktreeId[worktreeId]
        let task = Task { [weak self] in
            guard let self else { return }
            await RepositoryObservationRequestContext.$worktree.withValue(lifetime) {
                await self.drainWorktree(
                    worktreeId: worktreeId, taskGeneration: taskGeneration,
                    refreshFactScope: refreshFactScope
                )
            }
        }
        worktreeTasks[worktreeId] = task
        outstandingDrainTasks[taskGeneration] = task
        Task { [weak self] in
            await task.value
            await self?.drainTaskDidExit(taskGeneration: taskGeneration)
        }
        recordLogicalDebtSnapshotIfChanged()
    }

    private func shouldApplyTopologyAssertion(_ assertion: FilesystemTopologyAssertion) -> Bool {
        guard let latestTopologyAssertion else { return true }
        guard assertion.generation >= latestTopologyAssertion.generation else { return false }
        guard
            assertion.generation != latestTopologyAssertion.generation
                || assertion.contextsByWorktreeId != latestTopologyAssertion.contextsByWorktreeId
        else {
            return false
        }
        return true
    }

    private func acceptsLifecycleRegistration(
        worktreeId: UUID,
        context: WorktreeFilesystemContext
    ) -> Bool {
        guard let latestTopologyAssertion else { return true }
        return latestTopologyAssertion.contextsByWorktreeId[worktreeId] == context
    }

    private func acceptsFilesystemChanges(_ changeset: FileChangeset) -> Bool {
        guard let latestTopologyAssertion else { return true }
        let context = WorktreeFilesystemContext(repoId: changeset.repoId, rootPath: changeset.rootPath)
        return latestTopologyAssertion.contextsByWorktreeId[changeset.worktreeId] == context
    }

    private func applyRegistration(
        worktreeId: UUID,
        context: WorktreeFilesystemContext,
        timestamp: ContinuousClock.Instant,
        forceRefresh: Bool = false
    ) {
        let previousContext = registeredContext(for: worktreeId)
        var endedGlobalCapacityPause = false
        guard previousContext != context || forceRefresh else {
            removeSuppressedWorktree(worktreeId)
            return
        }
        if previousContext != nil, previousContext != context || forceRefresh {
            settleRepositoryRecomputationTarget(
                worktreeId: worktreeId,
                requiredIntentGeneration: nil,
                outcome: .obsolete
            )
            if let previousContext {
                (gitWorkingTreeProvider as? any GitExactCleanStatusProviding)?.retireExactCleanAuthority(
                    worktreeId: worktreeId,
                    rootPath: previousContext.rootPath
                )
            }
            lastEmittedSnapshotByWorktreeId.removeValue(forKey: worktreeId)
            lastStatusEntriesByWorktreeId.removeValue(forKey: worktreeId)
            lastAcceptedStatusFactsByWorktreeId.removeValue(forKey: worktreeId)
            exactCleanAuthorityByWorktreeId.removeValue(forKey: worktreeId)
            lastAcceptedLineDetailByWorktreeId.removeValue(forKey: worktreeId)
            lastAcceptedLineDetailAtByWorktreeId.removeValue(forKey: worktreeId)
            lastAcceptedStatusAtByWorktreeId.removeValue(forKey: worktreeId)
            automaticRefreshDeadlineByWorktreeId.removeValue(forKey: worktreeId)
            cancelDeadlineFact(worktreeId: worktreeId, sourceKind: .automatic)
            lastAutomaticStartAtByWorktreeId.removeValue(forKey: worktreeId)
            lastAutomaticCompletionAtByWorktreeId.removeValue(forKey: worktreeId)
            lastAutomaticDutyByWorktreeId.removeValue(forKey: worktreeId)
            consecutiveStatusFailureCountByWorktreeId.removeValue(forKey: worktreeId)
            worktreeTasks.removeValue(forKey: worktreeId)?.cancel()
            worktreeTaskGenerationByWorktreeId.removeValue(forKey: worktreeId)
            endedGlobalCapacityPause = clearCapacityRetryState(worktreeId: worktreeId)
            clearStatusBackoffState(worktreeId: worktreeId)
            clearQuarantineState(worktreeId: worktreeId)
            clearValidatedRootPath(worktreeId: worktreeId)
            resetAdaptiveCadence(worktreeId: worktreeId)
            clearRequiredIntent(worktreeId: worktreeId)
            immediateRefreshWorktreeIds.remove(worktreeId)
            coalescingWorktreeIds.remove(worktreeId)
        }

        removeSuppressedWorktree(worktreeId)
        beginIntakeFactRegistration(worktreeId: worktreeId)
        repoIdByWorktreeId[worktreeId] = context.repoId
        rootPathByWorktreeId[worktreeId] = context.rootPath
        nextPeriodicBatchSeqByWorktreeId[worktreeId] = nextPeriodicBatchSeqByWorktreeId[worktreeId] ?? 0
        let registrationChangeset = FileChangeset(
            worktreeId: worktreeId,
            repoId: context.repoId,
            rootPath: context.rootPath,
            paths: [],
            containsGitInternalChanges: true,
            timestamp: timestamp,
            batchSeq: 0
        )
        observeIntakeFact(worktreeId: worktreeId, batchSeq: registrationChangeset.batchSeq)
        if isAutomaticEligible(worktreeId: worktreeId) {
            pendingByWorktreeId[worktreeId] = registrationChangeset
            refreshAttribution.triggerSourceByWorktreeId[worktreeId] = .registration
            scheduleAutomaticRefresh(
                worktreeId: worktreeId,
                missingBaseline: true,
                allowsPromptMissingBaseline: demandTier(for: worktreeId) != .background
            )
        } else if activePaneWorktreeId == worktreeId
            || activeWorktreeIds.contains(worktreeId)
            || sidebarVisibleWorktreeIds.contains(worktreeId)
        {
            enqueueAttendedMissingBaselineIfNeeded(worktreeId: worktreeId)
        }
        if endedGlobalCapacityPause {
            admitPendingWorktrees()
        }
    }

    private func applyUnregistration(worktreeId: UUID, repoId: UUID) {
        settleRepositoryRecomputationTarget(
            worktreeId: worktreeId,
            requiredIntentGeneration: nil,
            outcome: .obsolete
        )
        if let rootPath = rootPathByWorktreeId[worktreeId] {
            (gitWorkingTreeProvider as? any GitExactCleanStatusProviding)?.retireExactCleanAuthority(
                worktreeId: worktreeId,
                rootPath: rootPath
            )
        }
        addSuppressedWorktree(worktreeId)
        pendingByWorktreeId.removeValue(forKey: worktreeId)
        immediateRefreshWorktreeIds.remove(worktreeId)
        explicitRefreshWorktreeIds.remove(worktreeId)
        tierEligibleWorktreeIds.remove(worktreeId)
        admittedDemandTierByWorktreeId.removeValue(forKey: worktreeId)
        admissionStartedAtByWorktreeId.removeValue(forKey: worktreeId)
        coalescingWorktreeIds.remove(worktreeId)
        activeWorktreeIds.remove(worktreeId)
        sidebarVisibleWorktreeIds.remove(worktreeId)
        automaticEligibleWorktreeIds?.remove(worktreeId)
        backgroundOnlyAutomaticWorktreeIds.remove(worktreeId)
        lastProcessedSidebarVisibleWorktreeIds.remove(worktreeId)
        pendingVisibilityDeltaWorktreeIds.remove(worktreeId)
        if activePaneWorktreeId == worktreeId {
            activePaneWorktreeId = nil
        }
        repoIdByWorktreeId.removeValue(forKey: worktreeId)
        rootPathByWorktreeId.removeValue(forKey: worktreeId)
        lastEmittedSnapshotByWorktreeId.removeValue(forKey: worktreeId)
        lastStatusEntriesByWorktreeId.removeValue(forKey: worktreeId)
        lastAcceptedStatusFactsByWorktreeId.removeValue(forKey: worktreeId)
        exactCleanAuthorityByWorktreeId.removeValue(forKey: worktreeId)
        lastAcceptedLineDetailByWorktreeId.removeValue(forKey: worktreeId)
        lastAcceptedLineDetailAtByWorktreeId.removeValue(forKey: worktreeId)
        lastAcceptedStatusAtByWorktreeId.removeValue(forKey: worktreeId)
        automaticRefreshDeadlineByWorktreeId.removeValue(forKey: worktreeId)
        cancelDeadlineFact(worktreeId: worktreeId, sourceKind: .automatic)
        lastAutomaticStartAtByWorktreeId.removeValue(forKey: worktreeId)
        lastAutomaticCompletionAtByWorktreeId.removeValue(forKey: worktreeId)
        lastAutomaticDutyByWorktreeId.removeValue(forKey: worktreeId)
        consecutiveStatusFailureCountByWorktreeId.removeValue(forKey: worktreeId)
        clearStatusBackoffState(worktreeId: worktreeId)
        clearQuarantineState(worktreeId: worktreeId)
        clearValidatedRootPath(worktreeId: worktreeId)
        resetAdaptiveCadence(worktreeId: worktreeId)
        clearRequiredIntent(worktreeId: worktreeId)
        nextPeriodicBatchSeqByWorktreeId.removeValue(forKey: worktreeId)
        retireIntakeFactRegistration(worktreeId: worktreeId)
        if !repoIdByWorktreeId.values.contains(repoId) {
            lastKnownOriginByRepoId.removeValue(forKey: repoId)
            originResolutionByRepoId.removeValue(forKey: repoId)
            remoteReferenceAcceptanceByRepoId.removeValue(forKey: repoId)
        }
        if let task = worktreeTasks.removeValue(forKey: worktreeId) {
            task.cancel()
        }
        worktreeTaskGenerationByWorktreeId.removeValue(forKey: worktreeId)
        let endedGlobalCapacityPause = clearCapacityRetryState(worktreeId: worktreeId)
        if endedGlobalCapacityPause {
            admitPendingWorktrees()
        }
        rescheduleDeadlineTask()
        recordLogicalDebtSnapshotIfChanged()
    }

    private func addSuppressedWorktree(_ worktreeId: UUID) {
        guard suppressedWorktreeIds.insert(worktreeId).inserted else { return }
        suppressedWorktreeOrder.append(worktreeId)
        while suppressedWorktreeOrder.count > refreshPolicy.suppressedWorktreeTombstoneLimit {
            let evictedWorktreeId = suppressedWorktreeOrder.removeFirst()
            suppressedWorktreeIds.remove(evictedWorktreeId)
        }
    }

    private func removeSuppressedWorktree(_ worktreeId: UUID) {
        guard suppressedWorktreeIds.remove(worktreeId) != nil else { return }
        suppressedWorktreeOrder.removeAll { $0 == worktreeId }
    }

    func clearImmediateRefreshIntent(worktreeId: UUID) {
        immediateRefreshWorktreeIds.remove(worktreeId)
        explicitRefreshWorktreeIds.remove(worktreeId)
    }

    private func drainWorktree(
        worktreeId: UUID, taskGeneration: UInt64, refreshFactScope: GitProjectorScope?
    ) async {
        defer {
            if !capacityRetryWorktreeIds.contains(worktreeId) {
                let outcome: GitProjectorRefreshOutcome =
                    isShuttingDown ? .shutdown : Task.isCancelled ? .cancelled : .superseded
                closeRefreshFact(worktreeId: worktreeId, ifCurrent: refreshFactScope, outcome: outcome)
            }
            if worktreeTaskGenerationByWorktreeId[worktreeId] == taskGeneration {
                worktreeTasks.removeValue(forKey: worktreeId)
                worktreeTaskGenerationByWorktreeId.removeValue(forKey: worktreeId)
                if !capacityRetryWorktreeIds.contains(worktreeId) {
                    admittedDemandTierByWorktreeId.removeValue(forKey: worktreeId)
                    clearValidatedRootPath(worktreeId: worktreeId)
                }
                admitPendingWorktrees()
                recordLogicalDebtSnapshotIfChanged()
            }
        }

        guard !Task.isCancelled else { return }
        guard !capacityRetryWorktreeIds.contains(worktreeId) else { return }
        guard var nextChangeset = pendingByWorktreeId.removeValue(forKey: worktreeId) else {
            return
        }
        admitPendingRequiredIntent(worktreeId: worktreeId)
        recordLogicalDebtSnapshotIfChanged()
        let shouldCoalesce = immediateRefreshWorktreeIds.remove(worktreeId) == nil && coalescingWindow > .zero
        if shouldCoalesce {
            coalescingWorktreeIds.insert(worktreeId)
            let coalescingScope = GitProjectorScope.deadline(
                worktreeId: worktreeId,
                kind: .coalescingWindow,
                generation: taskGeneration
            )
            factSink?(coalescingScope, .deadlineRegistered(.coalescingWindow))
            do {
                try await delay.wait(coalescingWindow)
            } catch is CancellationError {
                coalescingWorktreeIds.remove(worktreeId)
                factSink?(coalescingScope, .deadlineDisposition(.cancelled))
                return
            } catch {
                coalescingWorktreeIds.remove(worktreeId)
                factSink?(coalescingScope, .deadlineDisposition(.cancelled))
                Self.logger.warning(
                    "Unexpected projector sleep failure for worktree \(worktreeId.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            coalescingWorktreeIds.remove(worktreeId)
            guard !Task.isCancelled else {
                factSink?(coalescingScope, .deadlineDisposition(.cancelled))
                return
            }
            if let newer = pendingByWorktreeId.removeValue(forKey: worktreeId) {
                admitPendingRequiredIntent(worktreeId: worktreeId)
                recordLogicalDebtSnapshotIfChanged()
                nextChangeset = mergeTrackedChangesets(nextChangeset, with: newer)
                closeIntakeFactOnce(
                    worktreeId: worktreeId,
                    batchSeq: nextChangeset.batchSeq,
                    fact: .changesetAccepted
                )
                _ = immediateRefreshWorktreeIds.remove(worktreeId)
            }
            factSink?(coalescingScope, .deadlineDisposition(.admitted))
        }

        await computeAndEmit(changeset: nextChangeset, refreshFactScope: refreshFactScope)
    }

    func isCurrent(_ changeset: FileChangeset) -> Bool {
        let changesetContext = WorktreeFilesystemContext(repoId: changeset.repoId, rootPath: changeset.rootPath)
        guard let registeredContext = registeredContext(for: changeset.worktreeId) else {
            guard let latestTopologyAssertion else { return true }
            return latestTopologyAssertion.contextsByWorktreeId[changeset.worktreeId] == changesetContext
        }
        return registeredContext == changesetContext
    }

    func isCurrentForPublication(_ changeset: FileChangeset) -> Bool {
        guard isCurrent(changeset) else { return false }
        guard let pending = pendingByWorktreeId[changeset.worktreeId] else { return true }
        return pending.batchSeq <= changeset.batchSeq
    }

    func shouldCheckOrigin(for changeset: FileChangeset) -> Bool {
        if changeset.paths.isEmpty {
            return true
        }
        return changeset.paths.contains(where: Self.isGitConfigPath)
    }

    nonisolated private static func shouldRefresh(for changeset: FileChangeset) -> Bool {
        !changeset.paths.isEmpty
            || changeset.containsGitInternalChanges
            || changeset.suppressedGitInternalPathCount > 0
    }

    nonisolated private static func isGitConfigPath(_ relativePath: String) -> Bool {
        let normalizedPath =
            relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalizedPath == ".git/config" || normalizedPath.hasSuffix("/.git/config")
    }

}
