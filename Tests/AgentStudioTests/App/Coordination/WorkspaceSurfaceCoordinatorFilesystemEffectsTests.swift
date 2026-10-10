import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorFilesystemEffectsTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("unrelated workspace action performs no filesystem source work")
    func unrelatedWorkspaceActionPerformsNoFilesystemSourceWork() async throws {
        let context = makeContext(named: "unrelated-action")
        defer { try? FileManager.default.removeItem(at: context.tempDirectory) }
        let repo = context.store.addRepo(at: context.tempDirectory.appending(path: "repo"))
        let worktree = try #require(context.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = context.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let tab = Tab(paneId: pane.id)
        context.store.appendTab(tab)
        context.store.setActiveTab(tab.id)
        let source = OrderedRecordingFilesystemSource()
        let coordinator = makeCoordinator(context: context, source: source)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        await source.resetOperations()

        try await coordinator.execute(.renameTab(tabId: tab.id, name: "renamed"))
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        #expect(await source.operations().isEmpty)
        await coordinator.shutdown()
    }

    @Test("active tab selection performs no direct filesystem source write")
    func activeTabSelectionPerformsNoDirectFilesystemSourceWrite() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let context = makeContext(named: "active-selection")
            defer { try? FileManager.default.removeItem(at: context.tempDirectory) }
            let repo = context.store.addRepo(at: context.tempDirectory.appending(path: "repo"))
            let firstWorktree = try #require(context.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
            let secondCandidate = Worktree(
                repoId: repo.id,
                name: "second",
                path: repo.repoPath.appending(path: "second")
            )
            context.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [firstWorktree, secondCandidate])
            let secondWorktree = try #require(
                context.store.repo(repo.id)?.worktrees.first { $0.path == secondCandidate.path }
            )
            let firstPane = context.store.createPane(
                launchDirectory: firstWorktree.path,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: firstWorktree.id, cwd: firstWorktree.path)
            )
            let secondPane = context.store.createPane(
                launchDirectory: secondWorktree.path,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: secondWorktree.id, cwd: secondWorktree.path)
            )
            let firstTab = Tab(paneId: firstPane.id)
            let secondTab = Tab(paneId: secondPane.id)
            context.store.appendTab(firstTab)
            context.store.appendTab(secondTab)
            context.store.setActiveTab(firstTab.id)
            let source = OrderedRecordingFilesystemSource()
            let coordinator = makeCoordinator(context: context, source: source)
            await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
            await source.resetOperations()

            let focusExecutor = PaneFocusExecutor(
                hostViewProvider: { _ in nil },
                hostViewsProvider: { [] },
                selectTab: { context.store.setActiveTab($0) },
                selectPane: { _, _ in },
                selectDrawerPane: { _, _ in },
                selectEmptyDrawer: { _ in },
                syncRuntimeFocus: { _ in }
            )
            let focusDecision = PaneCommandFocusDecider.decide(
                trigger: .selectTab(secondTab.id),
                context: PaneFocusContext(
                    activeTabId: firstTab.id,
                    activePaneId: firstPane.id,
                    activeDrawer: nil,
                    targetPaneId: secondPane.id,
                    targetTabId: secondTab.id,
                    targetPaneKind: .terminal,
                    targetPaneIsAlreadyActive: false,
                    targetMountedContent: .unmounted,
                    managementLayer: .inactive,
                    windowState: .key
                )
            )
            focusExecutor.apply(.command(focusDecision))
            await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

            #expect(await source.operations().isEmpty)
            await coordinator.shutdown()
        }
    }

    @Test("direct worktree open performs no direct filesystem source write")
    func directWorktreeOpenPerformsNoDirectFilesystemSourceWrite() async throws {
        let context = makeContext(named: "direct-open")
        defer { try? FileManager.default.removeItem(at: context.tempDirectory) }
        let repo = context.store.addRepo(at: context.tempDirectory.appending(path: "repo"))
        let firstWorktree = try #require(context.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let secondCandidate = Worktree(
            repoId: repo.id,
            name: "second",
            path: repo.repoPath.appending(path: "second")
        )
        context.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [firstWorktree, secondCandidate])
        let secondWorktree = try #require(
            context.store.repo(repo.id)?.worktrees.first { $0.path == secondCandidate.path }
        )
        let firstPane = context.store.createPane(
            launchDirectory: firstWorktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: firstWorktree.id, cwd: firstWorktree.path)
        )
        let secondPane = context.store.createPane(
            launchDirectory: secondWorktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: secondWorktree.id, cwd: secondWorktree.path)
        )
        let firstTab = Tab(paneId: firstPane.id)
        let secondTab = Tab(paneId: secondPane.id)
        context.store.appendTab(firstTab)
        context.store.appendTab(secondTab)
        context.store.setActiveTab(firstTab.id)
        let source = OrderedRecordingFilesystemSource()
        let coordinator = makeCoordinator(context: context, source: source)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        await source.resetOperations()

        _ = try await coordinator.openTerminal(for: secondWorktree, in: repo)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        #expect(await source.operations().isEmpty)
        await coordinator.shutdown()
    }

    @Test("surface CWD change performs no direct filesystem source write")
    func surfaceCWDChangePerformsNoDirectFilesystemSourceWrite() async throws {
        let context = makeContext(named: "cwd-effect")
        defer { try? FileManager.default.removeItem(at: context.tempDirectory) }
        let repo = context.store.addRepo(at: context.tempDirectory.appending(path: "repo"))
        let firstWorktree = try #require(context.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let secondCandidate = Worktree(
            repoId: repo.id,
            name: "second",
            path: repo.repoPath.appending(path: "second")
        )
        context.store.reconcileDiscoveredWorktrees(repo.id, worktrees: [firstWorktree, secondCandidate])
        let secondWorktree = try #require(
            context.store.repo(repo.id)?.worktrees.first { $0.path == secondCandidate.path }
        )
        let pane = context.store.createPane(
            launchDirectory: firstWorktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: firstWorktree.id, cwd: firstWorktree.path)
        )
        let tab = Tab(paneId: pane.id)
        context.store.appendTab(tab)
        context.store.setActiveTab(tab.id)
        let source = OrderedRecordingFilesystemSource()
        let coordinator = makeCoordinator(context: context, source: source)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        await source.resetOperations()

        _ = await context.bus.post(
            RuntimeEnvelopeHarness.paneEnvelope(
                event: .terminal(.cwdChanged(secondWorktree.path.path)),
                paneId: PaneId(existingUUID: pane.id)
            )
        )
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        #expect(await source.operations().isEmpty)
        await coordinator.shutdown()
    }

    @Test("pane mount and removal perform no direct filesystem source writes")
    func paneMountAndRemovalPerformNoDirectFilesystemSourceWrites() async throws {
        let context = makeContext(named: "pane-lifecycle")
        defer { try? FileManager.default.removeItem(at: context.tempDirectory) }
        let repo = context.store.addRepo(at: context.tempDirectory.appending(path: "repo"))
        let worktree = try #require(context.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let source = OrderedRecordingFilesystemSource()
        let coordinator = makeCoordinator(context: context, source: source)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        await source.resetOperations()

        let pane = context.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        coordinator.upsertPaneFilesystemProjectionContext(for: pane)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        #expect(await source.operations().isEmpty)

        await source.resetOperations()
        coordinator.removePaneFilesystemProjectionContext(paneId: pane.id)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        #expect(await source.operations().isEmpty)
        await coordinator.shutdown()
    }

    @Test("failed current mount and failed insertion leave no filesystem membership")
    func failedMountAndInsertionLeaveNoFilesystemMembership() async throws {
        let context = makeContext(named: "failed-mount")
        defer { try? FileManager.default.removeItem(at: context.tempDirectory) }
        let repo = context.store.addRepo(at: context.tempDirectory.appending(path: "repo"))
        let worktree = try #require(context.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = context.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let source = OrderedRecordingFilesystemSource()
        let coordinator = makeCoordinator(context: context, source: source)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()
        await source.resetOperations()

        let mountedView = coordinator.mountCurrentTerminalContent(
            pane: pane,
            initialFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
            authority: .released(PaneId(existingUUID: pane.id))
        )
        await #expect(throws: WorkspaceUndoCompositionFailure.missingTarget) {
            try await coordinator.executeInsertPane(
                source: .newTerminal,
                targetTabId: UUIDv7.generate(),
                targetPaneId: UUIDv7.generate(),
                direction: .right,
                sizingMode: .halveTarget
            )
        }
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        #expect(mountedView == nil)
        #expect(await source.operations().isEmpty)
        await coordinator.shutdown()
    }

    @Test("accepted pane effects request one trace identity fleet capture per drain")
    func acceptedPaneEffectsRequestOneTraceIdentityFleetCapturePerDrain() async throws {
        let context = makeContext(named: "trace-identity")
        defer { try? FileManager.default.removeItem(at: context.tempDirectory) }
        let repo = context.store.addRepo(at: context.tempDirectory.appending(path: "repo"))
        let worktree = try #require(context.store.repo(repo.id)?.worktrees.first { $0.isMainWorktree })
        let pane = context.store.createPane(
            launchDirectory: worktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let source = OrderedRecordingFilesystemSource()
        let traceIdentityRecorder = TraceIdentityFleetCaptureRecorder()
        let coordinator = makeCoordinator(
            context: context,
            source: source,
            traceIdentityRefreshHandler: { traceIdentityRecorder.recordFleetCapture() }
        )
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        coordinator.upsertPaneFilesystemProjectionContext(for: pane)
        coordinator.upsertPaneFilesystemProjectionContext(for: pane)
        await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

        #expect(traceIdentityRecorder.fleetCaptureCount == 1)
        await coordinator.shutdown()
    }

    private func makeContext(named name: String) -> FilesystemEffectsTestContext {
        FilesystemEffectsTestContext(
            store: WorkspaceStore(),
            bus: makeTestPaneRuntimeEventBus(),
            tempDirectory: FileManager.default.temporaryDirectory
                .appending(path: "agentstudio-filesystem-effects-\(name)-\(UUID().uuidString)")
        )
    }

    private func makeCoordinator(
        context: FilesystemEffectsTestContext,
        source: OrderedRecordingFilesystemSource,
        surfaceManager: WorkspaceSurfaceManaging = MockFilesystemCoordinatorSurfaceManager(),
        traceIdentityRefreshHandler: (@MainActor @Sendable () -> Void)? = nil
    ) -> WorkspaceSurfaceCoordinator {
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        return WorkspaceSurfaceCoordinator(
            store: context.store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: context.store),
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: context.bus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: source,
            filesystemProjectionIndex: FilesystemProjectionIndex(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom(),
            traceIdentityRefreshHandler: traceIdentityRefreshHandler
        )
    }
}

@MainActor
private struct FilesystemEffectsTestContext {
    let store: WorkspaceStore
    let bus: EventBus<RuntimeEnvelope>
    let tempDirectory: URL
}

@MainActor
private final class TraceIdentityFleetCaptureRecorder {
    private(set) var fleetCaptureCount = 0

    func recordFleetCapture() {
        fleetCaptureCount += 1
    }
}
