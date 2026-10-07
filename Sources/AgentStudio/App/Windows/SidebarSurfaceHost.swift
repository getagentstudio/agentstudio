import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

struct SidebarSurfaceSwitchMetricState {
    private struct PendingSwitch {
        let sequence: Int
        let surface: SidebarSurface
        let start: ContinuousClock.Instant
    }

    private var pendingSwitch: PendingSwitch?

    mutating func begin(sequence: Int, surface: SidebarSurface, at start: ContinuousClock.Instant) {
        pendingSwitch = PendingSwitch(sequence: sequence, surface: surface, start: start)
    }

    mutating func complete(
        sequence: Int,
        surface: SidebarSurface,
        at completion: ContinuousClock.Instant
    ) -> Duration? {
        guard
            let pendingSwitch,
            pendingSwitch.sequence == sequence,
            pendingSwitch.surface == surface
        else { return nil }

        self.pendingSwitch = nil
        return pendingSwitch.start.duration(to: completion)
    }
}

struct SidebarSurfaceHost: View {
    enum SurfaceSwitchPublicationMode: Equatable {
        case cachedThenDelta
    }

    enum ChildKind: Equatable {
        case repoExplorer
    }

    let store: WorkspaceStore
    let octiconLoader: OcticonLoader
    let paneContextReaders: PaneContextUIReaders?
    let paneActivityStatusAtom: PaneActivityStatusAtom
    let applicationLifecycleMonitor: ApplicationLifecycleMonitor
    let sidebarTimeInvalidationConsumerID: UUID
    let sidebarState: WorkspaceSidebarState
    let repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom
    let bridgeAttendanceSnapshot: BridgeAttendanceSnapshot
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    let onRefocusActivePane: () -> Void
    let onSelectedPaneTargetChange:
        @MainActor (RepoExplorerSelectedPaneTarget?, RepoExplorerSelectedPaneTargetChangeOrigin) -> Void
    let onPreviewEligibilityLoss: @MainActor () -> Void
    let onPreviewCommit: @MainActor () -> Void
    let onSidebarVisibleWorktreesChanged: @MainActor @Sendable () -> Void
    let onPerformanceProofReadback: @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void
    let onRepositoryFactUpdateProgressPresented: @MainActor @Sendable (UUID, UUID) -> Void
    @State private var repoCommandPresentationBatch: RepoExplorerCommandPresentationBatch?

    init(
        store: WorkspaceStore,
        octiconLoader: OcticonLoader,
        paneActivityStatusAtom: PaneActivityStatusAtom,
        paneContextReaders: PaneContextUIReaders? = nil,
        applicationLifecycleMonitor: ApplicationLifecycleMonitor,
        sidebarTimeInvalidationConsumerID: UUID,
        sidebarState: WorkspaceSidebarState,
        repoExplorerSidebarPrefs: RepoExplorerSidebarPrefsAtom,
        bridgeAttendanceSnapshot: @escaping BridgeAttendanceSnapshot,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?,
        onRefocusActivePane: @escaping () -> Void,
        onSelectedPaneTargetChange:
            @escaping @MainActor (
                RepoExplorerSelectedPaneTarget?, RepoExplorerSelectedPaneTargetChangeOrigin
            ) -> Void = { _, _ in },
        onPreviewEligibilityLoss: @escaping @MainActor () -> Void = {},
        onPreviewCommit: @escaping @MainActor () -> Void = {},
        onSidebarVisibleWorktreesChanged: @escaping @MainActor @Sendable () -> Void,
        onPerformanceProofReadback:
            @escaping @MainActor @Sendable (RepoExplorerPerformanceProofReadback) -> Void,
        onRepositoryFactUpdateProgressPresented:
            @escaping @MainActor @Sendable (UUID, UUID) -> Void
    ) {
        self.paneContextReaders = paneContextReaders
        self.store = store
        self.octiconLoader = octiconLoader
        self.paneActivityStatusAtom = paneActivityStatusAtom
        self.applicationLifecycleMonitor = applicationLifecycleMonitor
        self.sidebarTimeInvalidationConsumerID = sidebarTimeInvalidationConsumerID
        self.sidebarState = sidebarState
        self.repoExplorerSidebarPrefs = repoExplorerSidebarPrefs
        self.bridgeAttendanceSnapshot = bridgeAttendanceSnapshot
        self.performanceTraceRecorder = performanceTraceRecorder
        self.onRefocusActivePane = onRefocusActivePane
        self.onSelectedPaneTargetChange = onSelectedPaneTargetChange
        self.onPreviewEligibilityLoss = onPreviewEligibilityLoss
        self.onPreviewCommit = onPreviewCommit
        self.onSidebarVisibleWorktreesChanged = onSidebarVisibleWorktreesChanged
        self.onPerformanceProofReadback = onPerformanceProofReadback
        self.onRepositoryFactUpdateProgressPresented = onRepositoryFactUpdateProgressPresented
    }

