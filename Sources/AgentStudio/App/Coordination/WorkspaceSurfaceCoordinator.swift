import AgentStudioBridge
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit
import Foundation
import GhosttyKit
import os.log

@MainActor
protocol WorkspaceSurfaceManaging: AnyObject {
    func syncFocus(activeSurfaceId: UUID?)

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError>

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView?
    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason)
    func undoClose(forPaneId paneId: UUID) -> ManagedSurface?
    func destroy(_ surfaceId: UUID)
    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>)
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>)
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>)

    /// Registers (or clears, passing `nil`) a handler fired whenever attached-surface
    /// membership changes (attach/detach/move/swap/destroy).
    func setAttachedBindingsChangeHandler(_ handler: (() -> Void)?)

    /// Reconciles renderer visibility for every attached surface against `visibilityForPaneID`.
    func reconcileAttachedVisibility(
        _ visibilityForPaneID: (UUID) -> Bool
    ) -> SurfaceVisibilityReconciliationResult
}

extension SurfaceManager: WorkspaceSurfaceManaging {}

struct WorkspaceSurfaceIPCLifecycle {
    let environment: @MainActor (UUID, UUID) -> [String: String]
    let invalidatePaneIDs: @MainActor (Set<UUID>) -> Void
    let finalRevokePaneIDs: @MainActor (Set<UUID>) -> Void
}

@MainActor
final class WorkspaceSurfaceCoordinator {
    nonisolated static let logger = Logger(subsystem: "com.agentstudio", category: "WorkspaceSurfaceCoordinator")

    struct ZoomCompanionContinuity {
        let surface: BridgeProductSurface
        let visibility: ZoomViewerVisibility
    }

    struct SwitchArrangementTransitions: Equatable {
        let hiddenPaneIds: Set<UUID>
        let paneIdsToReattach: Set<UUID>
    }

