import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ZmxE2ETests {
    @Test(
        "the mounted notice's Restart stops the archived daemon and mounts its saved cold command",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_ZMX_LEGACY_FIXTURE"] != nil)
    )
    func noticeRestartRunsProductionOwner() async throws {
        try await withRealBackend { harness, _ in
            try await Self.exerciseNoticeRestart(harness: harness, refusesStop: false)
        }
    }

    @Test("a refused Restart keeps the notice and stored protocol untouched")
    func noticeRestartPreservesNoticeWhenStopRefuses() async throws {
        try await withRealBackend { harness, _ in
            try await Self.exerciseNoticeRestart(harness: harness, refusesStop: true)
        }
    }

    @MainActor
    private static func exerciseNoticeRestart(harness: ZmxTestHarness, refusesStop: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: fixture.backend), startsObserving: false)
        let pane = store.createPane(launchDirectory: URL(filePath: harness.scratchHomeDirectory))
        let sessionID = try #require(pane.terminalState?.zmxSessionID)
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        try #require(await store.flushAsync() == .persisted)
        let daemon = try await prepareRestartEndpoint(harness: harness, sessionID: sessionID, refusesStop: refusesStop)
        let currentPath = try #require(harness.zmxPath)
        let configuration = SessionConfiguration(
            isEnabled: true, zmxPath: currentPath, zmxDir: harness.zmxDir,
            healthCheckInterval: 30, maxCheckpointAge: 3600)
        let manager = TerminalRestoreCapturingSurfaceManager()
        let registry = ViewRegistry()
        let window = WindowLifecycleAtom()
        window.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 800, height: 600))
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: registry, runtime: SessionRuntime(store: store), surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(), windowLifecycleStore: window,
            ipcLifecycle: .testUnavailable, bridgePaneAttendance: BridgePaneAttendanceAtom())
        coordinator.sessionConfig = configuration
        coordinator.terminalRestoreRuntime = TerminalRestoreRuntime(sessionConfiguration: configuration)
        do {
            let scrollback = ScrollbackStore(
                directoryURL: URL(filePath: harness.scratchHomeDirectory).appending(path: "saved"))
            let savedText = "restart-owner-scrollback-\(UUIDv7.generate())"
            #expect(
                try await scrollback.store(paneId: PaneId(existingUUID: pane.id), capture: Data(savedText.utf8))
                    == .written)
            let plan = await TerminalColdRestorePlanBuilder.buildPlan(
                pane: pane, sessionID: sessionID,
                launchPaths: .init(
                    zmxExecutablePath: currentPath, zmxDirectoryPath: harness.zmxDir, loginShellPath: "/bin/sh"),
                repositoryMainFolder: nil, scrollbackStore: scrollback)
            try await mountAndClickRestart(
                coordinator: coordinator, registry: registry, pane: pane, tab: tab, plan: plan)
            #expect(coordinator.incompatibleTerminalRestartTasksByPaneID.isEmpty)
            if refusesStop {
                #expect(registry.terminalStatusPlaceholderView(for: pane.id)?.mode == .incompatibleSessionVersion)
                #expect(coordinator.incompatibleTerminalPlansByPaneID[pane.id] == plan)
                #expect(manager.createdPaneIds.isEmpty)
                #expect(try fixture.coreRepository.terminalSessionProtocolVersion(sessionID) == nil)
            } else {
                let originalDaemon = try #require(daemon)
                #expect(ZmxSessionControl.currentIncarnation(forPID: originalDaemon.pid) != originalDaemon)
                #expect(try fixture.coreRepository.terminalSessionProtocolVersion(sessionID) == 1)
                #expect(coordinator.incompatibleTerminalPlansByPaneID[pane.id] == nil)
                let command = try #require(
                    manager.createdConfigsByPaneId[pane.id]?.startupStrategy.startupCommandForSurface)
                #expect(command.contains(plan.sessionID.rawValue))
                try await proveMountedCommandReplaysScrollback(
                    command, plan: plan, savedText: savedText, harness: harness)
            }
        } catch {
            await coordinator.shutdown()
            // Preserve the primary assertion if Restart never ran; the current CLI cannot kill a v0 daemon.
            if let daemon, ZmxSessionControl.currentIncarnation(forPID: daemon.pid) == daemon {
                do {
                    try await ZmxIncompatibleSessionStop.stop(
                        sessionID: sessionID, directory: harness.zmxDir, expectedIdentity: nil)
                } catch { Issue.record("Archived Restart fixture cleanup also failed: \(error)") }
            }
            throw error
        }
        await coordinator.shutdown()
    }

    @MainActor
    private static func mountAndClickRestart(
        coordinator: WorkspaceSurfaceCoordinator, registry: ViewRegistry, pane: Pane, tab: Tab,
        plan: TerminalColdRestorePlan
    ) async throws {
        let paneID = PaneId(existingUUID: pane.id)
        let result = await coordinator.mountPreparedTerminalContent(
            admission: .init(
                generation: .init(),
                descriptor: .init(pane: pane, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: tab.id)),
                attempt: 1, restoreKind: .incompatible(0, fallback: plan)),
            initialFrame: nil, authority: .released(paneID))
        #expect(
            result == .failed(failure: .surfaceCreationFailed(code: "incompatible_session_version"), retry: .doNotRetry)
        )
        let notice = try #require(registry.terminalStatusPlaceholderView(for: pane.id))
        #expect(notice.mode == .incompatibleSessionVersion)
        #expect(registry.terminalView(for: pane.id)?.surfaceId == nil)
        let overlay = try #require(notice.subviews.compactMap { $0 as? SurfaceErrorOverlayView }.first)
        // This is the callback installed on the rendered notice, not a reconstruction of Restart's sequence.
        let restart = try #require(overlay.onRestart)
        restart()
        let task = try #require(
            coordinator.incompatibleTerminalRestartTasksByPaneID[pane.id], "Restart must own a task")
        await task.value
    }

    private static func prepareRestartEndpoint(
        harness: ZmxTestHarness, sessionID: ZmxSessionID, refusesStop: Bool
    ) async throws -> ZmxProcessIncarnation? {
        let path = harness.sessionSocketPath(for: sessionID.rawValue)
        if refusesStop {
            // A present but unverifiable endpoint must not be treated as permission to replace it.
            try Data("not a listening socket".utf8).write(to: URL(filePath: path))
            return nil
        }
        let archivedPath = try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_ZMX_LEGACY_FIXTURE"])
        let marker = "restart-owner-ready-\(UUIDv7.generate())"
        let creation = try await RunToExitProcessExecutor().execute(
            command: archivedPath, args: ["run", sessionID.rawValue, "/bin/echo", marker], cwd: nil,
            environment: ZmxTestHarness.hermeticChildEnvironment(
                zmxDir: harness.zmxDir, scratchHomeDirectory: harness.scratchHomeDirectory))
        try #require(creation.succeeded, Comment(rawValue: creation.stderr))
        #expect(creation.stdout.contains(marker))
        return try ZmxIncompatibleSessionStop.verifiedDaemon(path: path)
    }

    private static func proveMountedCommandReplaysScrollback(
        _ command: String, plan: TerminalColdRestorePlan, savedText: String, harness: ZmxTestHarness
    ) async throws {
        // Ghostty creation is outside this proof. Execute exactly what production handed its surface boundary.
        let (process, created) = try harness.spawnShellCommandWithoutWaitingForSettlement(
            command, sessionId: plan.sessionID.rawValue)
        try await harness.waitUntilSessionSettled(
            sessionId: plan.sessionID.rawValue, zmxLauncherProcessID: process.processIdentifier,
            sessionCreatedStep: created)
        let outcome = await ColdStartObserver().observeColdStart(
            zmxDirectory: plan.zmxDirectory, socketPath: harness.sessionSocketPath(for: plan.sessionID.rawValue),
            bootID: try await WorkspaceUndoJournalClock.current().bootID, attemptID: plan.attemptID)
        #expect(outcome == .handedOff)
        let history = try await harness.sessionHistory(sessionId: plan.sessionID.rawValue)
        #expect(history.contains(savedText))
        #expect(history.contains("restored after restart"))
    }
}
