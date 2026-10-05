import AgentStudioAppIPC
import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
func withPaneCLIOutboxDrainHarness(
    refusalProbe: @escaping @Sendable (PaneCLIOutboxDrain.RefusalReason) -> Void = { _ in },
    _ body: @MainActor (PaneCLIOutboxDrainHarness) async throws -> Void
) async throws {
    let harness = try await PaneCLIOutboxDrainHarness(refusalProbe: refusalProbe)
    do {
        try await body(harness)
    } catch {
        await harness.tearDown()
        throw error
    }
    await harness.tearDown()
}

/// Real prepared local.sqlite, real Sessions ingestion and the live adapter.
/// Only the local SQLite write seam can fail; admission is never mocked.
@MainActor
final class PaneCLIOutboxDrainHarness {
    let rootURL: URL
    let storeURL: URL
    let legacyDirectory: URL
    let writer: CLIStore
    let sqliteAccess: FailableOutboxSessionsSQLiteAccess
    let repository: SessionsRepository
    let ingestion: SessionsIngestion
    let admission: AgentStudioIPCPaneContextAdapter
    let sessionAdmission: AgentStudioIPCSessionsAdapter
    let paneService: PaneContextService
    let membership = TestPaneContextMembership()
    let clock = TestPushClock()
    let refusalRecorder = OutboxRefusalRecorder()
    private let drainOwner: PaneCLIOutboxDrain
    private let additionalRefusalProbe: @Sendable (PaneCLIOutboxDrain.RefusalReason) -> Void

    static let testProvider = IPCSessionProviderIdentity(
        identifier: "outbox-drain-provider", version: "1.0.0", mode: "interactive")

