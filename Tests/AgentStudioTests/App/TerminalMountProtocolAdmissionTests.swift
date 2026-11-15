import AgentStudioInfrastructure
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Terminal mount protocol admission", .serialized)
struct TerminalMountProtocolAdmissionTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("ordinary repair and Undo never plain-attach an untracked session", arguments: [false, true])
    func unknownSessionDoesNotPlainAttach(viaUndo: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = fixture.store.createPane(launchDirectory: fixture.root)
        let tab = Tab(paneId: pane.id)
        fixture.store.appendTab(tab)
        try #require(await fixture.store.flushAsync() == .persisted)
        let sessionID = try #require(pane.terminalState?.zmxSessionID)
        try Data("present but not a current-protocol daemon".utf8).write(
            to: fixture.root.appending(path: sessionID.rawValue))
        do {
            if viaUndo {
                try await fixture.coordinator.execute(.closeTab(tabId: tab.id))
                #expect(try await fixture.coordinator.undoCloseTab())
            } else {
                _ = fixture.coordinator.createViewForRepair(for: pane)
            }
            #expect(fixture.manager.createdPaneIds.isEmpty)
            let task = try #require(fixture.coordinator.terminalProtocolClassificationTasksByPaneID[pane.id])
            await task.value
            #expect(fixture.coordinator.terminalProtocolClassificationTasksByPaneID.isEmpty)
            #expect(fixture.manager.createdPaneIds.isEmpty)
            #expect(
                fixture.coordinator.viewRegistry.terminalStatusPlaceholderView(for: pane.id)?.mode
                    == .incompatibleSessionVersion)
        } catch {
            await fixture.coordinator.shutdown()
            throw error
        }
        await fixture.coordinator.shutdown()
    }

    @Test("a newly persisted current-protocol terminal keeps synchronous plain attach")
    func currentSessionMountsWithoutAsyncAdmission() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let pane = try await fixture.store.createTerminalPane(
                metadata: PaneMetadata(launchDirectory: fixture.root, title: "Current"), placement: .newTab,
                nameForPane: { _ in "Current" }, willPublish: { _ in })
            _ = fixture.coordinator.createViewForRepair(for: pane)
            #expect(fixture.coordinator.terminalProtocolClassificationTasksByPaneID.isEmpty)
            let command = try #require(
                fixture.manager.createdConfigsByPaneId[pane.id]?.startupStrategy.startupCommandForSurface)
            #expect(command.contains(" attach "))
            #expect(!command.contains("/bin/sh -c"))
        } catch {
            await fixture.coordinator.shutdown()
            throw error
        }
        await fixture.coordinator.shutdown()
    }

    private struct Fixture {
        let store: WorkspaceStore
        let coordinator: WorkspaceSurfaceCoordinator
        let manager: TerminalRestoreCapturingSurfaceManager
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let workspaceID = UUIDv7.generate()
        let sqlite = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: sqlite.backend), startsObserving: false)
        // Keep AF_UNIX paths short and isolate every endpoint from all running apps.
        let root = URL(filePath: "/tmp/pm-\(UUIDv7.generate().uuidString.suffix(12))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = TerminalRestoreCapturingSurfaceManager()
        let window = WindowLifecycleAtom()
        window.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 800, height: 600))
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store), surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(), windowLifecycleStore: window,
            ipcLifecycle: .testUnavailable, bridgePaneAttendance: BridgePaneAttendanceAtom())
        let configuration = SessionConfiguration(
            isEnabled: true, zmxPath: "/usr/bin/false", zmxDir: root.path,
            healthCheckInterval: 30, maxCheckpointAge: 60)
        coordinator.sessionConfig = configuration
        coordinator.terminalRestoreRuntime = TerminalRestoreRuntime(sessionConfiguration: configuration)
        coordinator.scrollbackStore = ScrollbackStore(directoryURL: root.appending(path: "saved"))
        return Fixture(store: store, coordinator: coordinator, manager: manager, root: root)
    }
}