    static var surfaceChromePolicy: SidebarSurfaceChromePolicy {
        SidebarSurfaceChrome<EmptyView>.policy
    }

    static let surfaceSwitchPublicationMode: SurfaceSwitchPublicationMode = .cachedThenDelta

    var body: some View {
        SidebarSurfaceChrome {
            RepoExplorerView(
                store: store,
                octiconLoader: octiconLoader,
                repoExplorerPrefs: repoExplorerSidebarPrefs,
                isProjectionDemanded: !sidebarState.sidebarCollapsed,
                bridgeAttendanceSnapshot: bridgeAttendanceSnapshot,
                commandDispatcher: AppCommandDispatcher.shared,
                commandPresentationDelta: repoCommandPresentationBatch?.latestDelta,
                visibleSnapshotConsumerToken: repoCommandPresentationBatch?.consumerToken,
                onRefocusActivePane: onRefocusActivePane,
                onSelectedPaneTargetChange: onSelectedPaneTargetChange,
                onPreviewEligibilityLoss: onPreviewEligibilityLoss,
                onPreviewCommit: onPreviewCommit,
                onSidebarVisibleWorktreesChanged: onSidebarVisibleWorktreesChanged,
                onVisibleWorktreeSnapshotChanged: { snapshot in
                    repoCommandPresentationBatch?.acceptVisibleWorktreeSnapshot(snapshot)
                    for (repoID, attemptID) in snapshot.settledUpdateAttemptByRepositoryID {
                        onRepositoryFactUpdateProgressPresented(repoID, attemptID)
                    }
                },
                onPerformanceProofReadback: onPerformanceProofReadback,
                paneContextControl: { pane, presentation in
                    guard let paneContextReaders else { return nil }
                    return AnyView(
                        PaneContextPopoverHost(
                            paneId: pane, presentation: presentation, location: .sidebar, readers: paneContextReaders,
                            octiconLoader: octiconLoader,
                            onGoToPane: { target in
                                AppCommandDispatcher.shared.dispatch(.focusPane, target: target, targetType: .pane)
                            }, includingDrawers: !paneContextReaders.isDrawerPane(pane)))
                },
                latestPaneMessageSnapshot: { paneId in
                    paneActivityStatusAtom.status(for: paneId)
                },
                sessionStatusForPane: { paneContextReaders?.sessionStatusForPane($0) },
                contextDisplayForPane: { paneContextReaders?.contextDisplayForPane($0) },
                performanceTraceRecorder: performanceTraceRecorder,
                initialProjectionTrigger: "data_refresh",
                installSystemTimeInvalidationHandler: { handler in
                    applicationLifecycleMonitor.installSidebarTimeInvalidationHandler(
                        consumerID: sidebarTimeInvalidationConsumerID,
                        handler: handler
                    )
                },
                removeSystemTimeInvalidationHandler: {
                    applicationLifecycleMonitor.removeSidebarTimeInvalidationHandler(
                        consumerID: sidebarTimeInvalidationConsumerID
                    )
                }
            )
            .task {
                guard repoCommandPresentationBatch == nil else { return }
                let batch = RepoExplorerCommandPresentationBatch(
                    store: store,
                    repoExplorerPrefs: repoExplorerSidebarPrefs,
                    dispatcher: .shared,
                    performanceTraceRecorder: performanceTraceRecorder
                )
                repoCommandPresentationBatch = batch
                batch.start()
            }
            .onDisappear {
                repoCommandPresentationBatch?.stop()
                repoCommandPresentationBatch = nil
            }
        }
    }

    static func currentChildKind(uiState: WorkspaceSidebarState) -> ChildKind {
        _ = uiState
        return .repoExplorer
    }
}
