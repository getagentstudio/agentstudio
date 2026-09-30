import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

protocol RepositoryFactUpdateStarting: AnyObject, Sendable {
    func startRepositoryFactUpdate(repoId: UUID, attemptId: UUID) async -> RepositoryFactUpdateAdmissionBatch
}

struct RepositoryFactUpdateSourceAdmissionHandler: Sendable {
    let source: RepositoryFactSource
    let admit: @Sendable (UUID, UUID) async -> RepositoryFactSourceUpdateAdmission

    init(
        source: RepositoryFactSource,
        admit: @escaping @Sendable (UUID, UUID) async -> RepositoryFactSourceUpdateAdmission
    ) {
        self.source = source
        self.admit = admit
    }
}

struct RepositoryFactUpdateAdmissionBatch: Sendable {
    let acceptedLeasesBySource: [RepositoryFactSource: RepositoryFactSourceUpdateLease]
    let terminalResultsBySource: [RepositoryFactSource: RepositoryFactUpdateSourceResult]

    init(admissionsBySource: [RepositoryFactSource: RepositoryFactSourceUpdateAdmission]) {
        var acceptedLeasesBySource: [RepositoryFactSource: RepositoryFactSourceUpdateLease] = [:]
        var terminalResultsBySource: [RepositoryFactSource: RepositoryFactUpdateSourceResult] = [:]
        for (source, admission) in admissionsBySource {
            switch admission {
            case .accepted(let lease):
                acceptedLeasesBySource[source] = lease
            case .notApplicable:
                terminalResultsBySource[source] = .notApplicable
            case .obsolete:
                terminalResultsBySource[source] = .obsolete
            }
        }
        self.acceptedLeasesBySource = acceptedLeasesBySource
        self.terminalResultsBySource = terminalResultsBySource
    }

    var acceptedSources: Set<RepositoryFactSource> {
        Set(acceptedLeasesBySource.keys)
    }

    func settlement() async -> [RepositoryFactSource: RepositoryFactSourceUpdateOutcome] {
        await withTaskGroup(
            of: (RepositoryFactSource, RepositoryFactSourceUpdateOutcome).self,
            returning: [RepositoryFactSource: RepositoryFactSourceUpdateOutcome].self
        ) { group in
            for (source, lease) in acceptedLeasesBySource {
                group.addTask {
                    (source, await lease.settlement())
                }
            }
            var outcomesBySource: [RepositoryFactSource: RepositoryFactSourceUpdateOutcome] = [:]
            for await (source, outcome) in group {
                outcomesBySource[source] = outcome
            }
            return outcomesBySource
        }
    }
}

protocol WatchedFolderCommandHandling: AnyObject, Sendable {
    func refreshWatchedFolders(_ watchedPaths: [WatchedPath]) async -> WatchedFolderRefreshSummary
    func filesystemLogicalDebtCount() async -> Int
    func refreshRegisteredWorktreesAndWatchedFolders(
        _ watchedPaths: [WatchedPath]
    ) async -> WatchedFolderRefreshSummary
}