    let store: WorkspaceStore
    var paneActivityClock: PaneActivityClock?
    let undoClock: @Sendable () async throws -> WorkspaceUndoJournalTime
    let undoDelay: AsyncDelay
    let undoDeadlineWakeups = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var undoDeadlineTask: Task<Void, Never>?
    let terminalSessionCleanupWakeups = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var terminalSessionCleanupTask: Task<Void, Never>?
    var terminalSessionCleanupStopped = false
    var workspaceActionSubmission: (@MainActor (WorkspaceActionCommand) -> Void)?
    let viewRegistry: ViewRegistry
    let runtime: SessionRuntime
    let surfaceManager: WorkspaceSurfaceManaging
    let startupTraceRecorder: AgentStudioStartupTraceRecorder?
    let runtimeRegistry: RuntimeRegistry
    let visibilityTierResolver: StoreVisibilityTierResolver
    let runtimeEventReducer: NotificationReducer
    let paneEventBus: EventBus<RuntimeEnvelope>
    let runtimeTargetResolver: RuntimeTargetResolver
    let runtimeCommandClock: ContinuousClock
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let bridgeGitReadScheduler: BridgeGitReadScheduler
    let worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator
    let worktreeAnnotationStore: WorktreeAnnotationServiceActor?
    let worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor?
    let gitWorkingTreeStatusProvider: any GitWorkingTreeStatusProvider
    let gitStatusPhysicalGate: AgentStudioGitStatusPhysicalGate
    let filesystemSource: any WorkspaceFilesystemSourceManaging
    let filesystemProjectionIndex: any WorkspaceFilesystemProjectionIndexing
    let windowLifecycleStore: WindowLifecycleAtom
    let appLifecycleStore: AppLifecycleAtom
    let bridgePaneAttendance: BridgePaneAttendanceAtom
    let traceRuntime: AgentStudioTraceRuntime?
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    let traceIdentityRefreshHandler: (@MainActor @Sendable () -> Void)?
    let ipcLifecycle: WorkspaceSurfaceIPCLifecycle
    #if DEBUG
        var bridgeReviewSourceProviderOverridesByPaneId: [UUID: any BridgeReviewSourceProvider] = [:]
    #endif
    var awaitTopologyMutationAdmission: @MainActor () async -> Void = {}
    var removeRepoHandler: @MainActor (UUID) -> Void = { _ in }
    var preparedContentVisibilitySignalHandler: @MainActor (PreparedContentVisibleQueuedSet) -> Set<PaneId> = { _ in
        []
    }
    /// The generation of the currently accepted composition, threaded from
    /// the installed prepared-content mount owners once boot installs them
    /// (`AppDelegate+WorkspaceBoot.swift`). `nil` only in the brief pre-boot
    /// window and in test harnesses that never install a cohort.
    var acceptedPreparedContentMountGeneration: WorkspaceContentMountGeneration?
    /// `reevaluatePreparedTerminalGeometry()`'s sole path to
    /// `PreparedTerminalMountAdmissionPort.refreshQueuedTrustedFrames`,
    /// `PreparedTerminalMountAdmissionPort.acceptLaterTrustedFrames` and
    /// `WorkspacePreparedContentMountCoordinator.acceptTerminalGeometry` —
    /// both installed-owner-scoped objects this coordinator has no other
    /// reference to. Wired post-construction exactly like
    /// `preparedContentVisibilitySignalHandler`, in the same
    /// `AppDelegate+WorkspaceBoot.swift` boot step. Defaults to a no-op so
    /// harnesses that construct this coordinator without installing prepared
    /// content mount owners keep compiling unchanged.
    var preparedTerminalGeometryReevaluationHandler: @MainActor ([PaneId: NSRect]) async -> Void = { _ in }
    lazy var sessionConfig = SessionConfiguration.detect()
    lazy var terminalRestoreRuntime = TerminalRestoreRuntime(sessionConfiguration: sessionConfig)
    private var paneEventIngressTask: Task<Void, Never>?
    private var runtimeEventBridgeTasks: [PaneId: Task<Void, Never>] = [:]
    private var criticalRuntimeEventsTask: Task<Void, Never>?
    private var batchedRuntimeEventsTask: Task<Void, Never>?
    var bridgePaneRetirementTasksByPaneId: [UUID: Task<Void, Never>] = [:]
    var bridgePaneRetirementsRequiringRuntimeUnregister: Set<UUID> = []
    var bridgePaneRetirementsRequiringRestore: Set<UUID> = []
    var filesystemSyncTask: Task<Void, Never>?
    var filesystemSyncRequested = false
    var pendingFilesystemPaneUpdatesByPaneId: [UUID: FilesystemProjectionPaneUpdate] = [:]
    var filesystemFullReconciliationRequestCount: UInt64 = 0
    var filesystemAffectedKeyRequestCount: UInt64 = 0
    var pendingPaneRefocusReasonsByPaneId: [UUID: PaneRefocusRequestTrigger.Reason] = [:]
    var filesystemRegisteredContextsByWorktreeId: [UUID: WorktreeFilesystemContext] = [:]
    var filesystemActivityByWorktreeId: [UUID: Bool] = [:]
    var filesystemLastActivePaneWorktreeId: UUID?
    var filesystemLastSidebarVisibleWorktreeIds: Set<UUID> = []
    var filesystemTopologyAssertionGeneration: UInt64 = 0
    var filesystemSyncRequestGeneration: UInt64 = 0
    var filesystemProjectionRequestGeneration: UInt64 = 0
    var filesystemAppliedTopologyGeneration: UInt64 = 0
    var paneContextGeneration: UInt64 = 0
    var nextFilesystemProjectionSequenceByPaneId: [UUID: UInt64] = [:]
    var pendingTerminalStartupOperationID: String?
    var terminalStartupOperationIDsByPaneID: [UUID: String] = [:]
    var bridgePaneActivityCoordinatorsByPaneId: [UUID: BridgePaneActivityCoordinator] = [:]
    var bridgePaneActivityObservationGeneration: UInt64 = 0
    var pullRequestDemandOwningWindowId: UUID?
    var pullRequestDemandObservationGeneration: UInt64 = 0
    var pullRequestDemandDeliveryTask: Task<Void, Never>?
    var pullRequestDemandInFlightWorktreeIds: Set<UUID>?
    var pendingPullRequestDemandWorktreeIds: Set<UUID>?
    var lastDeliveredPullRequestDemandWorktreeIds: Set<UUID>?
    var repositoryFactDemandOwningWindowId: UUID?
    var repositoryFactDemandObservationGeneration: UInt64 = 0
    var rendererVisibilityOwningWindowId: UUID?
    var rendererVisibilityObservationGeneration: UInt64 = 0
    var heldPanePreviewState: HeldPanePreviewState?
    var heldPanePreviewPreparationCapture: HeldPanePreviewPreparationCapture?
    lazy var repositoryFactDemandCoordinator = RepositoryFactDemandCoordinator(
        performanceRecorder: performanceTraceRecorder
    ) { [weak self] snapshot in
        await self?.filesystemSource.setRepositoryFactDemand(snapshot)
    }
    var bridgeGitReadActivityPropagationTask: Task<Void, Never>?
    var zoomCompanionContinuityBySourcePaneId: [UUID: ZoomCompanionContinuity] = [:]

    var arrangementView: WorkspaceArrangementViewDerived {
        WorkspaceArrangementViewDerived(
            tabLayoutAtom: store.tabLayoutAtom,
            paneAtom: store.paneAtom,
            managementLayerAtom: atom(\.managementLayer)
        )
    }

