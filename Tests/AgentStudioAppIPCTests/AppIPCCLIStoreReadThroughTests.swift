import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore
@testable import AgentStudioCore

@Suite("App IPC CLI store read-through", .serialized)
struct AppIPCCLIStoreReadThroughTests {
    @Test("an ordinary online call migrates a previous-schema pane store with a null cleanup mark")
    func onlineCallMigratesWithoutPurgePermission() async throws {
        let storage = try await valueFromDedicatedThread { try ReadThroughStorageFixture(cursor: nil) }
        defer { storage.removeFiles() }
        let previousURL = storage.rootURL.appending(path: "previous.sqlite")
        let identity = try await valueFromDedicatedThread {
            let queue = try DatabaseQueue(path: previousURL.path)
            try CLIStoreMigrator.makeMigrator(channel: .debug).migrate(queue, upTo: CLIStoreMigrator.identityMigration)
            let identity = try CLIStore.openReader(url: previousURL, expectedChannel: .debug).get().identity
            try queue.close()
            return identity
        }
        let reader = AppCLIStoreReadThroughReader(
            storeURL: previousURL, expectedChannel: .debug, datastore: storage.datastore)
        try await withLiveServer(
            makeFixture: { try makeServerFixture(reader: reader) },
            body: { fixture in
                try fixture.server.start()
                let response = try await login(fixture: fixture)
                let status = try decodeResponseResult(IPCAuthStatusResult.self, from: response)
                guard case .authenticated(_, _, _, let mark) = status else {
                    Issue.record("Expected authenticated login")
                    return
                }
                #expect(mark == nil)
                let code = try await runCLI(fixture: fixture, storage: storage, storeURL: previousURL)
                #expect(code == 0)
                let observed = try await valueFromDedicatedThread {
                    let queue = try DatabaseQueue(path: previousURL.path)
                    defer { try? queue.close() }
                    return try queue.read { database in
                        let hasOutbox = try database.tableExists("cli_outbox")
                        let noticeCount: Int? =
                            hasOutbox ? try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM cli_outbox") : 0
                        return (
                            migrations: try CLIStoreMigrator.makeMigrator(channel: .debug).appliedMigrations(database),
                            storeID: try String.fetchOne(database, sql: "SELECT store_id FROM cli_store_identity"),
                            identityCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM cli_store_identity"),
                            hasOutbox: hasOutbox,
                            noticeCount: noticeCount
                        )
                    }
                }
                #expect(observed.migrations == [CLIStoreMigrator.identityMigration, CLIStoreMigrator.outboxMigration])
                #expect(observed.storeID == identity.storeID.uuidString)
                #expect(observed.identityCount == 1)
                #expect(observed.hasOutbox)
                #expect(observed.noticeCount == 0)
                #expect(try await storage.cursor() == nil)
            })
    }

