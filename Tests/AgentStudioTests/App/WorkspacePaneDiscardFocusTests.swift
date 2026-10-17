import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Pane discard focus ordering", .serialized)
struct WorkspacePaneDiscardFocusTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("another pane's focus survives drawer discard", arguments: [false, true])
    func newerFocusSurvivesDiscardCommit(changeDuringWrite: Bool) async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let focusProbe = DrawerDiscardFocusProbe()
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend) { event in
            await focusProbe.observe(event)
        }
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let parent = store.createPane()
        let other = store.createPane()
        let tab = Tab(paneId: parent.id)
        store.appendTab(tab)
        store.insertPane(
            other.id, inTab: tab.id, at: parent.id, direction: .horizontal, position: .after, sizingMode: .halveTarget)
        let child = try #require(store.addDrawerPane(to: parent.id))
        #expect(await store.flushAsync() == .persisted)
        let registry = ViewRegistry()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: registry, runtime: SessionRuntime(store: store),
            surfaceManager: HarnessSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(), runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        var hosts: [UUID: PaneHostView] = [:]
        for paneID in [parent.id, child.id, other.id] {
            let host = PaneHostView(paneId: paneID)
            let view = HardeningFocusableMountedContentView()
            host.mountContentView(view)
            registry.register(host, for: paneID)
            content.addSubview(host)
            hosts[paneID] = host
        }
        let initialID = changeDuringWrite ? child.id : other.id
        window.makeFirstResponder(hosts[initialID])
        #expect(window.firstResponder === hosts[initialID])
        if changeDuringWrite {
            focusProbe.onSave = { window.makeFirstResponder(hosts[other.id]) }
        }

        try await coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id))

        #expect(store.paneAtom.pane(child.id) == nil)
        #expect(window.firstResponder === hosts[other.id])
        await coordinator.shutdown()
        window.close()
    }
}

@MainActor
private final class DrawerDiscardFocusProbe {
    var onSave: (() -> Void)?

    func observe(_ event: WorkspaceSQLiteDatastoreActor.ProbeEvent) {
        guard case .saveWorkspaceSnapshot = event else { return }
        let action = onSave
        onSave = nil
        action?()
    }
}