    /// In-memory projection of available durable journal entries for native restoration.
    /// SQLite owns close ordering, deadlines, capacity and session ownership.
    private var undoCloses: [WorkspaceUndoCloseProjection] = []
    var undoStack: [WorkspaceMutationCoordinator.CloseEntry] {
        undoCloses.map { $0.snapshot.restoreEntry }
    }

    convenience init(
        store: WorkspaceStore,
        viewRegistry: ViewRegistry,
        runtime: SessionRuntime,
        windowLifecycleStore: WindowLifecycleAtom,
        appLifecycleStore: AppLifecycleAtom = AppLifecycleAtom(),
        ipcLifecycle: WorkspaceSurfaceIPCLifecycle,
        bridgePaneAttendance: BridgePaneAttendanceAtom,
        worktreeAnnotationStore: WorktreeAnnotationServiceActor? = nil,
        worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor? = nil
    ) {
        self.init(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: SurfaceManager.shared,
            runtimeRegistry: .shared,
            paneEventBus: PaneRuntimeEventBus.shared,
            runtimeCommandClock: ContinuousClock(),
            windowLifecycleStore: windowLifecycleStore,
            appLifecycleStore: appLifecycleStore,
            ipcLifecycle: ipcLifecycle,
            bridgePaneAttendance: bridgePaneAttendance,
            worktreeAnnotationStore: worktreeAnnotationStore,
            worktreeAnnotationOutputCoordinator: worktreeAnnotationOutputCoordinator
        )
    }

    init(
        store: WorkspaceStore,
        viewRegistry: ViewRegistry,
        runtime: SessionRuntime,
        surfaceManager: WorkspaceSurfaceManaging,
        startupTraceRecorder: AgentStudioStartupTraceRecorder? = nil,
        runtimeRegistry: RuntimeRegistry,
        paneEventBus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        runtimeCommandClock: ContinuousClock = ContinuousClock(),
        closeTransitionCoordinator: PaneCloseTransitionCoordinator = PaneCloseTransitionCoordinator(),
        bridgeGitReadScheduler: BridgeGitReadScheduler = BridgeGitReadScheduler(topology: .recoveryBaseline),
        worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator =
            BridgeWorktreeProductConstructionCoordinator(),
        gitWorkingTreeStatusProvider: (any GitWorkingTreeStatusProvider)? = nil,
        gitStatusPhysicalGate: AgentStudioGitStatusPhysicalGate? = nil,
        filesystemSource: (any WorkspaceFilesystemSourceManaging)? = nil,
        filesystemProjectionIndex: (any WorkspaceFilesystemProjectionIndexing)? = nil,
        windowLifecycleStore: WindowLifecycleAtom,
        appLifecycleStore: AppLifecycleAtom = AppLifecycleAtom(),
        ipcLifecycle: WorkspaceSurfaceIPCLifecycle,
        bridgePaneAttendance: BridgePaneAttendanceAtom,
        worktreeAnnotationStore: WorktreeAnnotationServiceActor? = nil,
        worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor? = nil,
        traceRuntime: AgentStudioTraceRuntime? = nil,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        traceIdentityRefreshHandler: (@MainActor @Sendable () -> Void)? = nil,
        undoClock: @escaping @Sendable () async throws -> WorkspaceUndoJournalTime = {
            try await WorkspaceUndoJournalClock.current()
        },
        undoDelay: AsyncDelay = .clock(ContinuousClock())
    ) {
        let suppliedFilesystemTrioCount = [
            filesystemSource != nil,
            gitWorkingTreeStatusProvider != nil,
            gitStatusPhysicalGate != nil,
        ].filter { $0 }.count
        precondition(
            suppliedFilesystemTrioCount == 0 || suppliedFilesystemTrioCount == 3,
            "filesystem source, Git status provider, and physical gate must be injected together"
        )
        let resolvedGitStatusPhysicalGate = gitStatusPhysicalGate ?? AgentStudioGitStatusPhysicalGate()
        let resolvedGitWorkingTreeStatusProvider: any GitWorkingTreeStatusProvider
        let resolvedFilesystemSource: any WorkspaceFilesystemSourceManaging
        if let filesystemSource, let gitWorkingTreeStatusProvider {
            resolvedGitWorkingTreeStatusProvider = gitWorkingTreeStatusProvider
            resolvedFilesystemSource = filesystemSource
        } else {
            let fseventStreamClient = DarwinFSEventStreamClient()
            let provider = AgentStudioGitWorkingTreeStatusProvider(
                physicalGate: resolvedGitStatusPhysicalGate,
                continuityWitness: fseventStreamClient
            )
            resolvedGitWorkingTreeStatusProvider = provider
            resolvedFilesystemSource = FilesystemGitPipeline(
                bus: paneEventBus,
                gitWorkingTreeProvider: provider,
                fseventStreamClient: fseventStreamClient,
                performanceTraceRecorder: performanceTraceRecorder
            )
        }
        let visibilityTierResolver = StoreVisibilityTierResolver(store: store)
        self.store = store
        self.undoClock = undoClock
        self.undoDelay = undoDelay
        self.viewRegistry = viewRegistry
        self.runtime = runtime
        self.ipcLifecycle = ipcLifecycle
        self.surfaceManager = surfaceManager
        self.startupTraceRecorder = startupTraceRecorder
        self.runtimeRegistry = runtimeRegistry
        self.visibilityTierResolver = visibilityTierResolver
        self.runtimeEventReducer = NotificationReducer(tierResolver: visibilityTierResolver)
        self.paneEventBus = paneEventBus
        self.runtimeTargetResolver = RuntimeTargetResolver(workspaceStore: store)
        self.runtimeCommandClock = runtimeCommandClock
        self.closeTransitionCoordinator = closeTransitionCoordinator
        self.bridgeGitReadScheduler = bridgeGitReadScheduler
        self.worktreeProductConstructionCoordinator = worktreeProductConstructionCoordinator
        self.worktreeAnnotationStore = worktreeAnnotationStore
        self.worktreeAnnotationOutputCoordinator = worktreeAnnotationOutputCoordinator
        self.gitWorkingTreeStatusProvider = resolvedGitWorkingTreeStatusProvider
        self.gitStatusPhysicalGate = resolvedGitStatusPhysicalGate
        self.filesystemSource = resolvedFilesystemSource
        self.filesystemProjectionIndex = filesystemProjectionIndex ?? FilesystemProjectionIndex()
        self.windowLifecycleStore = windowLifecycleStore
        self.appLifecycleStore = appLifecycleStore
        self.bridgePaneAttendance = bridgePaneAttendance
        self.traceRuntime = traceRuntime
        self.performanceTraceRecorder = performanceTraceRecorder
        self.traceIdentityRefreshHandler = traceIdentityRefreshHandler
        store.paneAtom.setAssociationOutcomeRecorder { [weak performanceTraceRecorder] outcome in
            performanceTraceRecorder?.recordPaneAssociationOutcome(outcome)
        }
        Ghostty.App.setRuntimeRegistry(runtimeRegistry)
        setupPrePersistHook()
        setupFilesystemSourceSync()
        startPaneEventIngress()
        startRuntimeReducerConsumers()
        startBridgePaneActivityObservation()
    }

