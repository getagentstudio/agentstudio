import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Workspace command durable undo", .serialized)
struct WorkspaceSurfaceCoordinatorDurableUndoTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("discarding one pane preserves another pane's undo and shared session")
    func discardPreservesUndoSessionOwner() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let sessionID = ZmxSessionID.generateUUIDv7()
        let undoPane = store.createPane(zmxSessionID: sessionID)
        let discardedPane = store.createPane(zmxSessionID: sessionID, residency: .backgrounded)
        let tab = Tab(paneId: undoPane.id)
        store.appendTab(tab)
        #expect(await store.flushAsync() == .persisted)
        let manager = HarnessSurfaceManager()
        var finalRevokedPaneIDs: [Set<UUID>] = []
        let ipcLifecycle = WorkspaceSurfaceIPCLifecycle(
            environment: { _, _ in [:] },
            invalidatePaneIDs: { _ in },
            finalRevokePaneIDs: { paneIDs in
                #expect(manager.retiredActivePaneIDs.isEmpty)
                finalRevokedPaneIDs.append(paneIDs)
            }
        )
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: ipcLifecycle,
            bridgePaneAttendance: BridgePaneAttendanceAtom())

        try await coordinator.execute(.closeTab(tabId: tab.id))
        try await coordinator.execute(.purgeOrphanedPane(paneId: discardedPane.id))

        #expect(manager.retainedUndoPaneIDs == [undoPane.id])
        #expect(manager.releasedUndoPaneIDs.isEmpty)
        #expect(manager.retiredActivePaneIDs == [discardedPane.id])
        #expect(finalRevokedPaneIDs == [[discardedPane.id]])
        #expect(try fixture.coreRepository.pendingTerminalSessionIDs().isEmpty)
        #expect(try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID).count == 1)
        await coordinator.shutdown()
    }

    @Test("permanent drawer discard commits before teardown", arguments: [false, true])
    func drawerDiscardRequiresDurability(rejectWrite: Bool) async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let parent = store.createPane()
        store.appendTab(Tab(paneId: parent.id))
        let child = try #require(store.addDrawerPane(to: parent.id))
        #expect(await store.flushAsync() == .persisted)
        let manager = HarnessSurfaceManager()
        var finalRevokedPaneIDs: [Set<UUID>] = []
        let ipcLifecycle = WorkspaceSurfaceIPCLifecycle(
            environment: { _, _ in [:] },
            invalidatePaneIDs: { _ in },
            finalRevokePaneIDs: { paneIDs in
                #expect(manager.retiredActivePaneIDs.isEmpty)
                finalRevokedPaneIDs.append(paneIDs)
            }
        )
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: ipcLifecycle,
            bridgePaneAttendance: BridgePaneAttendanceAtom())
        let (activityClock, activityAtom) = await makeActivityClock()
        coordinator.paneActivityClock = activityClock
        activityClock.submit(activityOccurrence(for: child.id))
        #expect(try await activityClock.settled() == .quiescent)
        #expect(activityAtom.value(for: child.id) != nil)
        if rejectWrite {
            try await fixture.coreRepository.databaseWriter.write { database in
                try database.execute(
                    sql: """
                        CREATE TRIGGER reject_drawer_discard BEFORE DELETE ON pane
                        BEGIN SELECT RAISE(ABORT, 'injected drawer discard failure'); END
                        """)
            }
            await #expect(throws: (any Error).self) {
                try await coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id))
            }
            #expect(store.paneAtom.pane(child.id) != nil)
            #expect(store.paneAtom.pane(parent.id)?.drawer?.paneIds == [child.id])
            #expect(manager.retiredActivePaneIDs.isEmpty)
            #expect(finalRevokedPaneIDs.isEmpty)
            #expect(activityAtom.value(for: child.id) != nil)
        } else {
            try await coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id))
            #expect(store.paneAtom.pane(child.id) == nil)
            #expect(store.paneAtom.pane(parent.id)?.drawer?.paneIds.isEmpty == true)
            #expect(try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.count == 1)
            #expect(
                try fixture.coreRepository.pendingTerminalSessionIDs() == [
                    try #require(child.terminalState?.zmxSessionID)
                ])
            #expect(manager.retiredActivePaneIDs == [child.id])
            #expect(finalRevokedPaneIDs == [[child.id]])
            #expect(try await activityClock.settled() == .quiescent)
            #expect(activityAtom.value(for: child.id) == nil)
        }
        await coordinator.shutdown()
        await activityClock.shutdown()
    }

    @Test("discard preserves another pane owning the same session")
    func discardPreservesSharedSession() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let sessionID = ZmxSessionID.generateUUIDv7()
        let discarded = store.createPane(zmxSessionID: sessionID, residency: .backgrounded)
        let retained = store.createPane(zmxSessionID: sessionID, residency: .backgrounded)
        #expect(await store.flushAsync() == .persisted)

        try await store.discardPane(
            target: .backgroundedPane(paneID: discarded.id), time: try await WorkspaceUndoJournalClock.current(),
            willPublish: { _ in }, didPublish: { _ in })

        #expect(store.paneAtom.pane(retained.id) != nil)
        #expect(try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.map(\.id) == [retained.id])
        #expect(try fixture.coreRepository.pendingTerminalSessionIDs().isEmpty)
    }

    @Test("background discard maintains drawer ownership", arguments: [false, true])
    func discardDrawerOwnership(childOnly: Bool) async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let parent = store.createPane(residency: .backgrounded)
        let child = try #require(
            store.paneAtom.addDrawerPane(
                to: parent.id, parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser,
                zmxSessionID: .generateUUIDv7()))
        store.setResidency(.backgrounded, for: child.id)
        #expect(await store.flushAsync() == .persisted)

        try await store.discardPane(
            target: .backgroundedPane(paneID: childOnly ? child.id : parent.id),
            time: try await WorkspaceUndoJournalClock.current(),
            willPublish: { _ in }, didPublish: { _ in })

        #expect(store.paneAtom.pane(child.id) == nil)
        #expect(try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.count == (childOnly ? 1 : 0))
        if childOnly { #expect(store.paneAtom.pane(parent.id)?.drawer?.paneIds.isEmpty == true) }
        let pending = try fixture.coreRepository.pendingTerminalSessionIDs()
        #expect(pending.contains(try #require(child.terminalState?.zmxSessionID)))
        #expect(pending.contains(try #require(parent.terminalState?.zmxSessionID)) == !childOnly)
    }

    @Test("permanent discard commits before removing a backgrounded pane", arguments: [false, true])
    func backgroundDiscardRequiresDurability(rejectWrite: Bool) async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let pane = store.createPane()
        store.setResidency(.backgrounded, for: pane.id)
        #expect(await store.flushAsync() == .persisted)
        let manager = HarnessSurfaceManager()
        var finalRevokedPaneIDs: [Set<UUID>] = []
        let ipcLifecycle = WorkspaceSurfaceIPCLifecycle(
            environment: { _, _ in [:] },
            invalidatePaneIDs: { _ in },
            finalRevokePaneIDs: { paneIDs in
                #expect(manager.retiredActivePaneIDs.isEmpty)
                finalRevokedPaneIDs.append(paneIDs)
            }
        )
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: ipcLifecycle,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let (activityClock, activityAtom) = await makeActivityClock()
        coordinator.paneActivityClock = activityClock
        activityClock.submit(activityOccurrence(for: pane.id))
        #expect(try await activityClock.settled() == .quiescent)
        #expect(activityAtom.value(for: pane.id) != nil)
        if rejectWrite {
            try await fixture.coreRepository.databaseWriter.write { database in
                try database.execute(
                    sql: """
                        CREATE TRIGGER reject_permanent_discard BEFORE DELETE ON pane
                        BEGIN SELECT RAISE(ABORT, 'injected discard failure'); END
                        """)
            }
            await #expect(throws: (any Error).self) {
                try await coordinator.execute(.purgeOrphanedPane(paneId: pane.id))
            }
            #expect(store.paneAtom.pane(pane.id) != nil)
            #expect(try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.count == 1)
            #expect(finalRevokedPaneIDs.isEmpty)
            #expect(activityAtom.value(for: pane.id) != nil)
        } else {
            try await coordinator.execute(.purgeOrphanedPane(paneId: pane.id))
            #expect(store.paneAtom.pane(pane.id) == nil)
            #expect(try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.isEmpty)
            let sessionID = try #require(pane.terminalState?.zmxSessionID)
            #expect(try fixture.coreRepository.pendingTerminalSessionIDs().contains(sessionID))
            #expect(finalRevokedPaneIDs == [[pane.id]])
            #expect(manager.retiredActivePaneIDs == [pane.id])
            #expect(try await activityClock.settled() == .quiescent)
            #expect(activityAtom.value(for: pane.id) == nil)
        }
        await coordinator.shutdown()
        await activityClock.shutdown()
    }

    @Test("a rejected journal write leaves the app's pane and tab open")
    func failedClosePreservesLiveAppComposition() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        #expect(await store.flushAsync() == .persisted)
        let manager = HarnessSurfaceManager()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        try await fixture.coreRepository.databaseWriter.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_app_close BEFORE INSERT ON workspace_undo_close
                    BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END
                    """)
        }

        await #expect(throws: (any Error).self) {
            try await coordinator.execute(.closeTab(tabId: tab.id))
        }
        #expect(store.tabLayoutAtom.tab(tab.id) != nil)
        #expect(store.paneAtom.pane(pane.id)?.residency == .active)
        #expect(coordinator.undoStack.isEmpty)
        #expect(manager.retainedUndoPaneIDs.isEmpty)
        await coordinator.shutdown()
    }

    @Test("close invalidates before teardown, undo makes no credential call, and expiry final-revokes before release")
    func appCloseUndoAndExpiryOrderIPCLifecycle() async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        #expect(await store.flushAsync() == .persisted)
        let manager = HarnessSurfaceManager()
        var lifecycleEvents: [(kind: String, paneIDs: Set<UUID>)] = []
        var invalidationObservedBeforeFirstRetention = false
        let ipcLifecycle = WorkspaceSurfaceIPCLifecycle(
            environment: { _, _ in [:] },
            invalidatePaneIDs: { paneIDs in
                if lifecycleEvents.isEmpty {
                    invalidationObservedBeforeFirstRetention = manager.retainedUndoPaneIDs.isEmpty
                }
                lifecycleEvents.append(("invalidate", paneIDs))
            },
            finalRevokePaneIDs: { paneIDs in
                #expect(manager.releasedUndoPaneIDs.isEmpty)
                lifecycleEvents.append(("final", paneIDs))
            }
        )
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: ipcLifecycle,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let activityAtom = PaneActivityTimeAtom()
        let activityDelayClock = TestPushClock()
        let activityInstant = ContinuousClock.now
        let activityClock = PaneActivityClock(
            publishInterval: .seconds(30),
            clock: activityDelayClock,
            monotonicNow: { activityInstant },
            sink: { batch in activityAtom.apply(batch) }
        )
        coordinator.paneActivityClock = activityClock
        await activityClock.start()
        activityClock.submit(activityOccurrence(for: pane.id, at: activityInstant))
        #expect(try await activityClock.settled() == .quiescent)

        try await coordinator.execute(.closeTab(tabId: tab.id))
        #expect(lifecycleEvents.map(\.kind) == ["invalidate"])
        #expect(lifecycleEvents.first?.paneIDs == [pane.id])
        #expect(invalidationObservedBeforeFirstRetention)
        #expect(store.tabLayoutAtom.tab(tab.id) == nil)
        #expect(store.paneAtom.pane(pane.id) == nil)
        #expect(try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.isEmpty)
        let history = try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID)
        #expect(history.count == 1)
        #expect(history.first?.snapshot.panes.map(\.id) == [pane.id])
        #expect(manager.retainedUndoPaneIDs == [pane.id])

        try await coordinator.undoCloseTab()
        #expect(activityAtom.value(for: pane.id) != nil)
        #expect(store.paneAtom.pane(pane.id)?.terminalState?.zmxSessionID == pane.terminalState?.zmxSessionID)
        #expect(try fixture.coreRepository.fetchPaneGraph(workspaceId: workspaceID).panes.map(\.id) == [pane.id])
        #expect(try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID).isEmpty)

        try await coordinator.execute(.closeTab(tabId: tab.id))
        activityClock.submit(activityOccurrence(for: pane.id, at: activityInstant.advanced(by: .seconds(1))))
        await activityDelayClock.waitForPendingSleepCount(exactly: 1)
        #expect(lifecycleEvents.map(\.kind) == ["invalidate", "invalidate"])
        let secondClose = try #require(
            try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID).first)
        let retirements = try await store.expireUndoCloses(
            time: WorkspaceUndoJournalTime(
                utc: secondClose.expiresAt.addingTimeInterval(1),
                bootID: secondClose.deadlineBootID,
                uptimeNanoseconds: secondClose.deadlineUptimeNanoseconds + 1
            )
        )
        coordinator.consumeUndoRetirements(retirements)
        #expect(try await activityClock.settled() == .quiescent)
        #expect(activityAtom.value(for: pane.id) == nil)
        #expect(lifecycleEvents.map(\.kind) == ["invalidate", "invalidate", "final"])
        #expect(lifecycleEvents.last?.paneIDs == [pane.id])
        #expect(manager.releasedUndoPaneIDs == [pane.id])
        await coordinator.shutdown()
        await activityClock.shutdown()
    }

    private func makeActivityClock() async -> (PaneActivityClock, PaneActivityTimeAtom) {
        let activityAtom = PaneActivityTimeAtom()
        let activityClock = PaneActivityClock(publishInterval: .zero) { batch in activityAtom.apply(batch) }
        await activityClock.start()
        return (activityClock, activityAtom)
    }

    private func activityOccurrence(
        for paneId: UUID,
        at orderingInstant: ContinuousClock.Instant = ContinuousClock.now
    ) -> PaneActivityOccurrence {
        PaneActivityOccurrence(
            paneId: paneId,
            source: .hook,
            orderingInstant: orderingInstant,
            wallTime: Date(timeIntervalSince1970: 1000)
        )
    }
}
