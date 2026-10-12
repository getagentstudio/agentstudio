import AgentStudioInfrastructure
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

extension WorkspaceSurfaceCoordinatorTests {
    @Test("filesystem sync owns roots without publishing direct activity demand")
    func filesystemSyncOwnsRootsWithoutPublishingDirectActivityDemand() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-sync-roots-\(UUIDv7.generate().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WorkspaceStore()
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/repo-sync-roots-\(UUIDv7.generate().uuidString)"))
        guard let primaryWorktree = store.repo(repo.id)?.worktrees.first(where: \.isMainWorktree) else {
            Issue.record("Expected addRepo to create a main worktree")
            return
        }
        let secondaryWorktree = Worktree(
            repoId: repo.id,
            name: "feature-a",
            path: repo.repoPath.appending(path: "feature-a")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [primaryWorktree, secondaryWorktree])
        let reconciledSecondaryWorktree = try reconciledWorktree(
            in: store,
            repoId: repo.id,
            path: secondaryWorktree.path
        )

        let primaryPane = store.createPane(
            launchDirectory: primaryWorktree.path,
            facets: PaneContextFacets(
                repoId: repo.id,
                worktreeId: primaryWorktree.id,
                cwd: primaryWorktree.path
            )
        )
        _ = appendAndActivateSingleTab(for: primaryPane.id, in: store)

        let filesystemSource = CoordinatorRecordingFilesystemSource()
        let paneEventBus = EventBus<RuntimeEnvelope>()
        let coordinator = makeFilesystemSyncCoordinator(
            store: store,
            filesystemSource: filesystemSource,
            paneEventBus: paneEventBus
        )

        await waitUntilFilesystemState(
            source: filesystemSource,
            timeout: .milliseconds(600)
        ) { snapshot in
            Set(snapshot.registeredRoots.keys) == Set([primaryWorktree.id, reconciledSecondaryWorktree.id])
                && snapshot.activityByWorktreeId.isEmpty
                && snapshot.activePaneWorktreeId == nil
        }

        let tertiaryWorktree = Worktree(
            repoId: repo.id,
            name: "feature-b",
            path: repo.repoPath.appending(path: "feature-b")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [primaryWorktree, tertiaryWorktree])
        let reconciledTertiaryWorktree = try reconciledWorktree(
            in: store,
            repoId: repo.id,
            path: tertiaryWorktree.path
        )
        coordinator.topologyDidChange(
            WorktreeTopologyDelta(
                repoId: repo.id,
                addedWorktreeIds: [reconciledTertiaryWorktree.id],
                removedWorktrees: [
                    RemovedWorktreeEntry(id: reconciledSecondaryWorktree.id, path: reconciledSecondaryWorktree.path)
                ],
                preservedWorktreeIds: [primaryWorktree.id],
                didChange: true,
                traceId: nil
            )
        )

        await waitUntilFilesystemState(
            source: filesystemSource,
            timeout: .milliseconds(600)
        ) { snapshot in
            Set(snapshot.registeredRoots.keys) == Set([primaryWorktree.id, reconciledTertiaryWorktree.id])
                && snapshot.activityByWorktreeId.isEmpty
                && snapshot.activePaneWorktreeId == nil
        }

        let tertiaryPane = store.createPane(
            launchDirectory: reconciledTertiaryWorktree.path,
            facets: PaneContextFacets(
                repoId: repo.id,
                worktreeId: reconciledTertiaryWorktree.id,
                cwd: reconciledTertiaryWorktree.path
            )
        )
        let tertiaryTab = Tab(paneId: tertiaryPane.id)
        store.appendTab(tertiaryTab)
        coordinator.upsertPaneFilesystemProjectionContext(for: tertiaryPane)
        try await coordinator.execute(WorkspaceActionCommand.selectTab(tabId: tertiaryTab.id))

        await waitUntilFilesystemState(
            source: filesystemSource,
            timeout: .milliseconds(600)
        ) { snapshot in
            Set(snapshot.registeredRoots.keys) == Set([primaryWorktree.id, reconciledTertiaryWorktree.id])
                && snapshot.activityByWorktreeId.isEmpty
                && snapshot.activePaneWorktreeId == nil
        }
    }