    isolated deinit {
        terminalSessionCleanupWakeups.continuation.finish()
        terminalSessionCleanupTask?.cancel()
        undoDeadlineWakeups.continuation.finish()
        undoDeadlineTask?.cancel()
        paneEventIngressTask?.cancel()
        for task in runtimeEventBridgeTasks.values {
            task.cancel()
        }
        runtimeEventBridgeTasks.removeAll()
        criticalRuntimeEventsTask?.cancel()
        batchedRuntimeEventsTask?.cancel()
        filesystemSyncTask?.cancel()
        bridgePaneActivityObservationGeneration &+= 1
        repositoryFactDemandObservationGeneration &+= 1
        pullRequestDemandObservationGeneration &+= 1
        rendererVisibilityObservationGeneration &+= 1
        surfaceManager.setAttachedBindingsChangeHandler(nil)
        pullRequestDemandDeliveryTask?.cancel()
        let filesystemSource = filesystemSource
        let filesystemProjectionIndex = filesystemProjectionIndex
        Task {
            await filesystemSource.setRepositoryFactDemand(.empty)
            await filesystemProjectionIndex.shutdown()
            await filesystemSource.shutdown()
        }
    }

    func shutdown() async {
        terminalSessionCleanupStopped = true
        terminalSessionCleanupWakeups.continuation.finish()
        terminalSessionCleanupTask?.cancel()
        await terminalSessionCleanupTask?.value
        terminalSessionCleanupTask = nil
        undoDeadlineWakeups.continuation.finish()
        undoDeadlineTask?.cancel()
        await undoDeadlineTask?.value
        undoDeadlineTask = nil
        retireAllZoomCompanions()
        closeAllBridgePaneActivityAuthorities()
        bridgePaneActivityObservationGeneration &+= 1
        stopRepositoryFactDemandObservation()
        pullRequestDemandObservationGeneration &+= 1
        stopRendererVisibilityObservation()
        for paneId in viewRegistry.allBridgeViews.keys {
            teardownView(for: paneId)
        }
        let activePaneEventIngressTask = paneEventIngressTask
        let activeCriticalRuntimeEventsTask = criticalRuntimeEventsTask
        let activeBatchedRuntimeEventsTask = batchedRuntimeEventsTask
        let activeFilesystemSyncTask = filesystemSyncTask
        let activePullRequestDemandDeliveryTask = pullRequestDemandDeliveryTask
        let activeRuntimeBridgeTasks = Array(runtimeEventBridgeTasks.values)

        paneEventIngressTask?.cancel()
        paneEventIngressTask = nil
        criticalRuntimeEventsTask?.cancel()
        criticalRuntimeEventsTask = nil
        batchedRuntimeEventsTask?.cancel()
        batchedRuntimeEventsTask = nil
        filesystemSyncTask?.cancel()
        filesystemSyncTask = nil
        filesystemSyncRequested = false
        pendingFilesystemPaneUpdatesByPaneId.removeAll()
        pullRequestDemandDeliveryTask?.cancel()
        pullRequestDemandDeliveryTask = nil
        pullRequestDemandInFlightWorktreeIds = nil
        pendingPullRequestDemandWorktreeIds = nil

        for task in activeRuntimeBridgeTasks {
            task.cancel()
        }
        runtimeEventBridgeTasks.removeAll()

        await repositoryFactDemandCoordinator.shutdown()
        await filesystemProjectionIndex.shutdown()

        if let activePaneEventIngressTask {
            await activePaneEventIngressTask.value
        }
        if let activeCriticalRuntimeEventsTask {
            await activeCriticalRuntimeEventsTask.value
        }
        if let activeBatchedRuntimeEventsTask {
            await activeBatchedRuntimeEventsTask.value
        }
        if let activeFilesystemSyncTask {
            await activeFilesystemSyncTask.value
        }
        if let activePullRequestDemandDeliveryTask {
            await activePullRequestDemandDeliveryTask.value
        }
        for task in activeRuntimeBridgeTasks {
            await task.value
        }

        await drainBridgePaneRetirements()
        await drainBridgeGitReadActivityPropagation()
        await worktreeProductConstructionCoordinator.shutdown()
        await bridgeGitReadScheduler.shutdown()
        await filesystemSource.shutdown()
    }

