import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WorkspaceBridgeGitReadActivityOrderingTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("Bridge Git read activity follows canonical pane update and removal order")
        func bridgeGitReadActivityFollowsCanonicalPaneOrder() async throws {
            // Arrange
            let setup = try makeActivityOrderingTestSetup()
            try await setup.installViewsAndVerifyInitialActivities()

            let blockerGate = HeldStep<Void>("blockerGate", cancellation: .holdThroughCancellation)
            let targetGate = HeldStep<Void>("targetGate", cancellation: .holdThroughCancellation)
            let peerGate = HeldStep<Void>("peerGate", cancellation: .holdThroughCancellation)
            let blockerRead = Task {
                try await setup.scheduler.read(
                    request: makeBridgeGitReadRequest(worktree: "blocker", key: "blocker")
                ) {
                    try? await blockerGate.arrive(())
                    return "blocker"
                }
            }
            try await blockerGate.firstArrival()
            let targetRead = Task {
                try await setup.scheduler.read(
                    request: makeBridgeGitReadRequest(
                        worktree: setup.targetWorktree.stableKey,
                        key: "target"
                    )
                ) {
                    try? await targetGate.arrive(())
                    return "target"
                }
            }
            let peerRead = Task {
                try await setup.scheduler.read(
                    request: makeBridgeGitReadRequest(
                        worktree: setup.peerWorktree.stableKey,
                        key: "peer"
                    )
                ) {
                    try? await peerGate.arrive(())
                    return "peer"
                }
            }
            _ = await setup.eventProbe.waitFor(.queued, occurrence: 3)

            // Act — preserve foreground → hidden → closed order for both target duplicates.
            setup.store.setActiveTab(setup.peerTabId)
            setup.coordinator.refreshBridgePaneActivities()
            await expectBridgePaneActivity(
                .loadedHidden,
                for: setup.targetPane.id,
                in: setup.coordinator,
                because: "the target tab moved to the background"
            )
            await expectBridgePaneActivity(
                .loadedHidden,
                for: setup.duplicateTargetPane.id,
                in: setup.coordinator,
                because: "the duplicate target pane moved to the background"
            )
            await expectBridgePaneActivity(
                .foreground,
                for: setup.peerPane.id,
                in: setup.coordinator,
                because: "the peer pane moved into the active native surface"
            )
            setup.coordinator.closeBridgePaneActivityAuthority(for: setup.targetPane.id)
            setup.coordinator.closeBridgePaneActivityAuthority(for: setup.duplicateTargetPane.id)
            setup.coordinator.refreshBridgePaneActivities()
            await setup.coordinator.drainBridgeGitReadActivityPropagation()
            blockerGate.release()
            let secondStart = await setup.eventProbe.waitFor(.started, occurrence: 2)

            // Assert — no older target update may overtake either close and restore stale rank.
            let expectedPeerKey = BridgeGitReadWorktreeKey(token: setup.peerWorktree.stableKey)
            #expect(secondStart.worktreeKey == expectedPeerKey)
            if secondStart.worktreeKey == expectedPeerKey {
                peerGate.release()
                try await targetGate.firstArrival()
                targetGate.release()
            } else {
                targetGate.release()
                try await peerGate.firstArrival()
                peerGate.release()
            }
            #expect(try await blockerRead.value == "blocker")
            #expect(try await targetRead.value == "target")
            #expect(try await peerRead.value == "peer")
            _ = await setup.eventProbe.waitFor(.slotReleased, occurrence: 3)
            #expect(setup.coordinator.bridgePaneActivity(for: setup.targetPane.id) == .closed)
            #expect(setup.coordinator.bridgePaneActivity(for: setup.duplicateTargetPane.id) == .closed)

            await setup.finish()
        }
    }
}

@MainActor
private struct ActivityOrderingTestSetup {
    let tempDirectory: URL
    let store: WorkspaceStore
    let coordinator: WorkspaceSurfaceCoordinator
    let scheduler: BridgeGitReadScheduler
    let eventProbe: BridgeGitReadSchedulerEventProbe
    let targetWorktree: Worktree
    let peerWorktree: Worktree
    let targetPane: Pane
    let duplicateTargetPane: Pane
    let peerPane: Pane
    let peerTabId: UUID

    func installViewsAndVerifyInitialActivities() async throws {
        installBridgeViewWithoutLoading(for: targetPane)
        installBridgeViewWithoutLoading(for: duplicateTargetPane)
        installBridgeViewWithoutLoading(for: peerPane)
        coordinator.refreshBridgePaneActivities()
        await expectBridgePaneActivity(
            .foreground,
            for: targetPane.id,
            in: coordinator,
            because: "the target pane is installed in the active tab"
        )
        await expectBridgePaneActivity(
            .foreground,
            for: duplicateTargetPane.id,
            in: coordinator,
            because: "the duplicate target pane shares the active arrangement"
        )
        await expectBridgePaneActivity(
            .loadedHidden,
            for: peerPane.id,
            in: coordinator,
            because: "the installed peer pane is in a background tab"
        )
    }