    @Test("a successful message stays silent on stderr when its per-call cleanup writer is busy")
    func successfulMessageDoesNotPrintCleanupFailure() async throws {
        let storage = try await valueFromDedicatedThread { try ReadThroughStorageFixture(cursor: 2) }
        defer { storage.removeFiles() }
        let originalRows = try await storage.entries()
        let paneID = UUIDv7.generate()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    channel: .debug, panes: [makePaneSummary(id: paneID, ordinal: 1)],
                    cliStoreReadThroughPort: storage.reader)
            },
            body: { fixture in
                try fixture.server.start()
                let held = HeldStep<Void>("CLI store cleanup is held by a real SQLite writer")
                let writer = storage.writer
                let lockOwner = Task {
                    try await valueFromDedicatedThread {
                        try writer.databaseQueue.write { _ in try held.arriveBlocking(()) }
                    }
                }
                do {
                    try await held.firstArrival()
                    let token = try fixture.issueTestCredential(
                        for: .pane(paneId: paneID, credentialRecordId: UUIDv7.generate(), status: .registered))
                    let output = await runClientCommandLineOffCooperativePool(
                        arguments: ["message", "notice succeeded"],
                        environment: [
                            "AGENTSTUDIO_IPC_SOCKET": fixture.paths.socketURL.path,
                            "AGENTSTUDIO_PANE_TOKEN": token.rawValue,
                            "AGENTSTUDIO_CLI_STORE": storage.storeURL.path,
                            "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
                        ])
                    held.release()
                    try await lockOwner.value
                    #expect(output.exitCode == 0)
                    #expect(output.standardOutput.contains("message sent"))
                    #expect(output.standardError.isEmpty)
                    #expect(try await storage.entries() == originalRows)
                } catch {
                    held.release()
                    _ = try? await lockOwner.value
                    throw error
                }
            })
    }

    @Test(
        "real auth.login reads the matching local cursor, with null for an absent cursor",
        arguments: [ReadThroughCursorScenario.absent, .empty, .handled])
    func loginReportsTheRealStoreCursor(scenario: ReadThroughCursorScenario) async throws {
        let storage = try await valueFromDedicatedThread {
            try ReadThroughStorageFixture(cursor: scenario.lastHandledID)
        }
        defer { storage.removeFiles() }
        try await withLiveServer(
            makeFixture: { try makeServerFixture(reader: storage.reader) },
            body: { fixture in
                try fixture.server.start()
                let response = try await login(fixture: fixture)
                let result = try #require(response.result)
                if case .object(let fields) = result {
                    #expect(fields["cliStoreReadThrough"] != nil)
                    if scenario == .absent { #expect(fields["cliStoreReadThrough"] == .null) }
                } else {
                    Issue.record("Authenticated login did not return an object")
                }
                let status = try decodeResponseResult(IPCAuthStatusResult.self, from: response)
                guard case .authenticated(_, _, _, let mark) = status else {
                    Issue.record("Expected authenticated login")
                    return
                }
                let expected = scenario.lastHandledID.map {
                    IPCCLIStoreReadThrough(storeId: storage.writer.identity.storeID, outbox: $0)
                }
                #expect(mark == expected)
                #expect(try await storage.cursor() == scenario.lastHandledID)
                #expect(try await storage.entries().count == 3)
            })
    }

    @Test("no configured reader yields an explicit null mark without inventing a store")
    func loginWithoutReaderDoesNotCreateAStore() async throws {
        try await withLiveServer(
            makeFixture: { try makeServerFixture(reader: nil) },
            body: { fixture in
                try fixture.server.start()
                let response = try await login(fixture: fixture)
                let result = try #require(response.result)
                guard case .object(let fields) = result else {
                    Issue.record("Expected login object")
                    return
                }
                #expect(fields["cliStoreReadThrough"] == .null)
                #expect(!FileManager.default.fileExists(atPath: fixture.paths.cliStoreURL.path))
            })
    }

    @Test("CLI call completion purges only the real app's old handled prefix")
    func cliCompletionPurgesOnlyHandledOldRows() async throws {
        let storage = try await valueFromDedicatedThread { try ReadThroughStorageFixture(cursor: 2) }
        defer { storage.removeFiles() }
        storage.clock.advance(by: .seconds(86_401))
        try await withLiveServer(
            makeFixture: { try makeServerFixture(reader: storage.reader) },
            body: { fixture in
                try fixture.server.start()
                let first = try await runCLI(fixture: fixture, storage: storage, storeURL: storage.storeURL)
                #expect(first == 0)
                #expect(try await storage.entries() == [storage.recentHandled, storage.unread])
                storage.clock.advance(by: .seconds(30 * 86_400))
                let second = try await runCLI(fixture: fixture, storage: storage, storeURL: storage.storeURL)
                #expect(second == 0)
                #expect(try await storage.entries() == [storage.unread])
                #expect(try await storage.cursor() == 2)
            })
    }

    @Test("the CLI ignores a real login mark for a foreign same-channel store")
    func cliCompletionCannotPurgeAnotherStore() async throws {
        let storage = try await valueFromDedicatedThread { try ReadThroughStorageFixture(cursor: 2) }
        defer { storage.removeFiles() }
        let foreignURL = storage.rootURL.appending(path: "foreign.sqlite")
        let foreign = try await valueFromDedicatedThread {
            try CLIStore.openWriter(url: foreignURL, channel: .debug).get()
        }
        let foreignEntry = try await valueFromDedicatedThread {
            try foreign.appendNotice(
                paneID: UUIDv7.generate(), messageID: UUIDv7.generate(), payloadJSON: "{}",
                createdAt: storage.originDate
            ).get()
        }
        storage.clock.advance(by: .seconds(10 * 86_400))
        try await withLiveServer(
            makeFixture: { try makeServerFixture(reader: storage.reader) },
            body: { fixture in
                try fixture.server.start()
                #expect(foreign.identity.storeID != storage.writer.identity.storeID)
                #expect(foreignEntry.id <= 2)
                let status = try decodeResponseResult(IPCAuthStatusResult.self, from: await login(fixture: fixture))
                guard case .authenticated(_, _, _, let mark) = status else {
                    Issue.record("Expected login")
                    return
                }
                #expect(mark?.storeId == storage.writer.identity.storeID)
                let code = try await runCLI(fixture: fixture, storage: storage, storeURL: foreignURL)
                #expect(code == 0)
                let remaining = try await valueFromDedicatedThread { try foreign.readOutbox(after: 0).get().entries }
                #expect(remaining == [foreignEntry])
            })
    }

    @Test("a real readonly reader refuses foreign channel files and returns no cursor mark")
    func foreignChannelReaderReturnsNoMark() async throws {
        let storage = try await valueFromDedicatedThread { try ReadThroughStorageFixture(cursor: 2) }
        defer { storage.removeFiles() }
        #expect(
            await storage.reader.readThrough()
                == IPCCLIStoreReadThrough(storeId: storage.writer.identity.storeID, outbox: 2))
        let reader = AppCLIStoreReadThroughReader(
            storeURL: storage.storeURL, expectedChannel: .beta, datastore: storage.datastore)
        #expect(await reader.readThrough() == nil)
        #expect(try await storage.entries().count == 3)
        #expect(try await storage.cursor() == 2)
    }

    @Test("a missing CLI file stays absent when the app asks for read-through")
    func readonlyReadThroughDoesNotCreateAStore() async throws {
        let storage = try await valueFromDedicatedThread { try ReadThroughStorageFixture(cursor: 2) }
        defer { storage.removeFiles() }
        #expect(
            await storage.reader.readThrough()
                == IPCCLIStoreReadThrough(storeId: storage.writer.identity.storeID, outbox: 2))
        let absentURL = storage.rootURL.appending(path: "missing/cli.sqlite")
        let reader = AppCLIStoreReadThroughReader(
            storeURL: absentURL, expectedChannel: .debug, datastore: storage.datastore)
        #expect(await reader.readThrough() == nil)
        #expect(!FileManager.default.fileExists(atPath: absentURL.deletingLastPathComponent().path))
        #expect(try await storage.cursor() == 2)
    }

    private func makeServerFixture(reader: (any AppIPCCLIStoreReadThroughPort)?) throws -> LiveServerFixture {
        try LiveServerFixture(channel: .debug, cliStoreReadThroughPort: reader)
    }

    private func login(fixture: LiveServerFixture) async throws -> JSONRPCResponseMessage {
        let token = fixture.installDebugCredential()
        let connection = try await connectWithoutBlockingCooperativePool(socketPath: fixture.paths.socketURL.path)
        defer { connection.close() }
        try await sendRequestWithoutBlockingCooperativePool(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(1), method: "auth.login", params: .object(["token": .string(token.rawValue)])))
        var reader = TestFrameReader()
        return try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
    }

    private func runCLI(fixture: LiveServerFixture, storage: ReadThroughStorageFixture, storeURL: URL) async throws
        -> Int32
    {
        let token = fixture.installDebugCredential()
        let environment = [
            "AGENTSTUDIO_IPC_SOCKET": fixture.paths.socketURL.path, "AGENTSTUDIO_PANE_TOKEN": token.rawValue,
            "AGENTSTUDIO_CLI_STORE": storeURL.path, "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
        ]
        return await valueFromDedicatedThread {
            AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: ["system.ping"], environment: environment, executablePath: "/fixture/agentstudio",
                    bundleExecutableURL: nil, standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: { _ in }, standardErrorSink: { _ in }, now: { storage.now }))
        }
    }
}