    func submitWorkspaceAction(_ action: WorkspaceActionCommand) {
        guard let workspaceActionSubmission else {
            Self.logger.error("Workspace command ingress arrived before its execution owner was installed")
            return
        }
        workspaceActionSubmission(action)
    }

    func installUndoJournalRecovery(_ recovery: WorkspaceUndoJournalRecovery) {
        undoCloses = recovery.availableCloses.reversed().map(WorkspaceUndoCloseProjection.init)
        consumeUndoRetirements(recovery.retiredCloses)
        signalUndoDeadlineChange()
    }

    func publishUndoReceipt(_ receipt: WorkspaceUndoJournalReceipt, adding: WorkspaceUndoCloseProjection? = nil) {
        // This bounded UI projection follows committed IDs; it never decides ownership or consumes undo.
        var projections = Dictionary(uniqueKeysWithValues: undoCloses.map { ($0.closeID, $0) })
        if let adding { projections[adding.closeID] = adding }
        undoCloses = receipt.availableCloseIDs.reversed().compactMap { projections[$0] }
        consumeUndoRetirements(receipt.retiredCloses)
        signalUndoDeadlineChange()
    }

    func consumeUndoRetirements(_ retirements: [WorkspaceUndoCloseRetirement]) {
        let retiredCloseIDs = Set(retirements.map(\.closeID))
        undoCloses.removeAll { retiredCloseIDs.contains($0.closeID) }
        let unownedPaneIDs = Set(retirements.flatMap(\.unownedPaneIDs))
        retirePanesPermanently(unownedPaneIDs)
        if !unownedPaneIDs.isEmpty {
            ipcLifecycle.finalRevokePaneIDs(unownedPaneIDs)
        }
        surfaceManager.releaseUndoSurfaces(forPaneIDs: unownedPaneIDs)
        for paneID in unownedPaneIDs { viewRegistry.retireSlot(for: paneID) }
        signalTerminalSessionCleanup()
    }

    /// Shared final-retirement edge for undo expiry and committed direct discards.
    func retirePanesPermanently(_ paneIDs: Set<UUID>) {
        paneActivityClock?.retire(Array(paneIDs))
    }

