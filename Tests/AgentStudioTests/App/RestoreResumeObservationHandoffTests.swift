import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Restore resume observation handoff", .serialized)
struct RestoreResumeObservationHandoffTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("live zmx membership follows persisted additions and removals, excluding other ownership")
    func persistedLiveMembershipIsCurrentAndScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "live-zmx-membership-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await prepareForegroundFiles(root: root)
        let workspaceId = UUIDv7.generate()
        let otherWorkspace = UUIDv7.generate()
        let paneId = UUIDv7.generate()
        let sessionId = ZmxSessionID.generateUUIDv7()
        let undoPaneId = UUIDv7.generate()
        let undoSessionId = ZmxSessionID.generateUUIDv7()
        try await prepared.coreQueue.write { database in
            for workspace in [workspaceId, otherWorkspace] {
                try database.execute(
                    sql: "INSERT INTO workspace VALUES (?, 'Membership proof', 1, 1)",
                    arguments: [workspace.uuidString])
            }
            try insertLiveMembershipPane(database, workspaceId: workspaceId, paneId: paneId, sessionId: sessionId)
            try insertLiveMembershipPane(
                database, workspaceId: otherWorkspace, paneId: UUIDv7.generate(),
                sessionId: .generateUUIDv7())
            try insertLiveMembershipPane(
                database, workspaceId: workspaceId, paneId: UUIDv7.generate(),
                sessionId: .generateUUIDv7(), provider: "ghostty")
            let closeId = UUIDv7.generate()
            try database.execute(
                sql: "INSERT INTO workspace_terminal_session_ownership(session_id) VALUES (?)",
                arguments: [undoSessionId.rawValue])
            try database.execute(
                sql: """
                    INSERT INTO workspace_undo_close(close_id, workspace_id, close_sequence, close_kind,
                        closed_at, expires_at, state, snapshot_version, snapshot_payload, deadline_boot_id, deadline_uptime_ns)
                    VALUES (?, ?, 1, 'pane', 100, 400, 'available', 1, ?, 'proof-boot', 400000000000)
                    """, arguments: [closeId.uuidString, workspaceId.uuidString, Data("{}".utf8)])
            try database.execute(
                sql: "INSERT INTO workspace_undo_close_member VALUES (?, ?, ?)",
                arguments: [closeId.uuidString, undoPaneId.uuidString, undoSessionId.rawValue])
        }
        #expect(try await prepared.datastore.liveZmxSessionsByPane(workspaceId: workspaceId) == [paneId: sessionId])
        let addedPaneId = UUIDv7.generate()
        let addedSessionId = ZmxSessionID.generateUUIDv7()
        try await prepared.coreQueue.write {
            try insertLiveMembershipPane($0, workspaceId: workspaceId, paneId: addedPaneId, sessionId: addedSessionId)
        }
        #expect(
            try await prepared.datastore.liveZmxSessionsByPane(workspaceId: workspaceId)
                == [paneId: sessionId, addedPaneId: addedSessionId])
        try await prepared.coreQueue.write {
            try $0.execute(sql: "DELETE FROM pane WHERE id = ?", arguments: [paneId.uuidString])
        }
        #expect(
            try await prepared.datastore.liveZmxSessionsByPane(workspaceId: workspaceId)
                == [addedPaneId: addedSessionId])
    }

    @Test("foreground transactions use the real App adapter over prepared Core files")
    func preparedDatastoreOwnsObservationTransactions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "foreground-access-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: root) }
        let datastore = try await prepareForegroundDatastore(root: root)
        let paneId = UUIDv7.generate()
        let sessionId = ZmxSessionID.generateUUIDv7()
        let launchId = UUIDv7.generate()
        let membership = [paneId: sessionId]
        let repository = SQLitePaneForegroundEvidenceRepository(
            access: WorkspaceForegroundEvidenceSQLiteAccess(datastore: datastore),
            observerLaunchId: launchId, paneSessions: { membership })
        let observation = PaneForegroundLook(
            paneId: paneId, zmxSessionId: sessionId,
            sessionIdentity: try handoffIdentity(bootId: "adapter-proof", daemonPid: 8300),
            bindingGenerationId: nil, program: .codex, observerLaunchId: launchId,
            sequence: 1, observedAt: Date(timeIntervalSince1970: 1))
        #expect(try await repository.admit(observation) == .admitted)
        #expect(try await repository.load(paneId: paneId) == observation)
        let storedSequence = try await datastore.performApplicationLocalRead {
            try Int64.fetchOne(
                $0, sql: "SELECT sequence FROM terminal_pane_foreground_evidence WHERE pane_id = ?",
                arguments: [paneId.uuidString])
        }
        #expect(storedSequence == 1)
        try await repository.retire(paneId: paneId)
        #expect(try await repository.load(paneId: paneId) == nil)
        let retainedRows = try await datastore.performApplicationLocalRead {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM terminal_pane_foreground_evidence")
        }
        #expect(retainedRows == 0)
    }

    @Test(
        "A1 preserves the old incarnation while accepting a newer look at that same incarnation",
        arguments: [true, false])
    func preRestoreHandoffPreservesIncarnation(sameIncarnation: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "foreground-handoff-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: root) }
        let datastore = try await prepareForegroundDatastore(root: root)
        let paneId = UUIDv7.generate()
        let sessionId = ZmxSessionID.generateUUIDv7()
        let sessions = SessionsRepository(sqliteAccess: WorkspaceSessionsSQLiteAccess(datastore: datastore))
        let bound = try await sessions.applyHook(
            .init(
                paneId: paneId, providerIdentifier: "codex", providerVersion: "fixture",
                sessionId: UUIDv7.generate().uuidString, eventName: .sessionStart, turnId: nil,
                signal: .sessionStart, recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 1),
                chain: TestMainAgentChain.observation), eligibility: .eligible)
        guard case .committed(let commit) = bound else { throw HandoffDecisionFailure.notBound }
        let generation = commit.binding.bindingGenerationId
        let oldLaunch = UUIDv7.generate()
        let launch = UUIDv7.generate()
        let identity = try handoffIdentity(bootId: "old-boot", daemonPid: 8000)
        let oldLook = PaneForegroundLook(
            paneId: paneId, zmxSessionId: sessionId, sessionIdentity: identity,
            bindingGenerationId: generation, program: .codex, observerLaunchId: oldLaunch,
            sequence: 10, observedAt: Date(timeIntervalSince1970: 1))
        let access = WorkspaceForegroundEvidenceSQLiteAccess(datastore: datastore)
        let oldRepository = SQLitePaneForegroundEvidenceRepository(access: access, observerLaunchId: oldLaunch)
        #expect(try await oldRepository.admit(oldLook) == .admitted)
        let membership = [paneId: sessionId]
        let repository = SQLitePaneForegroundEvidenceRepository(
            access: access, observerLaunchId: launch, paneSessions: { membership })
        let source = LocalFactSource(
            vocabulary: FactVocabulary<ForegroundObserverFactScope, ForegroundObserverFact>(
                describeScope: { "\($0.paneId)/\($0.operationId)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in if case .closed = fact { true } else { false } }))
        let facts = try source.attach()
        let currentIdentity = sameIncarnation ? identity : try handoffIdentity(bootId: "new-boot", daemonPid: 8100)
        let observer = PaneForegroundObserver(
            clock: TestPushClock(),
            policy: .init(lookSettleDelay: .seconds(5), lookMaxDelay: .seconds(60), quitLookDeadline: .seconds(1)),
            repository: repository, probe: HandoffNewSessionProbe(sessionId: sessionId, identity: currentIdentity),
            exitWatcher: HandoffNoExitWatcher(), observerLaunchId: launch, factSink: source.sink)
        do {
            await observer.note(.bindingChanged, pane: paneId)
            let demand = try await facts.expectNextOperation(
                matching: { $0.paneId == paneId }, opening: { $0 == .scheduled }, "handoff demand")
            try await facts.expectNext(in: demand, .scheduled)
            try await facts.expectNext(in: demand, .closed(.scheduled))
            let look = try await facts.expectNextOperation(
                matching: { $0.paneId == paneId }, opening: { $0 == .snapshotStarted(sequence: 1) }, "handoff look")
            try await facts.expectNext(in: look, .snapshotStarted(sequence: 1))
            try await facts.expectNext(in: look, .observation(.admitted))
            try await facts.expectNext(in: look, .closed(.looked))
            let current = try #require(try await repository.load(paneId: paneId))
            #expect(current.program == .shell)
            #expect(current.observerLaunchId == launch)
            let taken = try #require(try await observer.takePreRestoreLook(paneId: paneId))
            let expected = sameIncarnation ? current : oldLook
            #expect(taken.paneId == expected.paneId)
            #expect(taken.bindingGenerationId == expected.bindingGenerationId)
            #expect(taken.zmxSessionId == expected.zmxSessionId)
            #expect(taken.sessionIdentity == expected.sessionIdentity)
            #expect(taken.program == expected.program)
            #expect(taken.observerLaunchId == expected.observerLaunchId)
            #expect(taken.sequence == expected.sequence)
            #expect(try await observer.takePreRestoreLook(paneId: paneId) == nil)
            await observer.shutdown()
            try await facts.finish()
        } catch {
            await observer.shutdown()
            try? await facts.finish()
            throw error
        }
    }
}

private func handoffIdentity(bootId: String, daemonPid: Int32) throws -> Data {
    try ZmxSessionIdentity(
        version: 1, bootID: bootId,
        daemon: .init(pid: daemonPid, startSeconds: 1, startMicroseconds: 1),
        terminalLeader: .init(pid: daemonPid + 1, startSeconds: 1, startMicroseconds: 2),
        processGroupID: daemonPid + 1, sessionCreatedAt: 1
    ).encoded()
}
private struct HandoffNewSessionProbe: TerminalForegroundProbing {
    let sessionId: ZmxSessionID
    let identity: Data
    func probeForeground(of sessions: [ZmxSessionID]) -> [ZmxSessionID: ForegroundSnapshot] {
        [sessionId: .init(sessionIdentity: identity, foregroundProcess: nil, program: .shell)]
    }
}
private struct HandoffNoExitWatcher: ProcessExitWatching {
    func watchExit(of process: ProcessIncarnation, watchId: UUID) -> ProcessExitWatch {
        Issue.record("a shell look must not acquire a process-exit watch")
        return .init(events: AsyncStream { $0.finish() }, cancel: {})
    }
}

@concurrent nonisolated private func prepareForegroundDatastore(root: URL) async throws -> WorkspaceSQLiteDatastoreActor
{
    try await prepareForegroundFiles(root: root).datastore
}

@concurrent nonisolated private func prepareForegroundFiles(root: URL) async throws
    -> (datastore: WorkspaceSQLiteDatastoreActor, coreQueue: DatabaseQueue)
{
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let coreQueue = try DatabaseQueue(path: root.appending(path: "core.sqlite").path)
    let localQueue = try DatabaseQueue(path: root.appending(path: "local.sqlite").path)
    let core = WorkspaceCoreRepository(databaseWriter: coreQueue)
    try core.migrate()
    try WorkspaceLocalMigrations.migrate(localQueue)
    let local = WorkspaceLocalRepository(workspaceId: UUIDv7.generate(), databaseWriter: localQueue)
    let datastore = try await preparedWorkspaceSQLiteDatastore(
        coreRepository: core, preparedApplicationLocalRepository: local)
    return (datastore, coreQueue)
}

private func insertLiveMembershipPane(
    _ database: Database, workspaceId: UUID, paneId: UUID, sessionId: ZmxSessionID, provider: String = "zmx"
) throws {
    try database.execute(
        sql: """
            INSERT INTO pane(id, workspace_id, content_type, execution_backend, title,
                residency_kind, kind, created_at, updated_at)
            VALUES (?, ?, ?, 'local', 'Membership proof', 'active', 'leaf', 1, 1)
            """,
        arguments: [
            paneId.uuidString, workspaceId.uuidString, SQLitePaneContentTypeStorage.storageValue(for: .terminal),
        ])
    try database.execute(
        sql:
            "INSERT INTO pane_content_terminal(pane_id, provider, lifetime, zmx_session_id) VALUES (?, ?, 'persistent', ?)",
        arguments: [paneId.uuidString, provider, sessionId.rawValue])
}

private enum HandoffDecisionFailure: Error { case notBound }
