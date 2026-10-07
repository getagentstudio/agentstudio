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

    /// SR5; Program Design item 3: shows the specific restore-start failure
    /// reason on the pane's overlay instead of generic "Process Exited". A
    /// no-op if the pane has no attached surface.
    func reportColdRestoreFailure(paneID: UUID, failure: ColdStartFailure)
}

/// Default no-op: only `SurfaceManager` implements this for real, so the
/// ~25 test fakes conforming to `WorkspaceSurfaceManaging` need no stub.
extension WorkspaceSurfaceManaging {
    func reportColdRestoreFailure(paneID: UUID, failure: ColdStartFailure) {}
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
    /// SR4; Program Design item 4 ("Staggered starts"): owns each cold
    /// pane's startup-window observation task -- cancellable on retirement
    /// or teardown, self-removing, test-awaitable. See
    /// `WorkspaceSurfaceCoordinator+TerminalContentMounting.swift`.
    var coldStartObservationTasksByPaneID: [UUID: Task<Void, Never>] = [:]
    /// Typed-fact sink (`docs/specs/2026-09-28-typed-fact-test-harness`):
    /// `nil` in production, a `LocalFactSource.sink` in tests.
    var coldStartObservationFactSink: (@Sendable (UUID, ColdStartOutcome) -> Void)?
    /// SR2a; Program Design item 5: one more `observeSessionIdentity` call
    /// after a warm/unverified pane's attach settles, compared against the
    /// warm baseline. Reuses `ZmxBackend`'s default timeout, not the
    /// shorter `inventoryProbeDeadline` the launch-restore cohort's own
    /// probe uses -- this runs one pane at a time, off the startup path.
    lazy var postAttachRecreationProbe: (any ZmxSessionRestoreProbing)? = ZmxBackend(configuration: sessionConfig)
    /// A6 (advisor review 2026-10-01; PD rev 21 item 5, Lead decision: push,
    /// not pull): panes mounted warm/unverified and still waiting for their
    /// post-attach recreation check's own first render. `TerminalActivityRouter`'s
    /// existing `.firstRender` outcome arm (already unconditional for
    /// warm/unverified panes -- they never arm a restore phase, so
    /// `consumeAggregateState`'s `!isInRestorePhase` gate never blocks
    /// them) calls the injected `onFirstRender` callback it's composed
    /// with in `AppDelegate.bootStartTerminalActivityRouter`, which
    /// forwards here via `receivePostAttachFirstRender(paneID:)`. A pane
    /// still present here when it retires never gets a render; see
    /// `retirePanesPermanently`.
    var pendingPostAttachRecreationChecksByPaneID: [UUID: PendingPostAttachRecreationCheck] = [:]
    /// Ownership shape matches `coldStartObservationTasksByPaneID`:
    /// cancellable on retirement/teardown, self-removing, test-awaitable.
    var postAttachRecreationCheckTasksByPaneID: [UUID: Task<Void, Never>] = [:]
    /// Detection only (Program Design item 5's own stop: no UI mechanism
    /// exists yet; `InboxNotificationRouter` stays retired). `nil` in
    /// production, a `LocalFactSource.sink` in tests.
    var postAttachRecreationCheckFactSink: (@Sendable (UUID, PaneRecreationCheckOutcome) -> Void)?
    /// R2-2 (review round 2, Lead 2026-10-01): `executeRepair`'s own
    /// `restorePhaseLatch` carry-across (A5) only covers a replacement that
    /// succeeds. A failed `.recreateSurface` (creation/attachment failure)
    /// has no surface left to hold the generation on, but the projector's
    /// own phase survives the failure by design (SR6b) -- this is where
    /// that generation waits until a later repair, `.recreateSurface` or
    /// `.createMissingView`, actually succeeds and reinstalls it. Cleared
    /// on successful reinstall or permanent retirement (`retirePanesPermanently`),
    /// never on a failed attempt alone.
    var pendingRestorePhaseLatchesByPaneID: [UUID: RestoreGeneration] = [:]
    /// Issues fresh, launch-unique `RestoreGeneration` values (SR6b;
    /// Program Design item 13). Moved here from the now-deleted
    /// `RestoreGenerationAllocator` (a process-wide singleton the repo's
    /// `agentstudio_no_new_process_singletons` lint now forbids,
    /// agent-studio#441): `RestoreGeneration` is compared only for
    /// equality/dedup, never ordered (its own doc comment), so uniqueness
    /// per coordinator -- the one production owner that arms a restore
    /// phase -- is sufficient; generations are only ever compared within
    /// one pane's own history.
    private var nextRestoreGenerationValue: UInt64 = 1
    /// Not `private`: `WorkspaceSurfaceCoordinator+TerminalContentMounting.swift`'s
    /// `mountPreparedTerminalContent` is the one call site, in a different
    /// file -- `private` is file-scoped and does not cross that boundary.
    func allocateRestoreGeneration() -> RestoreGeneration {
        defer { nextRestoreGenerationValue &+= 1 }
        return RestoreGeneration(rawValue: nextRestoreGenerationValue)
    }
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
        for paneID in coldStartObservationTasksByPaneID.keys {
            Ghostty.ActionRouter.cancelPendingColdStart(paneID: paneID)
        }
        for task in coldStartObservationTasksByPaneID.values {
            task.cancel()
        }
        coldStartObservationTasksByPaneID.removeAll()
        for task in postAttachRecreationCheckTasksByPaneID.values {
            task.cancel()
        }
        postAttachRecreationCheckTasksByPaneID.removeAll()
        pendingPostAttachRecreationChecksByPaneID.removeAll()
        pendingRestorePhaseLatchesByPaneID.removeAll()
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
        let activeColdStartObservationPaneIDs = Array(coldStartObservationTasksByPaneID.keys)
        let activeColdStartObservationTasks = Array(coldStartObservationTasksByPaneID.values)
        let activePostAttachRecreationCheckTasks = Array(postAttachRecreationCheckTasksByPaneID.values)

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
        for paneID in activeColdStartObservationPaneIDs {
            Ghostty.ActionRouter.cancelPendingColdStart(paneID: paneID)
        }
        for task in activeColdStartObservationTasks {
            task.cancel()
        }
        coldStartObservationTasksByPaneID.removeAll()
        for task in activePostAttachRecreationCheckTasks {
            task.cancel()
        }
        postAttachRecreationCheckTasksByPaneID.removeAll()
        // R3-2 (review round 3, Lead decision 2026-10-02): every pane still
        // waiting for its first output when the whole coordinator shuts
        // down never gets one either -- same reason, same one-disposition
        // shape as `retirePanesPermanently`'s existing per-pane close
        // (above) and `finishViewTeardown`'s new one
        // (WorkspaceSurfaceCoordinator+ViewLifecycle.swift). This used to
        // just clear the map silently.
        for paneID in pendingPostAttachRecreationChecksByPaneID.keys {
            postAttachRecreationCheckFactSink?(paneID, .uncheckable(.paneUnavailableBeforeFirstRender))
        }
        pendingPostAttachRecreationChecksByPaneID.removeAll()
        pendingRestorePhaseLatchesByPaneID.removeAll()

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
        for task in activeColdStartObservationTasks {
            await task.value
        }
        for task in activePostAttachRecreationCheckTasks {
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
    ///
    /// Also the sole source of the projector's permanent-close signal (SR6b): a
    /// discarded pane never reaches an ordinary `.surfaceClosed` here, so
    /// without this, an armed-but-never-typed-into pane's restore phase would
    /// leak in `TerminalActivityProjector.restorePhaseByPane` forever. Fired
    /// as a submitted input, matching `TerminalActivityRouter
    /// .markUnseenActivityObserved`'s existing fire-and-forget pattern for
    /// posting a terminal-activity fact from a synchronous call site.
    func retirePanesPermanently(_ paneIDs: Set<UUID>) {
        paneActivityClock?.retire(Array(paneIDs))
        for paneID in paneIDs {
            Task { @MainActor in
                await Ghostty.ActionRouter.retirePanePermanently(paneID: paneID)
            }
            // Program Design item 4: ends the pending cold-start window and
            // removes its kqueue registrations; a no-op with no observer.
            Ghostty.ActionRouter.cancelPendingColdStart(paneID: paneID)
            coldStartObservationTasksByPaneID[paneID]?.cancel()
            // SR2a: a still-running post-attach recreation check is no
            // longer meaningful once the pane retires.
            postAttachRecreationCheckTasksByPaneID[paneID]?.cancel()
            // A6: a pane still waiting for its first output when it retires
            // never gets one -- record the honest reason instead of leaving
            // it pending forever (no task to cancel here: nothing has
            // started yet, only a registration).
            if pendingPostAttachRecreationChecksByPaneID.removeValue(forKey: paneID) != nil {
                postAttachRecreationCheckFactSink?(paneID, .uncheckable(.paneUnavailableBeforeFirstRender))
            }
            // R2-2: a pane retiring permanently with no surface left to
            // reinstall its preserved generation onto never gets one --
            // there is no later repair to wait for.
            pendingRestorePhaseLatchesByPaneID.removeValue(forKey: paneID)
        }
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