    private func updatePaneCWDAndResolvedContext(paneId: UUID, cwd: URL?) {
        guard let associationRevision = store.paneAtom.graphAtom.reservePaneAssociationRevision(paneId) else {
            Self.logger.warning("cwd update ignored for missing pane \(paneId.uuidString, privacy: .public)")
            return
        }
        let lookupClock = ContinuousClock()
        let lookupStartedAt = lookupClock.now
        let topologySnapshot = store.repositoryTopologyAtom.captureReadSnapshot()
        let resolvedContext = topologySnapshot.repoAndWorktree(containing: cwd)
        if let cwd {
            performanceTraceRecorder?.recordRepoAndWorktreeLookup(
                duration: lookupStartedAt.duration(to: lookupClock.now),
                indexCount: store.repositoryTopologyAtom.worktreePathIndexCount,
                hasMatch: resolvedContext != nil,
                fact: AgentStudioPerformanceTraceRecorder.TopologyLookupFact(
                    normalizedCWD: cwd.standardizedFileURL.path,
                    worktreePathIndexGeneration: store.repositoryTopologyAtom.worktreePathIndexGeneration,
                    repoId: resolvedContext?.repo.id,
                    worktreeId: resolvedContext?.worktree.id
                )
            )
        }
        let associationResolution: PaneAssociationResolution
        if let resolvedContext {
            associationResolution = .matched(
                repoId: resolvedContext.repo.id,
                worktreeId: resolvedContext.worktree.id
            )
        } else {
            associationResolution = .confidentNoMatch
        }
        let updateResult = store.paneAtom.graphAtom.applyPaneAssociationUpdate(
            paneId,
            cwd: cwd,
            resolution: associationResolution,
            revision: associationRevision
        )
        switch (associationResolution, updateResult) {
        case (.matched(_, _), .applied):
            performanceTraceRecorder?.recordPaneAssociationOutcome(.resolvedChanged)
        case (.matched(_, _), .unchanged):
            performanceTraceRecorder?.recordPaneAssociationOutcome(.resolvedEqual)
        case (.confidentNoMatch, .applied), (.confidentNoMatch, .unchanged):
            performanceTraceRecorder?.recordPaneAssociationOutcome(.clearedNoMatch)
        case (.uncertain, .deferredUncertain):
            performanceTraceRecorder?.recordPaneAssociationOutcome(.deferredUncertain)
        default:
            break
        }
        switch updateResult {
        case .applied:
            guard let pane = store.paneAtom.pane(paneId) else {
                removePaneFilesystemProjectionContext(paneId: paneId)
                return
            }
            upsertPaneFilesystemProjectionContext(for: pane)
            reconcileZoomCompanionAfterCWDChange(sourcePaneId: paneId)
        case .unchanged:
            return
        case .deferredUncertain:
            guard let pane = store.paneAtom.pane(paneId) else { return }
            upsertPaneFilesystemProjectionContext(for: pane)
            reconcileZoomCompanionAfterCWDChange(sourcePaneId: paneId)
        case .staleRevision:
            return
        case .paneMissing:
            Self.logger.warning("cwd update ignored for missing pane \(paneId.uuidString, privacy: .public)")
            return
        }
    }

    // MARK: - Webview State Sync

    private func setupPrePersistHook() {
        store.setPrePersistHook { [weak self] in
            self?.syncWebviewStates()
        }
    }

    /// Sync runtime webview tab state back to persisted pane model.
    /// Uses syncPaneWebviewState (not updatePaneWebviewState) to avoid
    /// marking dirty during an in-flight persist, which would cause a save-loop.
    func syncWebviewStates() {
        for (paneId, webviewView) in viewRegistry.allWebviewViews {
            store.paneAtom.syncPaneWebviewState(paneId, state: webviewView.currentState())
        }
    }

    // MARK: - Runtime Registry

    func registerRuntime(_ runtime: any PaneRuntime) {
        let registrationResult = runtimeRegistry.register(runtime)
        guard registrationResult == .inserted else { return }
        startRuntimeEventBridge(for: runtime)
    }

    @discardableResult
    func unregisterRuntime(_ paneId: PaneId) -> (any PaneRuntime)? {
        stopRuntimeEventBridge(for: paneId)
        let unregisteredRuntime = runtimeRegistry.unregister(paneId)
        recoverZoomCompanionAfterResourceLoss(for: paneId.uuid)
        return unregisteredRuntime
    }

    func runtimeForPane(_ paneId: PaneId) -> (any PaneRuntime)? {
        runtimeRegistry.runtime(for: paneId)
    }