/// Composition root for app-wide filesystem facts + derived local git facts.
///
/// `FilesystemActor` owns filesystem ingestion/routing and emits filesystem facts.
/// `GitWorkingDirectoryProjector` subscribes to those facts and emits git snapshot projections.
final class FilesystemGitPipeline: WorkspaceFilesystemSourceManaging, WatchedFolderCommandHandling,
    RepositoryFactUpdateStarting, Sendable
{
    private let scopeMutationOrder = FilesystemPipelineScopeOrder()
    private let filesystemActor: FilesystemActor
    private let gitWorkingDirectoryProjector: GitWorkingDirectoryProjector
    private let remoteReferenceRefreshActor: RemoteReferenceRefreshActor
    private let forgeActor: ForgeActor
    private let registrationValidator: GitWorktreeRegistrationValidator
    private let repositoryFactDemandPerformanceRecorder: (any RepositoryFactDemandPerformanceRecording)?

    init(
        bus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        registrationDiscoveryProvider: any RepoScanner.GitRepositoryDiscoveryProvider =
            RepoScannerGitDiscoveryClient(),
        gitWorkingTreeProvider: any GitWorkingTreeStatusProvider,
        remoteReferenceRefreshProvider: any RemoteReferenceRefreshProviding =
            AgentStudioGitRemoteReferenceRefreshProvider(),
        forgeStatusProvider: any ForgeStatusProvider = GitHubCLIForgeStatusProvider(),
        fseventStreamClient: any FSEventStreamClient = DarwinFSEventStreamClient(),
        watchedFolderScanScheduler: WatchedFolderScanScheduler = .production(),
        repositoryLocalActivityProjector: RepositoryLocalActivityProjector? = nil,
        filesystemDebounceWindow: Duration = AppPolicies.GitRefresh.filesystemDebounceWindow,
        filesystemMaxFlushLatency: Duration = AppPolicies.GitRefresh.filesystemMaxFlushLatency,
        gitCoalescingWindow: Duration = AppPolicies.GitRefresh.filesystemDerivedCoalescingWindow,
        gitRefreshPolicy: AppPolicies.GitRefresh.Policy = AppPolicies.GitRefresh.defaultPolicy,
        gitSleepClock: any Clock<Duration> & Sendable = ContinuousClock(),
        projectorFactSink: GitProjectorFactSink? = nil,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        repositoryFactDemandPerformanceRecorder:
            (any RepositoryFactDemandPerformanceRecording)? = nil
    ) {
        self.repositoryFactDemandPerformanceRecorder =
            repositoryFactDemandPerformanceRecorder ?? performanceTraceRecorder
        self.filesystemActor = FilesystemActor(
            bus: bus,
            fseventStreamClient: fseventStreamClient,
            repositoryLocalActivityProjector: repositoryLocalActivityProjector,
            watchedFolderScanScheduler: watchedFolderScanScheduler,
            debounceWindow: filesystemDebounceWindow,
            maxFlushLatency: filesystemMaxFlushLatency,
            performanceTraceRecorder: performanceTraceRecorder
        )
        let remoteReferenceAuthoritySink = RemoteReferenceAuthoritySink()
        let remoteReferenceRefreshActor = RemoteReferenceRefreshActor(
            provider: remoteReferenceRefreshProvider,
            performanceRecorder: performanceTraceRecorder,
            onAuthorityUpdate: { update in
                await remoteReferenceAuthoritySink.send(update)
            },
            onPromotedRecomputation: { acceptance in
                await remoteReferenceAuthoritySink.waitForRecomputation(
                    acceptance: acceptance
                )
            }
        )
        self.remoteReferenceRefreshActor = remoteReferenceRefreshActor
        let gitWorkingDirectoryProjector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: gitWorkingTreeProvider,
            coalescingWindow: gitCoalescingWindow,
            sleepClock: gitSleepClock,
            refreshPolicy: gitRefreshPolicy,
            performanceTraceRecorder: performanceTraceRecorder,
            factSink: projectorFactSink,
            remoteReferenceOriginHandler: { repoId, expectedOrigin, expectedLifetime in
                await remoteReferenceRefreshActor.setOrigin(
                    repoId: repoId, expectedOrigin: expectedOrigin, expectedLifetime: expectedLifetime)
            },
            pathExistenceProbe: GitWorkingDirectoryProjector.liveRootPathProbe
        )
        self.gitWorkingDirectoryProjector = gitWorkingDirectoryProjector
        remoteReferenceAuthoritySink.install { update in
            await gitWorkingDirectoryProjector.applyRemoteReferenceAuthorityUpdate(update)
        } waitForRecomputation: { acceptance in
            await gitWorkingDirectoryProjector.startAndWaitForRemoteReferenceRecomputation(
                acceptance: acceptance
            )
        }
        self.registrationValidator = GitWorktreeRegistrationValidator(
            discoveryProvider: registrationDiscoveryProvider
        )
        self.forgeActor = ForgeActor(
            bus: bus,
            statusProvider: forgeStatusProvider,
            providerName: "github",
            performanceTraceRecorder: performanceTraceRecorder
        )
    }

    func start() async {
        await startFilesystemActor()
        await startGitProjector()
        await startForgeActor()
    }

    func startFilesystemActor() async {
        await filesystemActor.start()
    }

    func startGitProjector() async {
        await gitWorkingDirectoryProjector.start()
    }

    func startForgeActor() async {
        await forgeActor.start()
    }

    func shutdown() async {
        await forgeActor.setDemand(worktreeIds: [])
        await remoteReferenceRefreshActor.setDemand(repositoryIds: [])
        await remoteReferenceRefreshActor.shutdown()
        await gitWorkingDirectoryProjector.shutdown()
        await filesystemActor.shutdown()
        await forgeActor.shutdown()
    }

    func register(worktreeId: UUID, repoId: UUID, rootPath: URL) async {
        await scopeMutationOrder.perform { [self] in
            await performRegister(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
        }
    }

    private func performRegister(worktreeId: UUID, repoId: UUID, rootPath: URL) async {
        // Ensure projector subscription is active before lifecycle facts are posted.
        await startGitProjector()
        await startForgeActor()
        let context = WorktreeFilesystemContext(repoId: repoId, rootPath: rootPath)
        switch await registrationValidator.registrationDecision(context: context) {
        case .validated:
            break
        case .authoritativeNegative:
            await forgeActor.unregister(worktreeId: worktreeId)
            await remoteReferenceRefreshActor.unregister(worktreeId: worktreeId)
            await filesystemActor.unregister(worktreeId: worktreeId)
            return
        }
        await remoteReferenceRefreshActor.register(
            repoId: repoId,
            worktreeId: worktreeId,
            repositoryPath: rootPath,
            remoteName: "origin",
            expectedOrigin: nil
        )
        await forgeActor.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
        await filesystemActor.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
    }

    func unregister(worktreeId: UUID) async {
        await scopeMutationOrder.perform { [self] in
            await performUnregister(worktreeId: worktreeId)
        }
    }

    private func performUnregister(worktreeId: UUID) async {
        await forgeActor.unregister(worktreeId: worktreeId)
        await remoteReferenceRefreshActor.unregister(worktreeId: worktreeId)
        await filesystemActor.unregister(worktreeId: worktreeId)
    }

    func assertTopology(_ assertion: FilesystemTopologyAssertion) async {
        await scopeMutationOrder.perform(topologyGeneration: assertion.generation) { [self] in
            await performTopologyAssertion(assertion)
        }
    }

    func scopeMutationSubmissionCount() async -> UInt64 { await scopeMutationOrder.submissionCount }

    private func performTopologyAssertion(_ assertion: FilesystemTopologyAssertion) async {
        await startGitProjector()
        await filesystemActor.assertTopology(assertion)
        await remoteReferenceRefreshActor.assertTopology(assertion)
        await forgeActor.assertObservationLifetimes(assertion)
        await gitWorkingDirectoryProjector.assertTopology(assertion)
    }

    func setRepositoryFactDemand(_ snapshot: RepositoryFactDemandSnapshot) async {
        await filesystemActor.setRepositoryFactAttention(
            activePaneWorktreeId: snapshot.activePaneWorktreeId,
            openWorktreeIds: snapshot.openWorktreeIds
        )
        await gitWorkingDirectoryProjector.setRepositoryFactAttention(
            activePaneWorktreeId: snapshot.activePaneWorktreeId,
            sidebarAttendedWorktreeIds: snapshot.sidebarAttendedWorktreeIds,
            visibleActiveTabWorktreeIds: snapshot.visibleActiveTabWorktreeIds,
            openWorktreeIds: snapshot.openWorktreeIds,
            warmAutomaticWorktreeIds: snapshot.automaticLocalGitWorktreeIds,
            backgroundOnlyAutomaticWorktreeIds: snapshot.backgroundOnlyAutomaticWorktreeIds
        )
        await remoteReferenceRefreshActor.setDemand(repositoryIds: snapshot.demandedRepositoryIds)
        await forgeActor.setDemand(worktreeIds: snapshot.forgeDemandedWorktreeIds)
        guard let repositoryFactDemandPerformanceRecorder else { return }
        let appliedBackgroundOnlyAutomaticWorktreeIds =
            await gitWorkingDirectoryProjector.appliedBackgroundOnlyAutomaticWorktreeIds()
        let appliedRemoteDemandRepositoryIds =
            await remoteReferenceRefreshActor.appliedAutomaticDemandRepositoryIds()
        let appliedForgeDemandWorktreeIds =
            await forgeActor.appliedAutomaticDemandWorktreeIds()
        repositoryFactDemandPerformanceRecorder.recordRepositoryFactDemandPerformanceSnapshot(
            Self.appliedDemandPerformanceSnapshot(
                snapshot: snapshot,
                backgroundOnlyAutomaticWorktreeIds: appliedBackgroundOnlyAutomaticWorktreeIds,
                remoteDemandRepositoryIds: appliedRemoteDemandRepositoryIds,
                forgeDemandWorktreeIds: appliedForgeDemandWorktreeIds
            )
        )
    }

    static func appliedDemandPerformanceSnapshot(
        snapshot: RepositoryFactDemandSnapshot,
        backgroundOnlyAutomaticWorktreeIds: Set<UUID>,
        remoteDemandRepositoryIds: Set<UUID>,
        forgeDemandWorktreeIds: Set<UUID>
    ) -> RepositoryFactDemandPerformanceSnapshot {
        var performance = RepositoryFactDemandPerformanceSnapshot()
        performance.applied = 1
        performance.appliedUnknownWorktreeCurrent = UInt64(snapshot.unknownWorktreeIds.count)
        performance.appliedUnknownBackgroundOnlyCurrent = UInt64(
            snapshot.unknownWorktreeIds.intersection(backgroundOnlyAutomaticWorktreeIds).count
        )
        performance.appliedUnknownRemoteDemandCurrent = UInt64(
            snapshot.unknownRepositoryIds.intersection(remoteDemandRepositoryIds).count
        )
        performance.appliedUnknownForgeDemandCurrent = UInt64(
            snapshot.unknownWorktreeIds.intersection(forgeDemandWorktreeIds).count
        )
        return performance
    }

    func waitForRepositoryFactDemandAdmission() async {
        await gitWorkingDirectoryProjector.waitForVisibilityAdmission()
    }

    func startRepositoryFactUpdate(
        repoId: UUID,
        attemptId: UUID
    ) async -> RepositoryFactUpdateAdmissionBatch {
        await Self.admitRepositoryFactUpdateSources(
            repoId: repoId,
            attemptId: attemptId,
            handlers: [
                RepositoryFactUpdateSourceAdmissionHandler(source: .remoteReferences) { [self] repoId, attemptId in
                    await remoteReferenceRefreshActor.startExplicitRepositoryUpdate(
                        repoId: repoId,
                        attemptId: attemptId
                    )
                }
            ]
        )
    }

    static func admitRepositoryFactUpdateSources(
        repoId: UUID,
        attemptId: UUID,
        handlers: [RepositoryFactUpdateSourceAdmissionHandler]
    ) async -> RepositoryFactUpdateAdmissionBatch {
        let admissionsBySource = await withTaskGroup(
            of: (RepositoryFactSource, RepositoryFactSourceUpdateAdmission).self,
            returning: [RepositoryFactSource: RepositoryFactSourceUpdateAdmission].self
        ) { group in
            for handler in handlers {
                group.addTask {
                    (
                        handler.source,
                        await handler.admit(repoId, attemptId)
                    )
                }
            }
            var admissionsBySource: [RepositoryFactSource: RepositoryFactSourceUpdateAdmission] = [:]
            for await (source, admission) in group {
                admissionsBySource[source] = admission
            }
            return admissionsBySource
        }
        return RepositoryFactUpdateAdmissionBatch(admissionsBySource: admissionsBySource)
    }

    func enqueueRawPathsForTesting(worktreeId: UUID, paths: [String]) async {
        await filesystemActor.enqueueRawPaths(worktreeId: worktreeId, paths: paths)
    }

    func refreshWatchedFolders(_ watchedPaths: [WatchedPath]) async -> WatchedFolderRefreshSummary {
        let summary = await filesystemActor.refreshWatchedFolders(watchedPaths)
        if watchedPaths.isEmpty {
            await gitWorkingDirectoryProjector.refreshRegisteredWorktreesImmediately()
        } else {
            await gitWorkingDirectoryProjector.refreshRegisteredWorktreesIntersecting(watchedPaths.map(\.path))
        }
        return summary
    }

    func refreshForRepositoryRetention(
        watchedPaths: [WatchedPath], repositories: [Repo], membershipRevision: UInt64, scanning scopeIDs: Set<UUID>
    ) async -> [WatchedFolderTopologyReceipt] {
        _ = await filesystemActor.refreshWatchedFolders(
            watchedPaths, restoring: repositories, membershipRevision: membershipRevision, scanning: scopeIDs)
        return await filesystemActor.currentWatchedFolderObservationReceipts()
    }

    func areCurrentWatchedFolderObservations(_ observations: [WatchedFolderTopologyObservation]) async -> Bool {
        await filesystemActor.areCurrentWatchedFolderObservations(observations)
    }

    func filesystemLogicalDebtCount() async -> Int {
        await filesystemActor.logicalDebtCount()
    }

    func gitLogicalDebtSnapshot() async -> GitLogicalDebtSnapshot {
        await gitWorkingDirectoryProjector.logicalDebtSnapshot()
    }

    func refreshRegisteredWorktreesAndWatchedFolders(
        _ watchedPaths: [WatchedPath]
    ) async -> WatchedFolderRefreshSummary {
        let summary = await filesystemActor.refreshWatchedFolders(watchedPaths)
        await gitWorkingDirectoryProjector.refreshRegisteredWorktreesImmediately()
        return summary
    }

    func applyScopeChange(_ change: ScopeChange) async {
        switch change {
        case .registerForgeRepo(let repoId, let remote, let expectedLifetime):
            guard
                await remoteReferenceRefreshActor.setOrigin(
                    repoId: repoId, expectedOrigin: remote, expectedLifetime: expectedLifetime
                )
            else { return }
            await forgeActor.setOrigin(repo: repoId, remote: remote)
        case .unregisterForgeRepo(let repoId, let expectedLifetime):
            await scopeMutationOrder.perform { [self] in
                guard await forgeActor.removeRepository(repo: repoId, expectedLifetime: expectedLifetime) else {
                    return
                }
                await remoteReferenceRefreshActor.setOrigin(
                    repoId: repoId, expectedOrigin: nil, expectedLifetime: expectedLifetime)
            }
        case .refreshForgeRepo(let repoId, let correlationId):
            await remoteReferenceRefreshActor.refresh(repoId: repoId)
            await forgeActor.refresh(repo: repoId, correlationId: correlationId)
        case .updateRepositoryScanBaseline(let repositories, let revision):
            await filesystemActor.updateRepositoryScanBaseline(repositories, membershipRevision: revision)
        case .updateWatchedFolders(let watchedPaths, let repositories, let revision):
            _ = await filesystemActor.refreshWatchedFolders(
                watchedPaths, restoring: repositories, membershipRevision: revision)
        }
    }
}