    @Test("syncRootsAndActivity excludes unavailable repos from filesystem registration")
    func syncRootsAndActivityExcludesUnavailableRepos() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-sync-unavailable-\(UUIDv7.generate().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WorkspaceStore()
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/repo-sync-unavailable-\(UUIDv7.generate().uuidString)"))
        store.markRepoUnavailable(repo.id)

        let filesystemSource = CoordinatorRecordingFilesystemSource()
        let paneEventBus = EventBus<RuntimeEnvelope>()
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: CoordinatorFilesystemMockSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: paneEventBus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: filesystemSource,
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )

        await waitUntilFilesystemState(
            source: filesystemSource,
            timeout: .milliseconds(600)
        ) { snapshot in
            snapshot.registeredRoots.isEmpty
                && snapshot.activityByWorktreeId.isEmpty
                && snapshot.activePaneWorktreeId == nil
        }

        _ = coordinator
    }

    @Test("filesystem sync converges to latest roots when updates arrive during an in-flight pass")
    func syncRootsAndActivityConvergesUnderInFlightUpdates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-sync-converge-\(UUIDv7.generate().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WorkspaceStore()
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/repo-sync-converge-\(UUIDv7.generate().uuidString)"))
        guard let mainWorktree = store.repo(repo.id)?.worktrees.first(where: \.isMainWorktree) else {
            Issue.record("Expected addRepo to create a main worktree")
            return
        }
        let staleWorktree = Worktree(
            repoId: repo.id,
            name: "stale-branch",
            path: repo.repoPath.appending(path: "stale-branch")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [mainWorktree, staleWorktree])
        let reconciledStaleWorktree = try #require(
            store.repo(repo.id)?.worktrees.first(where: { $0.path == staleWorktree.path })
        )

        let primaryPane = store.createPane(
            launchDirectory: mainWorktree.path,
            facets: PaneContextFacets(
                repoId: repo.id,
                worktreeId: mainWorktree.id,
                cwd: mainWorktree.path
            )
        )
        let primaryTab = Tab(paneId: primaryPane.id)
        store.appendTab(primaryTab)
        store.setActiveTab(primaryTab.id)

        let filesystemSource = CoordinatorDelayingFilesystemSource(operationDelayTurns: 32)
        let paneEventBus = EventBus<RuntimeEnvelope>()
        let gitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: CoordinatorFilesystemMockSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: paneEventBus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: gitStatusPhysicalGate,
            filesystemSource: filesystemSource,
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        _ = coordinator

        // Trigger a second desired state while the initial sync pass is still executing.
        let latestWorktree = Worktree(
            repoId: repo.id,
            name: "latest-branch",
            path: repo.repoPath.appending(path: "latest-branch")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [mainWorktree, latestWorktree])
        coordinator.topologyDidChange(
            WorktreeTopologyDelta(
                repoId: repo.id,
                addedWorktreeIds: [latestWorktree.id],
                removedWorktrees: [
                    RemovedWorktreeEntry(id: reconciledStaleWorktree.id, path: reconciledStaleWorktree.path)
                ],
                preservedWorktreeIds: [mainWorktree.id],
                didChange: true,
                traceId: nil
            )
        )

        await waitUntilFilesystemState(
            source: filesystemSource,
            timeout: .seconds(2)
        ) { snapshot in
            Set(snapshot.registeredRoots.keys) == Set([mainWorktree.id, latestWorktree.id])
                && snapshot.registeredRoots[reconciledStaleWorktree.id] == nil
                && snapshot.activityByWorktreeId.isEmpty
                && snapshot.activePaneWorktreeId == nil
        }
    }

    @Test("topology effect handler with no removed worktrees still syncs roots and does not orphan panes")
    func topologyEffectHandlerWithoutRemovedWorktreesStillSyncsRoots() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-empty-delta-\(UUIDv7.generate().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WorkspaceStore()
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/repo-empty-delta-\(UUIDv7.generate().uuidString)"))
        guard let mainWorktree = store.repo(repo.id)?.worktrees.first(where: \.isMainWorktree) else {
            Issue.record("Expected addRepo to create main worktree")
            return
        }

        let pane = store.createPane(
            launchDirectory: mainWorktree.path,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: mainWorktree.id, cwd: mainWorktree.path)
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        let filesystemSource = CoordinatorRecordingFilesystemSource()
        let coordinator = makeFilesystemSyncCoordinator(
            store: store,
            filesystemSource: filesystemSource,
            paneEventBus: EventBus<RuntimeEnvelope>()
        )
        _ = coordinator

        let newWorktree = Worktree(
            repoId: repo.id,
            name: "feature-added",
            path: repo.repoPath.appending(path: "feature-added")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [mainWorktree, newWorktree])
        let reconciledNewWorktree = try reconciledWorktree(
            in: store,
            repoId: repo.id,
            path: newWorktree.path
        )

        coordinator.topologyDidChange(
            WorktreeTopologyDelta(
                repoId: repo.id,
                addedWorktreeIds: [reconciledNewWorktree.id],
                removedWorktrees: [],
                preservedWorktreeIds: [mainWorktree.id],
                didChange: true,
                traceId: nil
            )
        )

        await waitUntilFilesystemState(
            source: filesystemSource,
            timeout: .milliseconds(600)
        ) { snapshot in
            Set(snapshot.registeredRoots.keys) == Set([mainWorktree.id, reconciledNewWorktree.id])
        }

        let updatedPane = try #require(store.pane(pane.id))
        #expect(updatedPane.residency == .active)
    }

    private func waitUntilFilesystemState(
        source: CoordinatorRecordingFilesystemSource,
        timeout: Duration,
        condition: @escaping @Sendable (CoordinatorFilesystemSourceSnapshot) -> Bool
    ) async {
        await assertEventuallyAsync("filesystem sync state", minimumTurns: 200, timeout: timeout) {
            condition(await source.snapshot())
        }
    }

    private func waitUntilFilesystemState(
        source: CoordinatorDelayingFilesystemSource,
        timeout: Duration,
        condition: @escaping @Sendable (CoordinatorFilesystemSourceSnapshot) -> Bool
    ) async {
        await assertEventuallyAsync("filesystem sync state", minimumTurns: 200, timeout: timeout) {
            condition(await source.snapshot())
        }
    }
}

