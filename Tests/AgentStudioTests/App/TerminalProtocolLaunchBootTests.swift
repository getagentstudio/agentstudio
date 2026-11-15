import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal

@MainActor
@Suite("Terminal protocol admission through AppDelegate launch", .serialized)
struct TerminalProtocolLaunchBootTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("every streamed legacy classification survives the real first-frame boot gate")
    func streamedLegacyPanesSurviveLaunchBoot() async throws {
        let source = LocalFactSource<UUID, BootFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .launchFinished }))
        let facts = try source.attach()
        let scope = UUIDv7.generate()
        let clock = TestPushClock()
        let fixture = try await makeFixture(delay: .clock(clock))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.delegate.installedWorkspacePreparedContentMountOwners.coordinator.terminalClassificationDidFinish = {
            source.sink(scope, .classified)
        }
        // IPC is unrelated to classification; this existing owned task slot suppresses real server startup.
        let ipc = Task<Void, Never> {}
        fixture.delegate.appIPCInitializationTask = ipc
        let launch = Task { @MainActor in
            await fixture.delegate.finishLaunchRestore(
                using: CGRect(x: 0, y: 0, width: 800, height: 600), source: "protocolUpgradeRegression")
            source.sink(scope, .launchFinished)
            source.end()
        }
        do {
            try await facts.expectNext(in: scope, .classified)
            #expect(fixture.manager.createdPaneIds.isEmpty)
            #expect(!fixture.delegate.launchRestoreObservationState.didComplete)
            fixture.window.recordFirstInteractiveFramePublished(source: .presented)
            await launch.value
            await ipc.value
            try await facts.expectNext(in: scope, .launchFinished)
            #expect(clock.pendingSleepCount == 0)
            for pane in fixture.panes {
                #expect(
                    fixture.registry.terminalStatusPlaceholderView(for: pane.id)?.mode == .incompatibleSessionVersion)
                #expect(fixture.registry.terminalView(for: pane.id)?.surfaceId == nil)
            }
            #expect(fixture.manager.createdPaneIds.isEmpty)
            #expect(fixture.coordinator.terminalProtocolClassificationTasksByPaneID.isEmpty)
            #expect(fixture.delegate.launchRestoreObservationState.didComplete)
            #expect(
                await fixture.delegate.installedWorkspacePreparedContentMountOwners.coordinator
                    .terminalActivationDeferralOutcome() == .completed)
            try await facts.finish()
        } catch {
            fixture.window.recordFirstInteractiveFramePublished(source: .presented)
            launch.cancel()
            await launch.value
            await ipc.value
            await fixture.coordinator.shutdown()
            await fixture.delegate.restoreResumeReadiness.shutdown()
            try? await facts.finish()
            do {
                try await fixture.delegate.startupTraceRecorder.drain()
                try await fixture.delegate.traceRuntime.flush()
            } catch { Issue.record("Private boot trace cleanup also failed: \(error)") }
            throw error
        }
        await fixture.coordinator.shutdown()
        await fixture.delegate.restoreResumeReadiness.shutdown()
        try await fixture.delegate.startupTraceRecorder.drain()
        try await fixture.delegate.traceRuntime.flush()
    }

    private enum BootFact: Equatable, Sendable { case classified, launchFinished }

    private struct Fixture {
        let delegate: AppDelegate
        let coordinator: WorkspaceSurfaceCoordinator
        let registry: ViewRegistry
        let manager: TerminalRestoreCapturingSurfaceManager
        let window: WindowLifecycleAtom
        let panes: [Pane]
        let root: URL
    }

    private func makeFixture(delay: AsyncDelay) async throws -> Fixture {
        let root = URL(filePath: "/tmp/pb-\(UUIDv7.generate().uuidString.suffix(12))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspaceID = UUIDv7.generate()
        let sqlite = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let seeding = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: sqlite.backend), startsObserving: false)
        let panes = (0..<2).map { _ in seeding.createPane(launchDirectory: root) }
        for pane in panes {
            seeding.appendTab(Tab(paneId: pane.id))
            let sessionID = try #require(pane.terminalState?.zmxSessionID)
            try Data("legacy endpoint without current-protocol identity".utf8).write(
                to: root.appending(path: sessionID.rawValue))
        }
        try #require(await seeding.flushAsync() == .persisted)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: sqlite.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID), sqliteDatastore: datastore,
            startsObserving: false)
        let cohort: WorkspacePreparedContentMountCohort
        switch await store.loadCanonicalComposition() {
        case .loaded(let acceptance): cohort = acceptance.contentMountCohort
        case let result:
            throw NSError(
                domain: "ProtocolBootFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected persisted canonical composition, got \(result)"])
        }
        let manager = TerminalRestoreCapturingSurfaceManager()
        let registry = ViewRegistry()
        let window = WindowLifecycleAtom(deferralDelay: delay)
        window.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 800, height: 600))
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: registry, runtime: SessionRuntime(store: store), surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(), windowLifecycleStore: window,
            ipcLifecycle: .testUnavailable, bridgePaneAttendance: BridgePaneAttendanceAtom())
        let configuration = SessionConfiguration(
            isEnabled: true, zmxPath: "/usr/bin/false", zmxDir: root.path, healthCheckInterval: 30, maxCheckpointAge: 60
        )
        coordinator.sessionConfig = configuration
        coordinator.terminalRestoreRuntime = TerminalRestoreRuntime(sessionConfiguration: configuration)
        let trace = AgentStudioTraceRuntime(
            configuration: .from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": root.appending(path: "trace").path,
            ]),
            processIdentifier: 4242, timeUnixNano: { 1 })
        let delegate = AppDelegate(
            traceRuntime: trace, startupTraceRecorder: AgentStudioStartupTraceRecorder(traceRuntime: trace),
            scrollbackStore: ScrollbackStore(directoryURL: root.appending(path: "saved")))
        delegate.store = store
        delegate.viewRegistry = registry
        delegate.workspaceSurfaceCoordinator = coordinator
        delegate.workspaceSQLiteDatastore = datastore
        delegate.windowLifecycleStore = window
        delegate.acceptWorkspacePreparedContentMountCohort(cohort)
        delegate.bootInstallPreparedContentMountOwners(coordinator: coordinator, terminalActivationDeferralDelay: delay)
        return Fixture(
            delegate: delegate, coordinator: coordinator, registry: registry, manager: manager, window: window,
            panes: panes, root: root)
    }
}
