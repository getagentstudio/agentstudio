import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Incompatible terminal pane lifecycle", .serialized)
struct TerminalProtocolPaneLifecycleTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("new terminal creation records only the newly minted session's protocol")
    func newTerminalRecordsProtocolBeforePublication() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let restoredPane = store.createPane()
        let restoredID = try #require(restoredPane.terminalState?.zmxSessionID)
        store.appendTab(Tab(paneId: restoredPane.id))
        try #require(await store.flushAsync() == .persisted)

        let created = try await store.createTerminalPane(
            metadata: PaneMetadata(title: "New terminal"), placement: .newTab,
            nameForPane: { _ in "New terminal" },
            willPublish: { pane in
                do {
                    let sessionID = try #require(pane.terminalState?.zmxSessionID)
                    #expect(try fixture.coreRepository.terminalSessionProtocolVersion(sessionID) == 1)
                } catch { Issue.record(error) }
            })

        #expect(try await store.terminalSessionProtocolVersion(#require(created.terminalState?.zmxSessionID)) == 1)
        #expect(try await store.terminalSessionProtocolVersion(restoredID) == nil)
    }

    private actor CleanupRecorder: ZmxSessionControlling {
        private(set) var stops: [ZmxSessionID] = []
        private(set) var controls: [ZmxSessionID] = []
        func stop(_ sessionID: ZmxSessionID) { stops.append(sessionID) }
        func observeSessionIdentity(_ sessionID: ZmxSessionID) -> Data? {
            controls.append(sessionID)
            return nil
        }
        func retireVerifiedSession(_ sessionID: ZmxSessionID, expectedIdentity: Data) -> ZmxSessionCleanupStatus {
            controls.append(sessionID)
            return .pending
        }
    }

    @Test("legacy final expiry uses verified stop while Close sends no control")
    func finalExpiryRoutesIncompatibleSessionToStop() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let pane = store.createPane()
        let sessionID = try #require(pane.terminalState?.zmxSessionID)
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        try #require(await store.flushAsync() == .persisted)
        let manager = HarnessSurfaceManager()
        let time = WorkspaceUndoJournalTime(
            utc: Date(timeIntervalSince1970: 100), bootID: "protocol-test", uptimeNanoseconds: 100_000_000_000)
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store), surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(), windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom(), undoClock: { time })
        let recorder = CleanupRecorder()
        let expectedIdentity = Data("previously recorded legacy incarnation".utf8)
        try #require(
            try fixture.coreRepository.recordTerminalSessionIdentity(sessionID: sessionID, identity: expectedIdentity))
        do {
            try await coordinator.execute(.closeTab(tabId: tab.id))
            _ = try await coordinator.performTerminalSessionCleanupPass(
                using: recorder, canRetire: { _ in true },
                stopIncompatibleSession: { sessionID, _, identity in
                    #expect(identity == expectedIdentity)
                    await recorder.stop(sessionID)
                })
            #expect(await recorder.stops.isEmpty)
            #expect(await recorder.controls.isEmpty)
            let retirements = try await store.expireUndoCloses(
                time: .init(
                    utc: Date(timeIntervalSince1970: 500), bootID: time.bootID, uptimeNanoseconds: 500_000_000_000))
            coordinator.consumeUndoRetirements(retirements)
            _ = try await coordinator.performTerminalSessionCleanupPass(
                using: recorder, canRetire: { _ in true },
                stopIncompatibleSession: { sessionID, _, identity in
                    #expect(identity == expectedIdentity)
                    await recorder.stop(sessionID)
                })
            #expect(await recorder.stops == [sessionID])
            #expect(await recorder.controls.isEmpty)
            #expect(try fixture.coreRepository.pendingTerminalSessionIDs().isEmpty)
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()
    }

    @Test("notice mounts without a surface and Close plus Undo restores the same notice")
    func noticeSurvivesCloseAndUndo() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let pane = store.createPane()
        let sessionID = try #require(pane.terminalState?.zmxSessionID)
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        try #require(await store.flushAsync() == .persisted)
        let manager = HarnessSurfaceManager()
        let registry = ViewRegistry()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: registry, runtime: SessionRuntime(store: store), surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(), windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom())
        do {
            let plan = await TerminalColdRestorePlanBuilder.buildPlan(
                pane: pane, sessionID: sessionID,
                launchPaths: .init(
                    zmxExecutablePath: "/usr/bin/true", zmxDirectoryPath: "/tmp/no-session", loginShellPath: "/bin/sh"),
                repositoryMainFolder: nil,
                scrollbackStore: ScrollbackStore(directoryURL: URL(filePath: "/tmp/no-scrollback")))
            let paneID = PaneId(existingUUID: pane.id)
            let result = await coordinator.mountPreparedTerminalContent(
                admission: .init(
                    generation: .init(),
                    descriptor: .init(
                        pane: pane, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: tab.id)),
                    attempt: 1, restoreKind: .incompatible(0, fallback: plan)),
                initialFrame: nil, authority: .released(paneID))
            #expect(
                result
                    == .failed(
                        failure: .surfaceCreationFailed(code: "incompatible_session_version"), retry: .doNotRetry))
            #expect(registry.terminalView(for: pane.id)?.surfaceId == nil)
            #expect(registry.terminalStatusPlaceholderView(for: pane.id)?.mode == .incompatibleSessionVersion)
            #expect(coordinator.incompatibleTerminalRestartTasksByPaneID.isEmpty)

            try await coordinator.execute(.closeTab(tabId: tab.id))
            #expect(coordinator.incompatibleTerminalRestartTasksByPaneID.isEmpty)
            #expect(try fixture.coreRepository.pendingTerminalSessionIDs().isEmpty)
            #expect(try await coordinator.undoCloseTab())
            #expect(coordinator.incompatibleTerminalRestartTasksByPaneID.isEmpty)
            #expect(registry.terminalStatusPlaceholderView(for: pane.id)?.mode == .incompatibleSessionVersion)
            #expect(registry.terminalView(for: pane.id)?.surfaceId == nil)
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()
    }
}