    private func startPaneEventIngress() {
        guard paneEventIngressTask == nil else { return }
        paneEventIngressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let subscription = await self.paneEventBus.subscribe(
                policy: .criticalUnbounded,
                subscriberName: "WorkspaceSurfaceCoordinator",
                factInterest: .matching([
                    .worktreeFilesystem,
                    .worktreeGitWorkingDirectory,
                    .paneTerminal,
                    .paneFilesystemContext,
                    .paneError,
                ])
            )
            for await envelope in subscription {
                if Task.isCancelled {
                    // Skip cancelled envelopes but keep iterating so termination can await subscriber removal.
                    continue
                }
                self.runtimeEventReducer.submit(envelope)
            }
        }
    }

    private func startRuntimeEventBridge(for runtime: any PaneRuntime) {
        guard !(runtime is any BusPostingPaneRuntime) else { return }

        let runtimePaneId = runtime.paneId
        guard runtimeEventBridgeTasks[runtimePaneId] == nil else { return }

        let stream = runtime.subscribe()
        runtimeEventBridgeTasks[runtimePaneId] = Task { @MainActor [weak self] in
            guard let self else { return }
            for await envelope in stream {
                if Task.isCancelled { break }
                await self.paneEventBus.post(envelope)
            }
            self.runtimeEventBridgeTasks.removeValue(forKey: runtimePaneId)
        }
    }

    private func stopRuntimeEventBridge(for paneId: PaneId) {
        runtimeEventBridgeTasks[paneId]?.cancel()
        runtimeEventBridgeTasks.removeValue(forKey: paneId)
    }

    private func startRuntimeReducerConsumers() {
        guard criticalRuntimeEventsTask == nil, batchedRuntimeEventsTask == nil else { return }

        criticalRuntimeEventsTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            for await envelope in self.runtimeEventReducer.criticalEvents {
                if Task.isCancelled { break }
                await self.handleRuntimeEnvelope(envelope)
            }
        }

        batchedRuntimeEventsTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            for await batch in self.runtimeEventReducer.batchedEvents {
                if Task.isCancelled { break }
                for envelope in batch {
                    await self.handleRuntimeEnvelope(envelope)
                }
            }
        }
    }

    private func handleRuntimeEnvelope(_ envelope: RuntimeEnvelope) async {
        if await handleFilesystemEnvelopeIfNeeded(envelope) {
            return
        }

        switch envelope {
        case .pane(let paneEnvelope):
            let sourcePaneId = paneEnvelope.paneId
            switch paneEnvelope.event {
            case .terminal(let event):
                handleTerminalRuntimeEvent(event, sourcePaneId: sourcePaneId)
            case .error(let errorEvent):
                Self.logger.warning(
                    "Runtime error event received from pane \(sourcePaneId.uuid.uuidString, privacy: .public): \(String(describing: errorEvent), privacy: .public)"
                )
            case .paneFilesystemContext(let event):
                await handleBridgePaneFilesystemContext(event, sourcePaneId: sourcePaneId)
            case .lifecycle, .terminalActivity, .browser, .diff, .editor, .agentNotificationRequested, .plugin,
                .artifact, .security, .filesystem:
                Self.logger.debug(
                    "Runtime event family ignored by coordinator for pane \(sourcePaneId.uuid.uuidString, privacy: .public): \(String(describing: paneEnvelope.event), privacy: .public)"
                )
            }
        case .system(let systemEnvelope):
            Self.logger.debug(
                "Runtime event ignored for system source \(String(describing: systemEnvelope.source), privacy: .public): \(String(describing: systemEnvelope.event), privacy: .public)"
            )
        case .worktree(let worktreeEnvelope):
            Self.logger.debug(
                "Runtime event ignored for worktree source \(String(describing: worktreeEnvelope.worktreeId), privacy: .public): \(String(describing: worktreeEnvelope.event), privacy: .public)"
            )
        }
    }

    func handleBridgePaneFilesystemContext(
        _ event: PaneFilesystemContextEvent,
        sourcePaneId: PaneId
    ) async {
        _ = event
        Self.logger.debug(
            "Derived filesystem context ignored for Bridge pane \(sourcePaneId.uuid.uuidString, privacy: .public); raw worktree ingress owns product invalidation"
        )
    }

    private func handleTerminalRuntimeEvent(_ event: GhosttyEvent, sourcePaneId: PaneId) {
        let sourcePaneUUID = sourcePaneId.uuid
        switch event {
        case .newTab, .newSplit, .gotoSplit, .resizeSplit, .equalizeSplits, .toggleSplitZoom,
            .closeTab, .gotoTab, .moveTab:
            Self.logger.debug(
                "Ghostty structural runtime event dropped by coordinator for pane \(sourcePaneUUID.uuidString, privacy: .public) event=\(String(describing: event), privacy: .public)"
            )
            return
        default:
            break
        }

        guard store.tabLayoutAtom.tabID(containingPane: sourcePaneUUID) != nil else {
            Self.logger.warning(
                "Terminal runtime event dropped: source pane \(sourcePaneUUID.uuidString, privacy: .public) is not present in any tab. event=\(String(describing: event), privacy: .public)"
            )
            return
        }

        switch event {
        case .newTab, .newSplit, .gotoSplit, .resizeSplit, .equalizeSplits, .toggleSplitZoom,
            .closeTab, .gotoTab, .moveTab:
            // Structural events return through the explicit drop above.
            return
        case .titleChanged(let title):
            store.paneAtom.updatePaneTitle(sourcePaneUUID, title: title)
        case .tabTitleChanged(let title):
            store.paneAtom.updatePaneTitle(sourcePaneUUID, title: title)
        case .cwdChanged(let cwdPath):
            // Runtime CWD is a shell string and may contain relative segments;
            // normalize here so both runtime and surface facts converge in the
            // shared pane identity update path below.
            updatePaneCWDAndResolvedContext(paneId: sourcePaneUUID, cwd: CWDNormalizer.normalize(cwdPath))
        case .commandFinished(let exitCode, _):
            Self.logger.debug(
                "Terminal commandFinished event received for pane \(sourcePaneUUID.uuidString, privacy: .public) exitCode=\(exitCode, privacy: .public)"
            )
        case .bellRang:
            AppEventBus.post(.worktreeBellRang(paneId: sourcePaneUUID))
            Self.logger.debug(
                "Terminal bell event received for pane \(sourcePaneUUID.uuidString, privacy: .public)"
            )
        case .progressReportUpdated, .readOnlyChanged, .secureInputRequested, .secureInputChanged,
            .rendererHealthChanged, .cellSizeChanged, .initialSizeChanged, .sizeLimitChanged,
            .mouseShapeChanged, .mouseVisibilityChanged, .mouseLinkHovered, .keySequenceChanged,
            .keyTableChanged, .colorChanged, .configReloadRequested, .configChanged,
            .searchStarted, .searchEnded, .searchMatchesUpdated, .searchSelectionChanged,
            .promptTitleRequested, .desktopNotificationRequested, .openURLRequested, .undoRequested,
            .redoRequested, .copyTitleToClipboardRequested, .scrollbarChanged, .deferred, .unhandled:
            Self.logger.debug(
                "Terminal runtime event ignored by coordinator for pane \(sourcePaneUUID.uuidString, privacy: .public): \(String(describing: event), privacy: .public)"
            )
        }
    }
}

