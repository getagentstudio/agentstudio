import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Workspace terminal session cleanup", .serialized)
struct WorkspaceTerminalSessionCleanupTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("completed history drains in bounded passes across workspaces")
    func completedHistoryPrunesInBoundedPasses() async throws {
        let fixture = try await SessionCleanupFixture()
        let otherWorkspaceID = UUIDv7.generate()
        let backend = CleanupRecordingBackend()
        do {
            try await fixture.repository.databaseWriter.write { database in
                for _ in 0..<250 {
                    try database.execute(
                        sql: """
                            INSERT INTO workspace_terminal_session_ownership(
                                session_id, cleanup_state, cleanup_requested_at, cleanup_completed_at)
                            VALUES (?, 'completed', 10, 20)
                            """, arguments: [ZmxSessionID.generateUUIDv7().rawValue])
                }
                for sequence in 1...201 {
                    try database.execute(
                        sql: """
                            INSERT INTO workspace_undo_close(
                                close_id, workspace_id, close_sequence, close_kind, closed_at, expires_at,
                                state, snapshot_version, snapshot_payload, deadline_boot_id, deadline_uptime_ns)
                            VALUES (?, ?, ?, 'pane', 100, 400, 'expired', 1, NULL, 'history-test', 400000000000)
                            """, arguments: [UUIDv7.generate().uuidString, otherWorkspaceID.uuidString, sequence])
                }
            }
            let needsAnotherPass = try await fixture.coordinator.performTerminalSessionCleanupPass(
                using: backend, canRetire: { _ in true })
            #expect(needsAnotherPass)
            try await fixture.repository.databaseWriter.read { database in
                let sessionCount = try Int.fetchOne(
                    database,
                    sql: "SELECT count(*) FROM workspace_terminal_session_ownership WHERE cleanup_state = 'completed'")
                let closeCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM workspace_undo_close")
                #expect(sessionCount == 150)
                #expect(closeCount == 101)
            }
            for _ in 0..<3 {
                _ = try await fixture.coordinator.performTerminalSessionCleanupPass(
                    using: backend, canRetire: { _ in true })
            }
            try await fixture.repository.databaseWriter.read { database in
                let sessionCount = try Int.fetchOne(
                    database,
                    sql: "SELECT count(*) FROM workspace_terminal_session_ownership WHERE cleanup_state = 'completed'")
                let closeCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM workspace_undo_close")
                #expect(sessionCount == 0)
                #expect(closeCount == 100)
            }
            #expect(fixture.coordinator.store.paneAtom.pane(fixture.pane.id) != nil)
            #expect(await backend.observed.isEmpty)
            #expect(await backend.retired.isEmpty)
        } catch {
            await fixture.coordinator.shutdown()
            throw error
        }
        await fixture.coordinator.shutdown()
    }

    @Test("startup cleanup waits five minutes despite wakeups", arguments: [false, true])
    func startupCleanupWaitsFiveMinutes(stopBeforeDeadline: Bool) async throws {
        let fixture = try await SessionCleanupFixture()
        let backend = CleanupRecordingBackend()
        let clock = TestPushClock()
        let startedAt = clock.now
        do {
            try await fixture.coordinator.execute(.purgeOrphanedPane(paneId: fixture.pane.id))
            fixture.coordinator.startTerminalSessionCleanup(
                using: backend, canRetire: { _ in true }, delay: .clock(clock))
            await assertEventuallyAsync("startup delay registered") { clock.pendingSleepCount == 1 }
            try #require(clock.pendingSleepCount == 1)
            #expect(clock.pendingSleepDeadlines == [startedAt.advanced(by: .seconds(300))])

            clock.advance(by: .seconds(299))
            fixture.coordinator.signalTerminalSessionCleanup()
            #expect(await backend.observed.isEmpty)
            #expect(await backend.retired.isEmpty)
            #expect(try fixture.repository.pendingTerminalSessionIDs() == [fixture.sessionID])

            if stopBeforeDeadline {
                await fixture.coordinator.shutdown()
                #expect(clock.pendingSleepCount == 0)
            }
            clock.advance(by: .seconds(1))
            if stopBeforeDeadline {
                #expect(await backend.observed.isEmpty)
                #expect(await backend.retired.isEmpty)
            } else {
                await assertEventuallyAsync("startup deadline admits pending cleanup") {
                    (try? fixture.repository.pendingTerminalSessionIDs().isEmpty) == true
                }
                #expect(await backend.retired == [fixture.sessionID])
            }
        } catch {
            await fixture.coordinator.shutdown()
            throw error
        }
        await fixture.coordinator.shutdown()
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("discard before first observation cleans the durably correlated session")
    func discardBeforeFirstObservationCleansKnownSession() async throws {
        let fixture = try await SessionCleanupFixture()
        let backend = CleanupRecordingBackend()
        do {
            try await fixture.coordinator.execute(.purgeOrphanedPane(paneId: fixture.pane.id))
            _ = try await fixture.coordinator.performTerminalSessionCleanupPass(
                using: backend, canRetire: { _ in true })
            _ = try await fixture.coordinator.performTerminalSessionCleanupPass(
                using: backend, canRetire: { _ in true })
            #expect(fixture.coordinator.store.paneAtom.pane(fixture.pane.id) == nil)
            #expect(await backend.observed == [fixture.sessionID])
            #expect(await backend.retired == [fixture.sessionID])
            #expect(try fixture.repository.pendingTerminalSessionIDs().isEmpty)
            #expect(try await fixture.cleanupFailure() == nil)
        } catch {
            await fixture.coordinator.shutdown()
            throw error
        }
        await fixture.coordinator.shutdown()
    }

    @Test("shutdown joins admitted observation and rejects consumer restart")
    func shutdownJoinsAdmittedObservation() async throws {
        let fixture = try await SessionCleanupFixture()
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let backend = CleanupRecordingBackend(observationGate: gate.stream)
        try await fixture.coordinator.execute(.purgeOrphanedPane(paneId: fixture.pane.id))
        fixture.coordinator.startTerminalSessionCleanup(
            using: backend, canRetire: { _ in true }, delay: AsyncDelay { _ in })
        var shutdownTask: Task<Void, Never>?
        var shutdownCompleted = false
        do {
            await assertEventuallyAsync("observation entered before shutdown") {
                await backend.observed == [fixture.sessionID]
            }
            try #require(await backend.observed == [fixture.sessionID])
            shutdownTask = Task {
                await fixture.coordinator.shutdown()
                shutdownCompleted = true
            }
            await assertEventuallyAsync("shutdown stopped admission") {
                await fixture.coordinator.terminalSessionCleanupStopped
            }
            try #require(fixture.coordinator.terminalSessionCleanupStopped)
            #expect(!shutdownCompleted)
            gate.continuation.finish()
            await shutdownTask?.value
            #expect(shutdownCompleted)
            #expect(try !fixture.repository.terminalSessionNeedsIdentity(fixture.sessionID))
            fixture.coordinator.startTerminalSessionCleanup(
                using: backend, canRetire: { _ in true }, delay: AsyncDelay { _ in })
            #expect(fixture.coordinator.terminalSessionCleanupTask == nil)
            #expect(await backend.retired.isEmpty)
        } catch {
            gate.continuation.finish()
            await shutdownTask?.value
            await fixture.coordinator.shutdown()
            throw error
        }
    }

    @Test("transient cleanup failure persists and retries through the injected delay")
    func transientFailureRetries() async throws {
        let fixture = try await SessionCleanupFixture()
        let backend = CleanupRecordingBackend(retirementFailures: 1)
        let retryGate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        do {
            try #require(
                try fixture.repository.recordTerminalSessionIdentity(
                    sessionID: fixture.sessionID, identity: Data("trusted-test-observation".utf8)))
            try await fixture.coordinator.execute(.purgeOrphanedPane(paneId: fixture.pane.id))
            fixture.coordinator.startTerminalSessionCleanup(
                using: backend, canRetire: { _ in true },
                delay: AsyncDelay { duration in
                    if duration == AppPolicies.WorkspacePersistence.sessionCleanupStartupDelay { return }
                    #expect(duration == AppPolicies.WorkspacePersistence.sessionCleanupRetryDelay)
                    await backend.recordRetryWait()
                    for await _ in retryGate.stream { break }
                    try Task.checkCancellation()
                })
            await assertEventuallyAsync("retry delay requested") { await backend.retryRequested }
            try #require(await backend.retryRequested)
            #expect(try await fixture.cleanupFailure() == ZmxSessionControlFailure.unavailable.rawValue)
            #expect(try fixture.repository.pendingTerminalSessionIDs() == [fixture.sessionID])
            retryGate.continuation.yield(())
            await assertEventuallyAsync("retry completes pending cleanup") {
                (try? fixture.repository.pendingTerminalSessionIDs().isEmpty) == true
            }
            #expect(await backend.retired == [fixture.sessionID, fixture.sessionID])
            #expect(try await fixture.cleanupFailure() == nil)
        } catch {
            retryGate.continuation.finish()
            await fixture.coordinator.shutdown()
            throw error
        }
        retryGate.continuation.finish()
        await fixture.coordinator.shutdown()
    }

    @Test("consumer handles new and preexisting pending work", arguments: [false, true])
    func consumerDrainsPendingWork(startAfterDiscard: Bool) async throws {
        let workspaceID = UUIDv7.generate()
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: datastore, startsObserving: false)
        let pane = store.createPane(residency: .backgrounded)
        let sessionID = try #require(pane.terminalState?.zmxSessionID)
        try #require(await store.flushAsync() == .persisted)
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: HarnessSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(), runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom())
        let backend = CleanupRecordingBackend()
        do {
            if startAfterDiscard {
                try await coordinator.execute(.purgeOrphanedPane(paneId: pane.id))
            }
            coordinator.startTerminalSessionCleanup(
                using: backend, canRetire: { _ in true }, delay: AsyncDelay { _ in })
            if !startAfterDiscard {
                try await coordinator.execute(.purgeOrphanedPane(paneId: pane.id))
            }
            await assertEventuallyAsync("consumer completed pending cleanup") {
                (try? await store.terminalSessionCleanupBatch(after: nil))?.isEmpty == true
            }
            #expect(await backend.retired == [sessionID])
            #expect(try fixture.coreRepository.pendingTerminalSessionIDs().isEmpty)
            #expect(await backend.observed == [sessionID])
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()
    }

    @Test("cleanup follows durable expiry and native retirement", arguments: [false, true])
    func cleanupFollowsDurableAndNativeRetirement(sessionAbsent: Bool) async throws {
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
            utc: Date(timeIntervalSince1970: 100), bootID: "cleanup-test", uptimeNanoseconds: 100_000_000_000)
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: manager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: manager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom(),
            undoClock: { time })
        let backend = CleanupRecordingBackend(sessionAbsent: sessionAbsent)
        do {
            _ = try await coordinator.performTerminalSessionCleanupPass(using: backend, canRetire: { _ in false })
            #expect(await backend.observed.isEmpty)
            try await coordinator.execute(.closeTab(tabId: tab.id))
            _ = try await coordinator.performTerminalSessionCleanupPass(using: backend, canRetire: { _ in false })
            #expect(await backend.observed.isEmpty)
            #expect(await backend.retired.isEmpty)
            let retired = try await store.expireUndoCloses(
                time: .init(
                    utc: Date(timeIntervalSince1970: 500), bootID: time.bootID, uptimeNanoseconds: 500_000_000_000))
            _ = try await coordinator.performTerminalSessionCleanupPass(
                using: backend, canRetire: { _ in manager.releasedUndoPaneIDs.contains(pane.id) })
            _ = try await coordinator.performTerminalSessionCleanupPass(
                using: backend, canRetire: { _ in manager.releasedUndoPaneIDs.contains(pane.id) })
            #expect(await backend.observed.isEmpty)
            #expect(await backend.retired.isEmpty)
            #expect(try fixture.coreRepository.pendingTerminalSessionIDs() == [sessionID])

            coordinator.consumeUndoRetirements(retired)
            _ = try await coordinator.performTerminalSessionCleanupPass(
                using: backend, canRetire: { _ in manager.releasedUndoPaneIDs.contains(pane.id) })
            _ = try await coordinator.performTerminalSessionCleanupPass(
                using: backend, canRetire: { _ in manager.releasedUndoPaneIDs.contains(pane.id) })
            #expect(await backend.retired == (sessionAbsent ? [] : [sessionID]))
            #expect(try fixture.coreRepository.pendingTerminalSessionIDs().isEmpty)
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()
    }
}

