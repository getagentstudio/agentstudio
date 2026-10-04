import AgentStudioAppIPC
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

/// Domain setup only. Server creation, stop marking, handler joins and socket
/// directory teardown remain exclusively in withLiveServer.
final class PaneContextIPCDomainCompanion: Sendable {
    let rootURL: URL
    let corePool: DatabasePool
    let localPool: DatabasePool
    let paneId = UUIDv7.generate()
    let membership = PaneContextIPCTestMembership()
    let clock = TestPushClock()
    let time: PaneContextIPCTestTime
    let access: HeldPaneContextIPCSQLiteAccess
    let service: PaneContextService
    let ingestion: SessionsIngestion
    let sessionsSQLiteAccess: WorkspaceSessionsSQLiteAccess
    let sessionsBridge = PaneContextSessionsBridge()
    let facts: LocalFactSource<UUID, PaneContextIPCDomainFact>

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "as-pane-domain-\(UUIDv7.generate())")
        corePool = try SQLiteDatabaseFactory.makeFileBackedPool(
            at: rootURL.appending(path: "core.sqlite"), label: "AgentStudio.sqlite.ipc-pane-core")
        do {
            localPool = try SQLiteDatabaseFactory.makeFileBackedPool(
                at: rootURL.appending(path: "local.sqlite"), label: "AgentStudio.sqlite.ipc-pane-local")
        } catch {
            try? corePool.close()
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
        do {
            try WorkspaceCoreMigrations.migrate(corePool)
            try WorkspaceLocalMigrations.migrate(localPool)
        } catch {
            try? corePool.close()
            try? localPool.close()
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
        let datastore = WorkspaceSQLiteDatastoreActor(
            preparedCoreRepository: WorkspaceCoreRepository(databaseWriter: corePool),
            preparationReceipt: .init(core: .uninitialized, local: .available(recovery: nil)),
            preparedApplicationLocalRepository: WorkspaceLocalRepository(
                workspaceId: UUIDv7.generate(), databaseWriter: localPool))
        access = HeldPaneContextIPCSQLiteAccess(base: WorkspacePaneContextSQLiteAccess(datastore: datastore))
        sessionsSQLiteAccess = WorkspaceSessionsSQLiteAccess(datastore: datastore)
        ingestion = SessionsIngestion(
            repository: SessionsRepository(sqliteAccess: sessionsSQLiteAccess),
            limits: SessionsIngestionLimits(maximumPendingPerPane: 32, maximumPendingGlobal: 128),
            probe: { _ in }, openAskSource: sessionsBridge)
        time = PaneContextIPCTestTime(clock: clock)
        facts = LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .joined, .requestRefused: true
                    case .openAskCount, .writeAdmissionReached: false
                    }
                }))
        membership.addPane(PaneId(existingUUID: paneId))
        let facts = facts
        let paneId = paneId
        let sessionsBridge = sessionsBridge
        service = PaneContextService(
            sqliteAccess: access, clock: clock, wallNow: { [time] in time.now }, membership: membership,
            currentBindingGeneration: PaneContextSessionsBridge.currentBindingGeneration,
            sessionSummary: { paneId in
                try await sessionsBridge.sessionSummary(paneId: paneId)
            },
            openAskSink: { update in
                await sessionsBridge.receiveOpenAskSummary(update)
                facts.sink(paneId, .openAskCount(update.approval + update.question + update.blocked))
            })
        sessionsBridge.connect(service: service, ingestion: ingestion)
    }

    func adapter(
        maximumEncodedReplyBytes: Int = min(
            IPCFramePolicy.maximumResponseFrameBytes, AppPolicies.IPC.maximumQueuedOutputBytes - 1)
    ) -> AgentStudioIPCPaneContextAdapter {
        AgentStudioIPCPaneContextAdapter(
            service: service, ingestion: ingestion, maximumEncodedReplyBytes: maximumEncodedReplyBytes)
    }

    /// The initial RPC is request 2 after login 1. If it refuses before reaching
    /// the awaited domain seam, the recorder consumes this correlated closing
    /// fact instead of waiting forever for admission. Physical writes keep the
    /// real server I/O path and never block an async test body.
    func connectionIOReportingRefusals(_ connection: UnixSocketConnection, in operationScope: UUID? = nil)
        -> AppIPCConnectionIO
    {
        let live = AppIPCConnectionIO.live(connection)
        let scope = operationScope ?? paneId
        return AppIPCConnectionIO(
            receive: live.receive,
            send: { [facts] bytes in
                try live.send(bytes)
                guard let payload = String(data: bytes, encoding: .utf8),
                    let response = try? JSONRPCCodec.decodeResponse(payload),
                    let requestId = response.id, requestId == .number(2), response.error != nil
                else { return }
                facts.sink(
                    scope, .requestRefused(requestId: requestId, reason: paneContextRefusalReason(response)))
            },
            close: live.close
        )
    }

    func bind(conversationId: String = "current", to targetPaneId: UUID? = nil) async throws -> IPCPaneWriterClaim {
        let provider = SessionsProviderIdentity(
            providerIdentifier: "claude-code", exactVersion: "2.1.286", operatingMode: "interactive")
        let source = SessionsBindingSourceIdentity(
            paneId: targetPaneId ?? paneId, providerConversationId: conversationId, sourceId: "ipc-pane-tests",
            sourceGenerationId: UUIDv7.generate(), occurrenceId: UUIDv7.generate())
        _ = try await ingestion.submit(
            correlationId: UUIDv7.generate(),
            mutation: .bind(
                .explicitModelBind(
                    SessionsExplicitModelBindInput(provider: provider, source: source, reportedAt: time.now))))
        return IPCPaneWriterClaim(provider: provider.providerIdentifier, conversationId: conversationId)
    }

    func sendParameters(
        messageId: UUID = UUIDv7.generate(), writer: IPCPaneWriterClaim? = nil, body: String = "Exact message",
        shape: IPCPaneMessageSendShape = .notice, why: String? = nil, actions: [IPCPaneMessageAction] = []
    ) -> IPCPaneMessageSendParams {
        IPCPaneMessageSendParams(
            handle: "self", messageId: messageId, writer: writer, importance: .attention,
            body: body, why: why, actions: actions, shape: shape, correlationId: UUIDv7.generate())
    }

    func askParameters(messageId: UUID = UUIDv7.generate(), writer: IPCPaneWriterClaim, deadline: Date? = nil)
        -> IPCPaneMessageAskParams
    {
        IPCPaneMessageAskParams(
            handle: "self", messageId: messageId, writer: writer, importance: .attention,
            body: "Proceed?", actions: [],
            shape: .ask(
                reason: .question, form: .freeText(placeholder: nil),
                waiting: .blocking(deadline: deadline ?? time.now.addingTimeInterval(60))),
            correlationId: UUIDv7.generate())
    }

    func seedNotices(count: Int, body: String, why: String? = nil) async throws -> Set<UUID> {
        let pane = PaneId(existingUUID: paneId)
        var identifiers = Set<UUID>()
        for _ in 0..<count {
            let identifier = AgentMessageId.generateUUIDv7()
            let request = PaneMessageSendRequest(
                paneId: pane, messageId: identifier, sender: .pane(pane),
                sourceOccurredAt: nil, importance: .info, body: body, why: why, actions: [], shape: .notice)
            try #require(await service.send(request) == .created(identifier))
            identifiers.insert(identifier.uuid)
        }
        return identifiers
    }

    func seedMessage(in source: PaneId, body: String, writer: IPCPaneWriterClaim? = nil) async throws -> UUID {
        let sender: AgentMessageSender
        let shape: PaneMessageSendShape
        if let writer {
            let binding = try #require(
                try await ingestion.bindingForProviderConversation(
                    paneId: source.uuid, providerIdentifier: writer.provider,
                    providerConversationId: writer.conversationId))
            sender = .session(
                provider: try BridgeAgentProviderName(binding.providerIdentifier),
                sessionRef: try BridgeAgentSessionRef(binding.providerConversationId),
                bindingGeneration: binding.bindingGenerationId)
            shape = .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking)
        } else {
            sender = .pane(source)
            shape = .notice
        }
        let messageId = AgentMessageId.generateUUIDv7()
        try #require(
            await service.send(
                PaneMessageSendRequest(
                    paneId: source, messageId: messageId, sender: sender, sourceOccurredAt: nil,
                    importance: .attention, body: body, why: nil, actions: [], shape: shape)) == .created(messageId))
        return messageId.uuid
    }

    func shutdown() async throws {
        access.releaseHeldWork()
        await service.stop()
        await ingestion.finish()
        try await withoutBlockingCooperativePool { [corePool, localPool, rootURL] in
            try corePool.close()
            try localPool.close()
            try FileManager.default.removeItem(at: rootURL)
        }
    }
}