extension FilesystemGitPipeline: WorktreePublicationHolding {
    func holdPublication(of destination: URL) async -> WatchedFolderPublicationHoldID {
        await filesystemActor.holdWatchedFolderPublication(of: destination)
    }

    func releasePublicationHold(_ holdID: WatchedFolderPublicationHoldID) async {
        await filesystemActor.releaseWatchedFolderPublicationHold(holdID)
    }

    func refreshWatchedFolder(_ watchedPathID: UUID, among watchedPaths: [WatchedPath]) async {
        _ = await filesystemActor.refreshWatchedFolders(watchedPaths, scanning: [watchedPathID])
    }
}

private final class RemoteReferenceAuthoritySink: @unchecked Sendable {
    typealias Handler = @Sendable (RemoteReferenceAuthorityUpdate) async -> Void
    typealias RecomputationHandler =
        @Sendable (RemoteReferenceAcceptance) async ->
        RepositoryFactSourceUpdateOutcome

    private let lock = NSLock()
    private var handler: Handler?
    private var recomputationHandler: RecomputationHandler?

    func install(
        _ handler: @escaping Handler,
        waitForRecomputation recomputationHandler: @escaping RecomputationHandler
    ) {
        lock.lock()
        self.handler = handler
        self.recomputationHandler = recomputationHandler
        lock.unlock()
    }

