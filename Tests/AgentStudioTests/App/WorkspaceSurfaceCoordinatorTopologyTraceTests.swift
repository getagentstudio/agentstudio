import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorTopologyTraceTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("closing four Bridge tabs keeps topology lookup telemetry bounded")
    func closeFourBridgeTabsKeepsTopologyLookupTelemetryBounded() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-close-bridge-topology-\(UUID().uuidString)")
        let traceDirectory = temporaryTraceDirectoryURL()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: traceDirectory)
        }
        let runtime = makePerformanceTraceRuntime(traceDirectory: traceDirectory)
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
        let paneEventBus = makeTestPaneRuntimeEventBus()
        let store = try makeWorkspaceJournalTestStore()
        let coordinator = makeTopologyTraceCoordinator(
            store: store,
            paneEventBus: paneEventBus,
            performanceTraceRecorder: recorder
        )
        do {
            let repo = store.addRepo(at: tempDir.appending(path: "bridge-root"))
            let worktree = try #require(store.repo(repo.id)?.worktrees.single)
            var tabs: [Tab] = []
            for index in 0..<4 {
                let pane = makeCWDOnlyBridgePane(store, title: "Bridge \(index)", cwd: worktree.path)
                let tab = Tab(paneId: pane.id, name: "Bridge \(index)")
                store.appendTab(tab)
                tabs.append(tab)
            }
            store.setActiveTab(tabs[0].id)
            await coordinator.waitForFilesystemRootsAndActivitySyncIdle()

            let firstCoordinatorCWD = URL(
                filePath: worktree.path.appending(path: "Sources").path,
                directoryHint: .isDirectory
            )
            let secondCoordinatorCWD = URL(
                filePath: worktree.path.appending(path: "Tests").path,
                directoryHint: .isDirectory
            )
            let tracedPaneID = try #require(tabs[0].activePaneId)
            _ = await paneEventBus.post(
                makeRuntimeEnvelope(
                    source: .pane(PaneId(existingUUID: tracedPaneID)),
                    paneKind: .terminal,
                    seq: 1,
                    commandId: nil,
                    correlationId: nil,
                    timestamp: ContinuousClock().now,
                    epoch: 0,
                    event: .terminal(.cwdChanged(firstCoordinatorCWD.path))
                )
            )
            await eventually("coordinator should consume the first runtime CWD fact") {
                store.pane(tracedPaneID)?.metadata.cwd == firstCoordinatorCWD
            }
            _ = await paneEventBus.post(
                makeRuntimeEnvelope(
                    source: .pane(PaneId(existingUUID: tracedPaneID)),
                    paneKind: .terminal,
                    seq: 2,
                    commandId: nil,
                    correlationId: nil,
                    timestamp: ContinuousClock().now,
                    epoch: 0,
                    event: .terminal(.cwdChanged(secondCoordinatorCWD.path))
                )
            )
            await eventually("coordinator should consume the second runtime CWD fact") {
                store.pane(tracedPaneID)?.metadata.cwd == secondCoordinatorCWD
            }

            for tab in tabs {
                for _ in 0..<16 {
                    _ = store.paneAtom.paneSnapshot()
                }
                try await coordinator.execute(.closeTab(tabId: tab.id))
            }
            try await coordinator.undoCloseTab()
            for _ in 0..<16 {
                _ = store.paneAtom.paneSnapshot()
            }
            try await recorder.drain()

            let outputFileURL = try #require(runtime.outputFileURL)
            let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
            #expect(countOccurrences(of: "\"body\":\"performance.topology.repo_and_worktree\"", in: contents) == 2)
        } catch {
            await coordinator.shutdown()
            try? await runtime.shutdown()
            throw error
        }
        await coordinator.shutdown()
        try await runtime.shutdown()
    }

    private func makeTopologyTraceCoordinator(
        store: WorkspaceStore,
        paneEventBus: EventBus<RuntimeEnvelope>,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder
    ) -> WorkspaceSurfaceCoordinator {
        let fixtureSurfaceManager = MockPaneTabCommandSurfaceManager(
            createSurfaceResult: .failure(.ghosttyNotInitialized)
        )
        return WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: fixtureSurfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: fixtureSurfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            paneEventBus: paneEventBus,
            gitWorkingTreeStatusProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            gitStatusPhysicalGate: AgentStudioGitStatusPhysicalGate(),
            filesystemSource: TopologyTraceRecordingFilesystemSource(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom(),
            performanceTraceRecorder: performanceTraceRecorder
        )
    }

    private func makeCWDOnlyBridgePane(
        _ store: WorkspaceStore,
        title: String,
        cwd: URL
    ) -> Pane {
        store.createPane(
            content: .bridgePanel(
                BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: cwd.path,
                        baseline: .localDefaultBranch(branchName: "main"))
                )
            ),
            metadata: PaneMetadata(
                contentType: .diff,
                launchDirectory: cwd,
                title: title,
                facets: PaneContextFacets(cwd: cwd)
            )
        )
    }

    private func makePerformanceTraceRuntime(traceDirectory: URL) -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "close-bridge-topology-lookup",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 918,
            timeUnixNano: { 918 }
        )
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-close-bridge-topology-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor TopologyTraceRecordingFilesystemSource: WorkspaceFilesystemSourceManaging {
    private(set) var registeredRoots: [UUID: URL] = [:]
    private(set) var activityByWorktreeId: [UUID: Bool] = [:]
    private(set) var activePaneWorktreeId: UUID?

    func start() async {}

    func shutdown() async {}

    func register(worktreeId: UUID, repoId _: UUID, rootPath: URL) async {
        registeredRoots[worktreeId] = rootPath
    }

    func unregister(worktreeId: UUID) async {
        registeredRoots.removeValue(forKey: worktreeId)
        activityByWorktreeId.removeValue(forKey: worktreeId)
        if activePaneWorktreeId == worktreeId {
            activePaneWorktreeId = nil
        }
    }

    func assertTopology(_ assertion: FilesystemTopologyAssertion) async {
        let desiredWorktreeIds = Set(assertion.contextsByWorktreeId.keys)
        registeredRoots = assertion.contextsByWorktreeId.mapValues(\.rootPath)
        activityByWorktreeId = activityByWorktreeId.filter { desiredWorktreeIds.contains($0.key) }
        if let activePaneWorktreeId, !desiredWorktreeIds.contains(activePaneWorktreeId) {
            self.activePaneWorktreeId = nil
        }
    }

    func setActivity(worktreeId: UUID, isActiveInApp: Bool) async {
        activityByWorktreeId[worktreeId] = isActiveInApp
    }

    func setActivePaneWorktree(worktreeId: UUID?) async {
        activePaneWorktreeId = worktreeId
    }

}