func withPaneContextIPCDomain<Output>(
    _ body: (PaneContextIPCDomainCompanion) async throws -> Output
) async throws -> Output {
    let domain = try await withoutBlockingCooperativePool { try PaneContextIPCDomainCompanion() }
    do {
        let output = try await body(domain)
        try await domain.shutdown()
        return output
    } catch {
        try? await domain.shutdown()
        throw error
    }
}

enum PaneContextIPCDomainFact: Equatable, Sendable {
    case openAskCount(Int)
    case writeAdmissionReached
    case requestRefused(requestId: JSONRPCIdentifier, reason: String?)
    case joined
}

/// Holds the production transaction boundary, not a substitute repository.
final class HeldPaneContextIPCSQLiteAccess: PaneContextSQLiteAccess, Sendable {
    private struct Holds: Sendable {
        var beforeWrite: HeldStep<Void>?
        var afterWrite: HeldStep<Void>?
        var beforeWriteReached: (@Sendable () -> Void)?
    }
    private let base: WorkspacePaneContextSQLiteAccess
    private let holds = Mutex(Holds())
    private let registeredHolds = Mutex<[HeldStep<Void>]>([])

    init(base: WorkspacePaneContextSQLiteAccess) { self.base = base }

    func holdNextWrite(
        before: HeldStep<Void>? = nil, after: HeldStep<Void>? = nil,
        beforeWriteReached: (@Sendable () -> Void)? = nil
    ) {
        registeredHolds.withLock {
            if let before { $0.append(before) }
            if let after { $0.append(after) }
        }
        holds.withLock {
            $0 = Holds(beforeWrite: before, afterWrite: after, beforeWriteReached: beforeWriteReached)
        }
    }