enum ReadThroughCursorScenario: Sendable {
    case absent, empty, handled
    var lastHandledID: Int64? {
        switch self {
        case .absent: nil
        case .empty: 0
        case .handled: 2
        }
    }
}

private struct ReadThroughStorageFixture: Sendable {
    let rootURL: URL
    let storeURL: URL
    let writer: CLIStore
    let datastore: WorkspaceSQLiteDatastoreActor
    let reader: AppCLIStoreReadThroughReader
    let coreQueue: DatabaseQueue
    let localQueue: DatabaseQueue
    let recentHandled: CLIOutboxEntry
    let unread: CLIOutboxEntry
    let clock = TestPushClock()
    let originInstant: TestPushClock.Instant
    let originDate = Date(timeIntervalSince1970: 1_700_000_000)

    init(cursor: Int64?) throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "cli-read-through-\(UUIDv7.generate())")
        storeURL = rootURL.appending(path: "cli.sqlite")
        originInstant = clock.now
        writer = try CLIStore.openWriter(url: storeURL, channel: .debug).get()
        _ = try Self.append(to: writer, createdAt: originDate)
        recentHandled = try Self.append(to: writer, createdAt: originDate.addingTimeInterval(43_200))
        unread = try Self.append(to: writer, createdAt: originDate)
        coreQueue = try SQLiteDatabaseFactory.makeInMemoryQueue()
        localQueue = try DatabaseQueue(path: rootURL.appending(path: "local.sqlite").path)
        try WorkspaceCoreMigrations.migrate(coreQueue)
        try WorkspaceLocalMigrations.migrate(localQueue)
        if let cursor {
            let storeID = writer.identity.storeID
            try localQueue.write { database in
                try CLIOutboxCursorCommitParticipant(storeID: storeID, lastHandledID: cursor).commit(in: database)
            }
        }
        datastore = WorkspaceSQLiteDatastoreActor(
            preparedCoreRepository: WorkspaceCoreRepository(databaseWriter: coreQueue),
            preparationReceipt: .init(core: .uninitialized, local: .available(recovery: nil)),
            preparedApplicationLocalRepository: WorkspaceLocalRepository(
                workspaceId: UUIDv7.generate(), databaseWriter: localQueue))
        reader = AppCLIStoreReadThroughReader(storeURL: storeURL, expectedChannel: .debug, datastore: datastore)
    }

    var now: Date {
        let elapsed = originInstant.duration(to: clock.now).components
        return originDate.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    func entries() async throws -> [CLIOutboxEntry] {
        try await valueFromDedicatedThread { try writer.readOutbox(after: 0).get().entries }
    }

    func cursor() async throws -> Int64? {
        let storeID = writer.identity.storeID
        return try await datastore.performApplicationLocalRead {
            try Int64.fetchOne(
                $0, sql: "SELECT last_handled_id FROM pane_context_cli_outbox_cursor WHERE store_id = ?",
                arguments: [storeID.uuidString])
        }
    }

    private static func append(to writer: CLIStore, createdAt: Date) throws -> CLIOutboxEntry {
        try writer.appendNotice(
            paneID: UUIDv7.generate(), messageID: UUIDv7.generate(), payloadJSON: "{}", createdAt: createdAt
        ).get()
    }

    func removeFiles() {
        try? writer.databaseQueue.close()
        try? localQueue.close()
        try? coreQueue.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