    init(refusalProbe: @escaping @Sendable (PaneCLIOutboxDrain.RefusalReason) -> Void) async throws {
        additionalRefusalProbe = refusalProbe
        let rootURL = FileManager.default.temporaryDirectory.appending(path: "cli-outbox-drain-\(UUIDv7.generate())")
        let storeURL = rootURL.appending(path: "ipc/cli.sqlite")
        self.rootURL = rootURL
        self.storeURL = storeURL
        legacyDirectory = rootURL.appending(path: "ipc/spool/v2")
        writer = try await valueFromDedicatedThread { try CLIStore.openWriter(url: storeURL, channel: .debug).get() }
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: UUIDv7.generate())
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        guard case .ready = await datastore.prepareOptionalApplicationLocalSchema() else {
            throw OutboxHarnessFailure.optionalSchemaUnavailable
        }
        let sqliteAccess = FailableOutboxSessionsSQLiteAccess(base: WorkspaceSessionsSQLiteAccess(datastore: datastore))
        self.sqliteAccess = sqliteAccess
        repository = SessionsRepository(sqliteAccess: sqliteAccess)
        let ingestion = SessionsIngestion(
            repository: repository,
            limits: SessionsIngestionLimits(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in })
        self.ingestion = ingestion
        let admission = AgentStudioIPCSessionsAdapter(ingestion: ingestion)
        sessionAdmission = admission
        paneService = PaneContextService(
            sqliteAccess: sqliteAccess, clock: clock, wallNow: { Date(timeIntervalSince1970: 1_700_000_000) },
            membership: membership, currentBindingGeneration: PaneContextSessionsBridge.currentBindingGeneration)
        self.admission = AgentStudioIPCPaneContextAdapter(service: paneService, ingestion: ingestion)
        let recorder = refusalRecorder
        drainOwner = try PaneCLIOutboxDrain(
            admission: self.admission, sqliteAccess: sqliteAccess, expectedChannel: .debug,
            refusalProbe: {
                recorder.record($0)
                refusalProbe($0)
            })
    }

    func drain() async -> PaneCLIOutboxDrain.DrainReport {
        await drainOwner.drain(storeURL: storeURL, legacySpoolDirectory: legacyDirectory)
    }

    func restartedDrain() async throws -> PaneCLIOutboxDrain.DrainReport {
        let recorder = refusalRecorder
        let refusalProbe = additionalRefusalProbe
        let restarted = try PaneCLIOutboxDrain(
            admission: admission, sqliteAccess: sqliteAccess, expectedChannel: .debug,
            refusalProbe: {
                recorder.record($0)
                refusalProbe($0)
            })
        return await restarted.drain(storeURL: storeURL, legacySpoolDirectory: legacyDirectory)
    }

    func append(paneID: UUID, line: String, messageID: UUID? = nil) async throws -> CLIOutboxEntry {
        membership.addPane(PaneId(existingUUID: paneID))
        let resolvedID: UUID
        if let messageID {
            resolvedID = messageID
        } else if let request = try? JSONRPCCodec.decodeRequest(line),
            case .object(let parameters)? = request.params,
            case .string(let correlation)? = parameters["messageId"] ?? parameters["correlationId"],
            let parsed = UUID(uuidString: correlation)
        {
            resolvedID = parsed
        } else {
            resolvedID = UUIDv7.generate()
        }
        let writer = writer
        return try await valueFromDedicatedThread {
            try writer.appendNotice(
                paneID: paneID, messageID: resolvedID, payloadJSON: line,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ).get()
        }
    }

    func rows() async throws -> [CLIOutboxEntry] {
        let writer = writer
        return try await valueFromDedicatedThread { try writer.readOutbox(after: 0).get().entries }
    }

    func cursor() async throws -> Int64 {
        let storeID = writer.identity.storeID
        return try await sqliteAccess.read { database in
            // Until the production migration lands, absent means no progress.
            guard try database.tableExists("pane_context_cli_outbox_cursor") else { return 0 }
            return try Int64.fetchOne(
                database,
                sql: "SELECT last_handled_id FROM pane_context_cli_outbox_cursor WHERE store_id = ?",
                arguments: [storeID.uuidString]) ?? 0
        }
    }

    func sessionSummary(paneID: UUID) async throws -> SessionSummary? {
        try await ingestion.sessionSummary(paneId: paneID)
    }

    func attention(paneID: UUID) async throws -> [SessionsStoredAttentionRecord] {
        try await repository.statusContext(paneId: paneID).attention
    }

    func snapshot(paneID: UUID) async throws -> SessionsSnapshot {
        try await repository.snapshot(.pane(paneID))
    }

    func bindPane(paneID: UUID) async throws {
        membership.addPane(PaneId(existingUUID: paneID))
        let result = try await sessionAdmission.recordProviderEvent(
            paneId: paneID,
            params: IPCSessionEventParams(
                handle: paneID.uuidString, provider: Self.testProvider,
                event: IPCSessionEventIdentity(
                    name: .sessionStart, conversationId: "conversation-\(paneID)",
                    turnId: nil, requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                correlationId: UUIDv7.generate()), provenance: .matchingPane)
        #expect(result.disposition == .admitted)
        let currentSnapshot = try await snapshot(paneID: paneID)
        let binding = try #require(currentSnapshot.currentBinding)
        #expect(binding.status == .active)
        #expect(binding.paneId == paneID)
    }

    func paneMessages(paneID: UUID) async throws -> [AgentMessageDetail] {
        let result = await paneService.readDetail(.init(paneId: PaneId(existingUUID: paneID), page: .first))
        guard case .detail(let detail) = result else { throw OutboxStorageFailure() }
        return detail.messages
    }

    func messageLine(
        text: String, handle: String = "self", correlationID: UUID = UUIDv7.generate(),
        writer: IPCPaneWriterClaim? = nil
    ) throws -> String {
        try requestLine(
            method: "pane.message.send",
            parameters: IPCPaneMessageSendParams(
                handle: handle, messageId: correlationID, writer: writer,
                sourceOccurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                importance: .info, body: text, actions: [],
                shape: .notice, correlationId: correlationID))
    }

    func legacyMessageLine(text: String, correlationID: UUID = UUIDv7.generate()) throws -> String {
        try JSONRPCCodec.encodeRequest(
            .init(
                id: .number(1), method: "session.message",
                params: .object([
                    "handle": .string("self"), "text": .string(text),
                    "correlationId": .string(correlationID.uuidString),
                ])))
    }

    func reportLine(kind: String, explanation: String?, correlationID: UUID = UUIDv7.generate()) throws -> String {
        var parameters: [String: JSONValue] = [
            "handle": .string("self"), "kind": .string(kind), "correlationId": .string(correlationID.uuidString),
        ]
        if let explanation { parameters["explanation"] = .string(explanation) }
        return try JSONRPCCodec.encodeRequest(
            .init(id: .number(1), method: "session.report", params: .object(parameters)))
    }

    func providerEventLine() throws -> String {
        try requestLine(
            method: "session.event",
            parameters: IPCSessionEventParams(
                handle: "self", provider: Self.testProvider,
                event: IPCSessionEventIdentity(
                    name: .sessionStart, conversationId: "forged-outbox-event",
                    turnId: nil, requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                correlationId: UUIDv7.generate()))
    }

    func legacyFileURL(paneID: UUID) -> URL {
        legacyDirectory.appending(path: "\(paneID.uuidString).notifications.ndjson")
    }

    func writeLegacyFile(paneID: UUID, lines: [String]) throws {
        membership.addPane(PaneId(existingUUID: paneID))
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data(lines.map { "\($0)\n" }.joined().utf8).write(to: legacyFileURL(paneID: paneID))
    }

    func tearDown() async {
        await paneService.stop()
        await ingestion.finish()
        try? await valueFromDedicatedThread { [writer] in try writer.close() }
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func requestLine(method: String, parameters: some Encodable) throws -> String {
        let value = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(parameters))
        return try JSONRPCCodec.encodeRequest(JSONRPCClientRequest(id: .number(1), method: method, params: value))
    }
}

private enum OutboxHarnessFailure: Error { case optionalSchemaUnavailable }

struct OutboxStorageFailure: Error {}

final class OutboxRefusalRecorder: Sendable {
    private let values = Mutex<[PaneCLIOutboxDrain.RefusalReason]>([])

    func record(_ reason: PaneCLIOutboxDrain.RefusalReason) { values.withLock { $0.append(reason) } }
    var reasons: [PaneCLIOutboxDrain.RefusalReason] { values.withLock { $0 } }
}

actor FailableOutboxSessionsSQLiteAccess: SessionsSQLiteAccess, PaneContextSQLiteAccess {
    private let base: WorkspaceSessionsSQLiteAccess
    private var rejectsWrites = false
    private var rejectsNextWrite = false
    private var rejectsCursorCommit = false

    init(base: WorkspaceSessionsSQLiteAccess) { self.base = base }

    func setRejectsWrites(_ rejects: Bool) { rejectsWrites = rejects }
    func failNextWrite() { rejectsNextWrite = true }
    func failCursorCommit() { rejectsCursorCommit = true }

    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await base.read(operation)
    }

    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        guard !rejectsWrites else { throw OutboxStorageFailure() }
        if rejectsNextWrite {
            rejectsNextWrite = false
            throw OutboxStorageFailure()
        }
        let failCursorCommit = rejectsCursorCommit
        return try await base.write { database in
            let output = try operation(database)
            // Fail after the participating cursor SQL but before GRDB commits.
            // A separate later cursor transaction would leave the notice saved,
            // which the rollback test deliberately rejects.
            if failCursorCommit, try database.tableExists("pane_context_cli_outbox_cursor"),
                (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM pane_context_cli_outbox_cursor") ?? 0) > 0
            {
                throw OutboxStorageFailure()
            }
            return output
        }
    }
}