struct CoordinatorFilesystemSourceSnapshot: Sendable, CustomStringConvertible {
    let registeredRoots: [UUID: URL]
    let activityByWorktreeId: [UUID: Bool]
    let activePaneWorktreeId: UUID?

    var description: String {
        "registered=\(registeredRoots.keys.map(\.uuidString).sorted()) "
            + "activity=\(activityByWorktreeId.mapValues { $0 ? "active" : "idle" }) "
            + "activePaneWorktree=\(activePaneWorktreeId?.uuidString ?? "nil")"
    }
}

actor CoordinatorRecordingFilesystemSource: WorkspaceFilesystemSourceManaging {
    private(set) var registeredRoots: [UUID: URL] = [:]
    private(set) var activityByWorktreeId: [UUID: Bool] = [:]
    private(set) var activePaneWorktreeId: UUID?
    private(set) var topologyAssertionGeneration: UInt64?

    func start() async {}

    func shutdown() async {}

    func register(worktreeId: UUID, repoId: UUID, rootPath: URL) {
        registeredRoots[worktreeId] = rootPath
    }

    func unregister(worktreeId: UUID) {
        registeredRoots.removeValue(forKey: worktreeId)
        activityByWorktreeId.removeValue(forKey: worktreeId)
        if activePaneWorktreeId == worktreeId {
            activePaneWorktreeId = nil
        }
    }

    func assertTopology(_ assertion: FilesystemTopologyAssertion) async {
        guard topologyAssertionGeneration.map({ assertion.generation >= $0 }) ?? true else { return }
        topologyAssertionGeneration = assertion.generation
        let desiredWorktreeIds = Set(assertion.contextsByWorktreeId.keys)
        registeredRoots = assertion.contextsByWorktreeId.mapValues(\.rootPath)
        activityByWorktreeId = activityByWorktreeId.filter { desiredWorktreeIds.contains($0.key) }
        if let activePaneWorktreeId, !desiredWorktreeIds.contains(activePaneWorktreeId) {
            self.activePaneWorktreeId = nil
        }
    }

    func setActivity(worktreeId: UUID, isActiveInApp: Bool) {
        activityByWorktreeId[worktreeId] = isActiveInApp
    }

    func setActivePaneWorktree(worktreeId: UUID?) {
        activePaneWorktreeId = worktreeId
    }

    func snapshot() -> CoordinatorFilesystemSourceSnapshot {
        CoordinatorFilesystemSourceSnapshot(
            registeredRoots: registeredRoots,
            activityByWorktreeId: activityByWorktreeId,
            activePaneWorktreeId: activePaneWorktreeId
        )
    }
}

