import AgentStudioInfrastructure
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal

@MainActor
@Suite("Stale terminal endpoint restore", .serialized)
struct TerminalStaleEndpointTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("a closed bound socket cold restores despite unavailable inventory")
    func closedSocketIsCold() async throws {
        let sessionID = ZmxSessionID.generateUUIDv7()
        let endpoint = try UnixSocketEndpointFixture(socketName: sessionID.rawValue, directoryID: UUIDv7.generate())
        defer { endpoint.cleanup() }
        try endpoint.closeSocket()
        #expect(try endpoint.connectionFailureErrno() == ECONNREFUSED)
        let probe = Probe()

        let kind = try await classify(sessionID: sessionID, directory: endpoint.directory, probe: probe)

        guard case .cold = kind else {
            Issue.record("A refused socket with no holder must cold restore")
            return
        }
        #expect(await probe.versions == [ZmxProtocol.version])
        #expect(await probe.identityObservations == 0)
    }

    @Test("a bound non-listening holder remains incompatible")
    func boundCreationGapIsNotDead() async throws {
        let sessionID = ZmxSessionID.generateUUIDv7()
        let endpoint = try UnixSocketEndpointFixture(socketName: sessionID.rawValue, directoryID: UUIDv7.generate())
        defer { endpoint.cleanup() }
        #expect(try endpoint.connectionFailureErrno() == ECONNREFUSED)
        let probe = Probe()

        let kind = try await classify(sessionID: sessionID, directory: endpoint.directory, probe: probe)

        guard case .incompatible = kind else {
            Issue.record("A bound holder cannot grant cold restore")
            return
        }
        #expect(await probe.versions.isEmpty)
    }

    @Test("Restart cold restores a stale socket but refuses a bound creation gap", arguments: [false, true])
    func noticeRestartRequiresNoBoundHolder(keepBoundHolder: Bool) async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: fixture.backend), startsObserving: false)
        let pane = store.createPane()
        let sessionID = try #require(pane.terminalState?.zmxSessionID)
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        try #require(await store.flushAsync() == .persisted)
        let endpoint = try UnixSocketEndpointFixture(socketName: sessionID.rawValue, directoryID: UUIDv7.generate())
        defer { endpoint.cleanup() }
        if !keepBoundHolder { try endpoint.closeSocket() }
        #expect(try endpoint.connectionFailureErrno() == ECONNREFUSED)
        let configuration = SessionConfiguration(
            isEnabled: true, zmxPath: "/usr/bin/true", zmxDir: endpoint.directory.path,
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
            let plan = await TerminalColdRestorePlanBuilder.buildPlan(
                pane: pane, sessionID: sessionID,
                launchPaths: .init(
                    zmxExecutablePath: "/usr/bin/true", zmxDirectoryPath: endpoint.directory.path,
                    loginShellPath: "/bin/sh"),
                repositoryMainFolder: nil,
                scrollbackStore: ScrollbackStore(directoryURL: endpoint.directory.appending(path: "saved")))
            _ = await coordinator.mountPreparedTerminalContent(
                admission: .init(
                    generation: .init(),
                    descriptor: .init(
                        pane: pane, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: tab.id)),
                    attempt: 1, restoreKind: .incompatible(0, fallback: plan)),
                initialFrame: nil, authority: .released(PaneId(existingUUID: pane.id)))
            let notice = try #require(registry.terminalStatusPlaceholderView(for: pane.id))
            let overlay = try #require(notice.subviews.compactMap { $0 as? SurfaceErrorOverlayView }.first)
            let restart = try #require(overlay.onRestart)
            restart()
            let task = try #require(coordinator.incompatibleTerminalRestartTasksByPaneID[pane.id])
            await task.value
            if keepBoundHolder {
                #expect(notice.mode == .incompatibleSessionVersion)
                #expect(manager.createdPaneIds.isEmpty)
                #expect(try fixture.coreRepository.terminalSessionProtocolVersion(sessionID) == nil)
            } else {
                #expect(manager.createdPaneIds == [pane.id])
                let command = try #require(
                    manager.createdConfigsByPaneId[pane.id]?.startupStrategy.startupCommandForSurface)
                #expect(command.contains("Restored after restart"))
                #expect(try fixture.coreRepository.terminalSessionProtocolVersion(sessionID) == ZmxProtocol.version)
                #expect(coordinator.incompatibleTerminalPlansByPaneID[pane.id] == nil)
            }
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()
    }

    private func classify(sessionID: ZmxSessionID, directory: URL, probe: Probe) async throws -> TerminalRestoreKind {
        let pane = Pane(
            content: .terminal(.init(provider: .zmx, lifetime: .persistent, zmxSessionID: sessionID)),
            metadata: PaneMetadata(title: "Private endpoint"))
        let configuration = SessionConfiguration(
            isEnabled: true, zmxPath: "/usr/bin/true", zmxDir: directory.path,
            healthCheckInterval: 30, maxCheckpointAge: 3600)
        let resolver = TerminalRestoreKindResolver(
            sessionConfiguration: configuration, probe: probe,
            scrollbackStore: ScrollbackStore(directoryURL: directory.appending(path: "saved")),
            repositoryMainFolder: { _ in nil }, recordedProtocol: { _ in 0 },
            recordProtocol: { _, version in await probe.record(version) })
        return try #require(await resolver.resolveRestoreKind(for: pane))
    }

    private actor Probe: ZmxSessionRestoreProbing {
        var versions: [UInt8] = []
        var identityObservations = 0
        func discoverSessionInventory() async -> ZmxSessionInventory { .unavailable(.timedOut) }
        func observeSessionIdentity(_ sessionID: ZmxSessionID) async -> Data? {
            identityObservations += 1
            return nil
        }
        func record(_ version: UInt8) { versions.append(version) }
    }
}