    private func installBridgeViewWithoutLoading(for pane: Pane) {
        guard case .bridgePanel(let state) = pane.content else {
            Issue.record("Expected a Bridge pane")
            return
        }
        coordinator.viewRegistry.ensureSlot(for: pane.id)
        let controller = BridgePaneController(
            paneId: pane.id,
            state: state,
            appRootURL: testBridgeAppRootURL(),
            metadata: pane.metadata,
            initialPaneActivity: .dormant
        )
        coordinator.registerHostedView(
            mountedView: BridgePaneMountView(paneId: pane.id, controller: controller),
            for: pane.id
        )
    }

    func finish() async {
        await coordinator.shutdown()
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

@MainActor
private func makeActivityOrderingTestSetup() throws -> ActivityOrderingTestSetup {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "agentstudio-bridge-git-activity-ordering-\(UUID().uuidString)")
    let store = WorkspaceStore()
    let targetRepo = store.addRepo(at: tempDirectory.appending(path: "target-repo"))
    let restoredTargetRepo = try #require(store.repo(targetRepo.id))
    let targetWorktree = try #require(restoredTargetRepo.worktrees.first)
    let peerRepo = store.addRepo(at: tempDirectory.appending(path: "peer-repo"))
    let restoredPeerRepo = try #require(store.repo(peerRepo.id))
    let peerWorktree = try #require(restoredPeerRepo.worktrees.first)
    let targetPane = makeBridgePane(
        store: store,
        repo: targetRepo,
        worktree: targetWorktree,
        title: "Target review"
    )
    let duplicateTargetPane = makeBridgePane(
        store: store,
        repo: targetRepo,
        worktree: targetWorktree,
        title: "Duplicate target review"
    )
    let peerPane = makeBridgePane(
        store: store,
        repo: peerRepo,
        worktree: peerWorktree,
        title: "Peer review"
    )
    let peerTabId = installActivityOrderingTabs(
        store: store,
        targetPaneIds: [targetPane.id, duplicateTargetPane.id],
        peerPaneId: peerPane.id
    )
    let eventProbe = BridgeGitReadSchedulerEventProbe()
    let scheduler = BridgeGitReadScheduler(
        topology: makeBridgeGitReadSchedulerTopology(),
        deadlineScheduler: BridgeGitReadManualDeadlineScheduler(),
        eventSink: eventProbe.eventSink
    )
    let appLifecycleStore = AppLifecycleAtom()
    let windowLifecycleStore = WindowLifecycleAtom()
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: ViewRegistry(),
        runtime: SessionRuntime(store: store),
        surfaceManager: HarnessSurfaceManager(),
        terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
        terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
        runtimeRegistry: RuntimeRegistry(),
        paneEventBus: makeTestPaneRuntimeEventBus(),
        bridgeGitReadScheduler: scheduler,
        windowLifecycleStore: windowLifecycleStore,
        appLifecycleStore: appLifecycleStore,
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: BridgePaneAttendanceAtom()
    )
    activateActivityOrderingWindow(
        coordinator: coordinator,
        appLifecycleStore: appLifecycleStore,
        windowLifecycleStore: windowLifecycleStore
    )
    return ActivityOrderingTestSetup(
        tempDirectory: tempDirectory,
        store: store,
        coordinator: coordinator,
        scheduler: scheduler,
        eventProbe: eventProbe,
        targetWorktree: targetWorktree,
        peerWorktree: peerWorktree,
        targetPane: targetPane,
        duplicateTargetPane: duplicateTargetPane,
        peerPane: peerPane,
        peerTabId: peerTabId
    )
}

@MainActor
private func installActivityOrderingTabs(
    store: WorkspaceStore,
    targetPaneIds: [UUID],
    peerPaneId: UUID
) -> UUID {
    let targetArrangement = PaneArrangement(
        name: "Target",
        isDefault: true,
        layout: .autoTiled(targetPaneIds),
        activePaneId: targetPaneIds.first
    )
    let targetTab = Tab(
        name: "Target",
        allPaneIds: targetPaneIds,
        arrangements: [targetArrangement],
        activeArrangementId: targetArrangement.id
    )
    let peerTab = Tab(paneId: peerPaneId, name: "Peer")
    store.appendTab(targetTab)
    store.appendTab(peerTab)
    store.setActiveTab(targetTab.id)
    return peerTab.id
}

@MainActor
private func activateActivityOrderingWindow(
    coordinator: WorkspaceSurfaceCoordinator,
    appLifecycleStore: AppLifecycleAtom,
    windowLifecycleStore: WindowLifecycleAtom
) {
    let owningWindowId = UUID()
    coordinator.startBridgePaneActivityObservation()
    appLifecycleStore.setActive(true)
    windowLifecycleStore.recordWindowRegistered(owningWindowId)
    windowLifecycleStore.recordWindowPresentation(
        WindowPresentationFacts(
            isVisible: true,
            isMiniaturized: false,
            isOccluded: false
        ),
        for: owningWindowId
    )
}

@MainActor
private func makeBridgePane(
    store: WorkspaceStore,
    repo: Repo,
    worktree: Worktree,
    title: String
) -> Pane {
    store.createPane(
        content: .bridgePanel(
            BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: worktree.path.path,
                    baseline: .ref(name: "HEAD~1"))
            )
        ),
        metadata: PaneMetadata(
            contentType: .diff,
            title: title,
            facets: PaneContextFacets(
                repoId: repo.id,
                repoName: repo.name,
                worktreeId: worktree.id,
                worktreeName: worktree.name,
                cwd: worktree.path
            )
        )
    )
}
