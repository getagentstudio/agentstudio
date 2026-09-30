import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Authorization admits an agent's request while its target is inside the
/// agent's own pane; these cases move the target out before the effect runs
/// and prove the effect owner refuses it.
@MainActor
@Suite("App IPC own-pane re-check at effect time", .serialized)
struct AgentStudioIPCOwnPaneEffectRecheckTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("an agent's close queued behind a detach of its drawer child is refused with nothing applied")
    func queuedDetachThenCloseIsRefused() async throws {
        // A SQLite-backed store whose core repository the test reads directly,
        // so "no durable mutation" is checked in the persisted graph.
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let parent = store.createPane(title: "Agent terminal")
        let tab = Tab(paneId: parent.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        store.setActivePane(parent.id, inTab: tab.id)
        let child = try #require(store.addDrawerPane(to: parent.id))
        let childSession = try #require(child.terminalState?.zmxSessionID)
        #expect(await store.flushAsync() == .persisted)
        #expect(
            try persistedPlacement(of: child.id, in: fixture, workspaceID: workspaceID)
                == .drawerChild(parentPaneId: parent.id))
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: HarnessSurfaceManager(), runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom())
        let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
        let undoDepthBefore = executor.undoStack.count
        let durableUndoClosesBefore = try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID).count

        // Causal barrier: hold the gesture queue so both later gestures are
        // queued before either runs, in submission order.
        let gate = HeldStep<Void>("queued gesture predecessor")
        defer { gate.release() }
        let barrier = executor.submitGesture { _ in
            try? await gate.arrive(())
            return true
        }
        _ = try await gate.firstArrival()
        let detach = executor.submitAction(.detachDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id))
        let agentClose = executor.submitScopedAction(
            .removeDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id),
            ownPaneAssertion: WorkspaceOwnPaneAssertion(boundPaneId: parent.id)
        )
        // Authorization ran while the child was still the agent's own; the
        // assertion is only evaluated when the gesture runs.
        #expect(store.paneAtom.pane(child.id)?.parentPaneId == parent.id)
        gate.release()

        #expect(await barrier.value)
        #expect(await detach.value)
        #expect(await agentClose.value == .outsideOwnPane)
        let detachedChild = try #require(store.paneAtom.pane(child.id))
        #expect(detachedChild.parentPaneId == nil)
        #expect(store.tabLayoutAtom.tab(tab.id)?.allPaneIds.contains(child.id) == true)
        #expect(executor.undoStack.count == undoDepthBefore)

        // Durable state: the predecessor's detach is persisted, and the refused
        // close wrote nothing: the pane row survives, no terminal session was
        // queued for cleanup, and no undo-close was journaled.
        #expect(await store.flushAsync() == .persisted)
        #expect(try persistedPlacement(of: child.id, in: fixture, workspaceID: workspaceID) == .layout)
        #expect(try !fixture.coreRepository.pendingTerminalSessionIDs().contains(childSession))
        #expect(try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID).count == durableUndoClosesBefore)
        await coordinator.shutdown()
    }

    private func persistedPlacement(
        of paneId: UUID,
        in fixture: WorkspaceSQLiteBridgeFixture,
        workspaceID: UUID
    ) throws -> WorkspaceCoreRepository.PanePlacementRecord? {
        try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.first { $0.id == paneId }?.placement
    }

    @Test("terminal input to a drawer child detached before handoff reaches no runtime")
    func runtimeInputAfterDetachIsRefused() async throws {
        let scenario = try OwnPaneEffectScenario()
        defer { try? FileManager.default.removeItem(at: scenario.harness.tempDir) }
        let adapter = AgentStudioIPCRuntimeAdapter(
            workspaceStore: scenario.harness.store,
            runtimeRegistry: scenario.harness.runtimeRegistry,
            commandDispatcher: scenario.harness.coordinator
        )
        let agent = AppIPCOwnPaneAssertion(boundPaneId: scenario.parentPaneId)
        let childHandle = IPCHandle(kind: .pane, reference: .canonicalUUID(scenario.childPaneId))

        _ = try await adapter.sendTerminalInput(
            to: childHandle, input: "before\n", correlationId: nil, ownPaneAssertion: agent)
        #expect(
            await scenario.harness.executor.execute(
                .detachDrawerPane(parentPaneId: scenario.parentPaneId, drawerPaneId: scenario.childPaneId)))
        await #expect(throws: AuthorizationError.notYetAllowed("terminal.send")) {
            _ = try await adapter.sendTerminalInput(
                to: childHandle, input: "after\n", correlationId: nil, ownPaneAssertion: agent)
        }

        #expect(terminalCommandNames(scenario.childRuntime.receivedCommands) == ["sendInput(before\n)"])
    }

    @Test("a headless scroll for a drawer child detached before handoff reaches no runtime")
    func headlessScrollAfterDetachIsRefused() async throws {
        let scenario = try OwnPaneEffectScenario()
        defer { try? FileManager.default.removeItem(at: scenario.harness.tempDir) }
        #expect(
            await scenario.harness.executor.execute(
                .detachDrawerPane(parentPaneId: scenario.parentPaneId, drawerPaneId: scenario.childPaneId)))

        let outcome = await scenario.harness.controller.executeHeadlessIPC(
            AppCommandExecutionRequest(
                command: .scrollToBottom,
                arguments: .typedIPC(
                    .pane(
                        .init(
                            workspaceWindowId: UUIDv7.generate(),
                            paneSelector: try IPCPaneSelector(rawValue: scenario.childPaneId.uuidString)
                        ))),
                executionContext: .headlessIPC(admitsDebugTestingCommands: false),
                ownPaneAssertion: WorkspaceOwnPaneAssertion(boundPaneId: scenario.parentPaneId)
            ))

        #expect(outcome == .outsideOwnPane)
        #expect(scenario.childRuntime.receivedCommands.isEmpty)
    }
}

/// One main terminal with one drawer terminal in the active tab, each with a
/// recording runtime.
@MainActor
private struct OwnPaneEffectScenario {
    let harness: PaneTabViewControllerCommandHarness
    let tabId: UUID
    let parentPaneId: UUID
    let childPaneId: UUID
    let childRuntime: RecordingCommandPaneRuntime

    init() throws {
        harness = makeHarness()
        let parent = harness.store.createPane(title: "Agent terminal")
        let tab = Tab(paneId: parent.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(parent.id, inTab: tab.id)
        let child = try #require(harness.store.addDrawerPane(to: parent.id))
        childRuntime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: child.id))
        harness.runtimeRegistry.register(childRuntime)
        tabId = tab.id
        parentPaneId = parent.id
        childPaneId = child.id
    }
}