actor CoordinatorDelayingFilesystemSource: WorkspaceFilesystemSourceManaging {
    private let operationDelayTurns: Int
    private(set) var registeredRoots: [UUID: URL] = [:]
    private(set) var activityByWorktreeId: [UUID: Bool] = [:]
    private(set) var activePaneWorktreeId: UUID?
    private(set) var topologyAssertionGeneration: UInt64?

    init(operationDelayTurns: Int) {
        self.operationDelayTurns = operationDelayTurns
    }

    func start() async {}

    func shutdown() async {}

    func register(worktreeId: UUID, repoId: UUID, rootPath: URL) async {
        await settleDelay()
        registeredRoots[worktreeId] = rootPath
    }

    func unregister(worktreeId: UUID) async {
        await settleDelay()
        registeredRoots.removeValue(forKey: worktreeId)
        activityByWorktreeId.removeValue(forKey: worktreeId)
        if activePaneWorktreeId == worktreeId {
            activePaneWorktreeId = nil
        }
    }

    func assertTopology(_ assertion: FilesystemTopologyAssertion) async {
        await settleDelay()
        guard topologyAssertionGeneration.map({ assertion.generation >= $0 }) ?? true else { return }
        topologyAssertionGeneration = assertion.generation
        let desiredWorktreeIds = Set(assertion.contextsByWorktreeId.keys)
        registeredRoots = assertion.contextsByWorktreeId.mapValues(\.rootPath)
        activityByWorktreeId = activityByWorktreeId.filter { desiredWorktreeIds.contains($0.key) }
        if let activePaneWorktreeId, !desiredWorktreeIds.contains(activePaneWorktreeId) {
            self.activePaneWorktreeId = nil
        }
    }

    func setActivity(worktreeId: UUID, isActiveInApp: Bool) async {
        await settleDelay()
        activityByWorktreeId[worktreeId] = isActiveInApp
    }

    func setActivePaneWorktree(worktreeId: UUID?) async {
        await settleDelay()
        activePaneWorktreeId = worktreeId
    }

    func snapshot() -> CoordinatorFilesystemSourceSnapshot {
        CoordinatorFilesystemSourceSnapshot(
            registeredRoots: registeredRoots,
            activityByWorktreeId: activityByWorktreeId,
            activePaneWorktreeId: activePaneWorktreeId
        )
    }

    private func settleDelay() async {
        for _ in 0..<operationDelayTurns {
            await Task.yield()
        }
    }
}

final class CoordinatorFilesystemMockSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config _: Ghostty.SurfaceConfiguration,
        metadata _: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.operationFailed("mock"))
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        _ = surfaceId
        _ = paneId
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        _ = surfaceId
        _ = reason
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {
        _ = surfaceId
    }
}