private actor CleanupRecordingBackend: ZmxSessionControlling {
    private(set) var observed: [ZmxSessionID] = []
    private(set) var retired: [ZmxSessionID] = []
    private let identity = Data("trusted-test-observation".utf8)
    private let observationGate: AsyncStream<Void>?
    private var retirementFailures: Int
    private let sessionAbsent: Bool
    private(set) var retryRequested = false

    func recordRetryWait() { retryRequested = true }

    init(observationGate: AsyncStream<Void>? = nil, retirementFailures: Int = 0, sessionAbsent: Bool = false) {
        self.observationGate = observationGate
        self.retirementFailures = retirementFailures
        self.sessionAbsent = sessionAbsent
    }

    func observeSessionIdentity(_ sessionID: ZmxSessionID) async throws -> Data? {
        observed.append(sessionID)
        if let observationGate {
            for await _ in observationGate { break }
        }
        return sessionAbsent ? nil : identity
    }

    func retireVerifiedSession(_ sessionID: ZmxSessionID, expectedIdentity: Data) async throws
        -> ZmxSessionCleanupStatus
    {
        #expect(expectedIdentity == identity)
        retired.append(sessionID)
        if retirementFailures > 0 {
            retirementFailures -= 1
            throw ZmxSessionControlFailure.unavailable
        }
        return .completed
    }
}

@MainActor
private struct SessionCleanupFixture {
    let repository: WorkspaceCoreRepository
    let pane: Pane
    let sessionID: ZmxSessionID
    let coordinator: WorkspaceSurfaceCoordinator

    init() async throws {
        let workspaceID = UUIDv7.generate()
        let sqliteFixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        repository = sqliteFixture.coreRepository
        let store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: try preparedWorkspaceSQLiteDatastore(from: sqliteFixture.backend), startsObserving: false)
        pane = store.createPane(residency: .backgrounded)
        sessionID = try #require(pane.terminalState?.zmxSessionID)
        try #require(await store.flushAsync() == .persisted)
        coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: HarnessSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(), runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(), ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom())
    }

    func cleanupFailure() async throws -> String? {
        let sessionID = sessionID
        return try await repository.databaseWriter.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT last_cleanup_error FROM workspace_terminal_session_ownership WHERE session_id = ?",
                arguments: [sessionID.rawValue])
        }
    }
}
