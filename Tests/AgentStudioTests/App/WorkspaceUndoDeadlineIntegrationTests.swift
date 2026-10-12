import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Workspace durable undo deadline", .serialized)
struct WorkspaceUndoDeadlineIntegrationTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("one deadline task preserves failed expiry and drains on shutdown", arguments: [false, true])
    func journalDeadlineOwnsRetention(failFirstExpiry: Bool) async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let clock = TestPushClock()
        let origin = clock.now
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        let manager = HarnessSurfaceManager()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom(),
            undoClock: {
                let elapsed = Int64(origin.duration(to: clock.now).nanosecondsForTaskSleep)
                return .init(
                    utc: Date(timeIntervalSince1970: 100 + Double(elapsed) / 1_000_000_000),
                    bootID: "test-boot", uptimeNanoseconds: 100_000_000_000 + elapsed)
            },
            undoDelay: .clock(clock)
        )

        try await coordinator.execute(.closeTab(tabId: tab.id))
        await eventually("the journal should arm one deadline") { clock.pendingSleepCount == 1 }
        let initialSleepGeneration = clock.scheduledSleepGeneration
        if failFirstExpiry {
            try await fixture.coreRepository.databaseWriter.write { database in
                try database.execute(
                    sql: """
                        CREATE TRIGGER reject_expiry BEFORE UPDATE OF state ON workspace_undo_close
                        WHEN NEW.state = 'expired'
                        BEGIN SELECT RAISE(ABORT, 'injected expiry failure'); END
                        """)
            }
        }
        clock.advance(by: .seconds(299))
        #expect(coordinator.undoStack.count == 1)
        #expect(manager.releasedUndoPaneIDs.isEmpty)
        clock.advance(by: .seconds(1))
        if failFirstExpiry {
            await eventually("a failed expiry should schedule a bounded retry") {
                clock.pendingSleepCount == 1 && clock.scheduledSleepGeneration > initialSleepGeneration
            }
            #expect(coordinator.undoStack.count == 1)
            #expect(manager.releasedUndoPaneIDs.isEmpty)
            let retained = try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID)
            #expect(retained.first?.deadlineUptimeNanoseconds == 400_000_000_000)
            try await fixture.coreRepository.databaseWriter.write { database in
                try database.execute(sql: "DROP TRIGGER reject_expiry")
            }
            clock.advance(by: AppPolicies.WorkspacePersistence.undoDeadlineRetryDelay)
        }
        await eventually("the committed expiry should remove undo ownership") { coordinator.undoStack.isEmpty }
        #expect(manager.releasedUndoPaneIDs == [pane.id])
        #expect(try await datastore.fetchAvailableUndoCloses(workspaceID: workspaceID).isEmpty)
        await coordinator.shutdown()
        #expect(clock.pendingSleepCount == 0)
    }
}