    func send(_ update: RemoteReferenceAuthorityUpdate) async {
        let handler = lock.withLock { self.handler }
        await handler?(update)
    }

    func waitForRecomputation(
        acceptance: RemoteReferenceAcceptance
    ) async -> RepositoryFactSourceUpdateOutcome {
        let handler = lock.withLock { recomputationHandler }
        guard let handler else { return .obsolete }
        return await handler(acceptance)
    }
}

enum GitWorktreeRegistrationDecision: Sendable, Equatable {
    case validated
    case authoritativeNegative
}

actor GitWorktreeRegistrationValidator {
    private let discoveryProvider: any RepoScanner.GitRepositoryDiscoveryProvider

    init(
        discoveryProvider: any RepoScanner.GitRepositoryDiscoveryProvider =
            RepoScannerGitDiscoveryClient()
    ) {
        self.discoveryProvider = discoveryProvider
    }

    /// A single discovery probe per worktree. Only evidence that the exact candidate path is
    /// certainly not a git repository rejects registration. Every other outcome — a probe
    /// timeout, cancellation, or service failure, and worktree-metadata drift such as a
    /// symlinked path variant or a stale main-worktree pointer — registers the worktree
    /// provisionally so the row starts scanning instead of stalling forever. The existing
    /// status backoff and honesty threshold in `GitWorkingDirectoryProjector` surface any real,
    /// persistent failure once the worktree is registered.
    func registrationDecision(
        context: WorktreeFilesystemContext
    ) async -> GitWorktreeRegistrationDecision {
        switch await discoveryProvider.discoveryOutcome(for: context.rootPath) {
        case .validated, .timeout, .cancelled, .failure:
            return .validated
        case .authoritativeNegative(let reason):
            return Self.isCertainNonRepository(reason) ? .authoritativeNegative : .validated
        }
    }

    /// Reasons that are true "this path is not a git repository" evidence from libgit2. All
    /// other authoritative-negative reasons describe worktree metadata drift (canonicalized path
    /// variants, a stale main-worktree pointer, a submodule worktree) rather than repository
    /// absence, and must not reject registration.
    private static func isCertainNonRepository(
        _ reason: GitRepositoryAuthoritativeNegativeReason
    ) -> Bool {
        switch reason {
        case .exactCandidateIsNotRepository, .invalidRepository, .invalidWorktreeRegistration,
            .bareRepository, .notAValidWorktree:
            return true
        case .canonicalPathMismatch, .submoduleWorktree, .mainWorktreeMismatch:
            return false
        }
    }
}