extension WorkspaceSurfaceCoordinator: TopologyEffectHandler {
    func topologyDidChange(_ delta: WorktreeTopologyDelta) {
        applyTopologyRemovals(from: [delta])
        applyTopologyAdoptions(from: [delta])
        syncFilesystemRootsAndActivity()
    }

    func topologyDidChange(_ deltas: [WorktreeTopologyDelta]) {
        applyTopologyRemovals(from: deltas)
        applyTopologyAdoptions(from: deltas)
        syncFilesystemRootsAndActivity()
    }

    private func applyTopologyRemovals(from deltas: [WorktreeTopologyDelta]) {
        var removedWorktreeIDs = Set<UUID>()
        for delta in deltas {
            for entry in delta.removedWorktrees {
                removedWorktreeIDs.insert(entry.id)
                for _ in store.mutationCoordinator.clearPaneAssociations(forRemovedWorktreeID: entry.id) {
                    performanceTraceRecorder?.recordPaneAssociationOutcome(.topologyRemoved)
                }
            }
        }
        guard !removedWorktreeIDs.isEmpty else { return }
        // Scoped topology may already have cleared the source pane's optional facets.
        // The retained companion still carries the checkout whose authority must retire.
        for (sourcePaneID, companion) in store.panePresentationAtom.zoomCompanionsBySourcePaneId
        where removedWorktreeIDs.contains(companion.resolvedWorktreeId) {
            _ = reconcileZoomCompanion(sourcePaneId: sourcePaneID, owningTabId: companion.owningTabId)
        }
    }

    private func applyTopologyAdoptions(from deltas: [WorktreeTopologyDelta]) {
        let affectedWorktreeIDs = Set(
            deltas.flatMap { $0.addedWorktreeIds + $0.preservedWorktreeIds }
        )
        let adoptedPaneIDs = store.mutationCoordinator.reconcilePaneAssociationsForCurrentTopology(
            affectedWorktreeIDs: affectedWorktreeIDs
        )
        for _ in adoptedPaneIDs {
            performanceTraceRecorder?.recordPaneAssociationOutcome(.resolvedChanged)
        }
    }

    // MARK: - Tab Name Derivation

    /// Seed a stable tab name once at creation time from the pane's context.
    /// Worktree-backed panes get "folder · branch", others get the pane title.
    /// We intentionally do not auto-rename tabs later when enrichment changes.
    func tabNameForPane(_ pane: Pane) -> String {
        atom(\.tabDisplay).title(
            for: pane,
            workspaceRepositoryTopology: store.repositoryTopologyAtom,
            repoCache: atom(\.repoCache)
        )
    }
}