    func releaseHeldWork() {
        let held = holds.withLock { current in
            let held = current
            current = Holds()
            return held
        }
        held.beforeWrite?.retire()
        held.afterWrite?.retire()
        for registeredHold in registeredHolds.withLock({ $0 }) {
            registeredHold.retire()
        }
    }

    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await base.read(operation)
    }

    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        let held = holds.withLock { current in
            let held = current
            current = Holds()
            return held
        }
        held.beforeWriteReached?()
        try await held.beforeWrite?.arrive(())
        let output = try await base.write(operation)
        try await held.afterWrite?.arrive(())
        return output
    }
}

final class PaneContextIPCTestMembership: PaneContextMembershipReading, Sendable {
    private let sourcesByPane = Mutex<[PaneId: [PaneId]]>([:])
    func sources(for paneId: PaneId) -> [PaneId]? { sourcesByPane.withLock { $0[paneId] } }
    func addPane(_ paneId: PaneId) { sourcesByPane.withLock { $0[paneId] = [paneId] } }
    func setDrawers(_ drawers: [PaneId], for owner: PaneId) {
        sourcesByPane.withLock { sources in
            sources[owner] = [owner] + drawers
            for drawer in drawers { sources[drawer] = [drawer] }
        }
    }
}

final class PaneContextIPCTestTime: Sendable {
    private let clock: TestPushClock
    private let origin: TestPushClock.Instant
    init(clock: TestPushClock) {
        self.clock = clock
        origin = clock.now
    }
    var now: Date {
        let elapsed = origin.duration(to: clock.now).components
        return Date(timeIntervalSince1970: 1_800_000_000 + Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}

/// Domain socket setup composes the existing live fixture; it owns no server
/// teardown. Each wait consumes the correlated response through TestFrameReader.
func withPaneContextWire(
    domain: PaneContextIPCDomainCompanion,
    panes: [IPCPaneSummary]? = nil,
    sessionsPort: any AppIPCSessionsPort = RecordingSessionsPort(),
    maximumEncodedReplyBytes: Int = min(
        IPCFramePolicy.maximumResponseFrameBytes, AppPolicies.IPC.maximumQueuedOutputBytes - 1),
    body: (LiveServerFixture, inout PaneContextWireClient) async throws -> Void
) async throws {
    try await withLiveServer(
        makeFixture: {
            try LiveServerFixture(
                channel: .stable, panes: panes ?? [makePaneSummary(id: domain.paneId, ordinal: 1)],
                sessionsPort: sessionsPort,
                paneContextPort: domain.adapter(maximumEncodedReplyBytes: maximumEncodedReplyBytes))
        },
        releaseHeldWork: { domain.access.releaseHeldWork() },
        body: { fixture in
            try fixture.server.start()
            var client = try await PaneContextWireClient(fixture: fixture, paneId: domain.paneId)
            defer { client.close() }
            try await body(fixture, &client)
        })
}

struct PaneContextWireClient {
    private let connection: UnixSocketConnection
    private var reader = TestFrameReader(
        decoder: NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
    private var nextRequestId = 2

    init(fixture: LiveServerFixture, paneId: UUID) async throws {
        let token = try fixture.issueTestCredential(
            for: .pane(paneId: paneId, credentialRecordId: UUIDv7.generate(), status: .registered))
        connection = try await connectWithoutBlockingCooperativePool(socketPath: fixture.paths.socketURL.path)
        do {
            try await loginWithoutBlockingMainActor(
                connection: connection, token: token, requestId: 1, reader: &reader)
        } catch {
            connection.close()
            throw error
        }
    }

    func close() { connection.close() }

    mutating func response<Parameters: Encodable>(method: String, params: Parameters) async throws
        -> JSONRPCResponseMessage
    {
        let requestId = JSONRPCIdentifier.number(nextRequestId)
        nextRequestId += 1
        try await sendRequestWithoutBlockingCooperativePool(
            connection: connection,
            request: try JSONRPCClientRequest(
                id: requestId, method: method, params: JSONRPCCodec.encodeJSONValue(params)))
        let reply = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        #expect(reply.id == requestId, "The response must close the exact request")
        return reply
    }

    mutating func detail(page: IPCPaneContextReadPage = .first) async throws -> IPCPaneContextGetResult {
        try paneContextWireResult(
            IPCPaneContextGetResult.self,
            from: await response(
                method: "pane.context.get", params: IPCPaneContextGetParams(handle: "self", page: page)))
    }

    mutating func send(_ params: IPCPaneMessageSendParams) async throws -> IPCPaneMessageSendResult {
        try paneContextWireResult(
            IPCPaneMessageSendResult.self, from: await response(method: "pane.message.send", params: params))
    }

    mutating func changes(writer: IPCPaneWriterClaim?, after: UInt64) async throws -> IPCPaneMessageChangesResult {
        try paneContextWireResult(
            IPCPaneMessageChangesResult.self,
            from: await response(
                method: "pane.message.changes",
                params: IPCPaneMessageChangesParams(
                    handle: "self", writer: writer, after: after, correlationId: UUIDv7.generate())))
    }
}
