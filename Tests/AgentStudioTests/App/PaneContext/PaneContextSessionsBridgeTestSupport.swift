import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio

// Both owners use the same real transactions and HeldStep seam. The wrapper
// avoids a retroactive conformance on the shared test-support actor.
private struct BridgeSessionsSQLiteAccess: SessionsSQLiteAccess {
    let access: HeldPaneContextSQLiteAccess

    func read<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await access.read(operation)
    }

    func write<Output: Sendable>(
        _ operation: @Sendable (Database) throws -> Output
    ) async throws -> Output {
        try await access.write(operation)
    }
}

final class PaneContextSessionsBridgeFixture: Sendable {
    let root: URL
    let pool: DatabasePool
    let sqliteAccess: HeldPaneContextSQLiteAccess
    let clock: TestPushClock
    let time: PaneContextTestTime
    let membership: TestPaneContextMembership
    let paneId: PaneId
    let bridge: PaneContextSessionsBridge
    let ingestion: SessionsIngestion
    let service: PaneContextService
    let provider = IPCSessionProviderIdentity(
        identifier: ClaudeCodeProviderIdentity.identifier,
        version: "2.1.289", mode: ClaudeCodeProviderIdentity.operatingMode)

    init(ingestionProbe: @escaping SessionsIngestionProbe = { _ in }) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "agentstudio-context-sessions-\(UUIDv7.generate())")
        pool = try SQLiteDatabaseFactory.makeFileBackedPool(
            at: root.appending(path: "local.sqlite"), label: "AgentStudio.sqlite.context-sessions-tests")
        try WorkspaceLocalMigrations.migrate(pool)
        let access = HeldPaneContextSQLiteAccess(databasePool: pool)
        sqliteAccess = access
        let clock = TestPushClock()
        self.clock = clock
        let time = PaneContextTestTime(clock: clock)
        self.time = time
        let membership = TestPaneContextMembership()
        self.membership = membership
        paneId = .generateUUIDv7()
        membership.addPane(paneId)
        let bridge = PaneContextSessionsBridge()
        self.bridge = bridge
        let ingestion = Self.makeSessionsIngestion(access: access, bridge: bridge, probe: ingestionProbe)
        self.ingestion = ingestion
        service = PaneContextService(
            sqliteAccess: access, clock: clock, wallNow: { time.now }, membership: membership,
            currentBindingGeneration: { paneId, database in
                try PaneContextSessionsBridge.currentBindingGeneration(paneId: paneId, in: database)
            },
            sessionSummary: { paneId in try await bridge.sessionSummary(paneId: paneId) },
            openAskSink: { update in await bridge.receiveOpenAskSummary(update) },
            agentLineSink: { work, generation in
                await bridge.receiveAgentLine(work: work, bindingGenerationId: generation)
            }
        )
        bridge.connect(service: service, ingestion: ingestion)
    }

    func makeIngestion() -> SessionsIngestion { Self.makeSessionsIngestion(access: sqliteAccess, bridge: bridge) }

    private static func makeSessionsIngestion(
        access: HeldPaneContextSQLiteAccess, bridge: PaneContextSessionsBridge,
        probe: @escaping SessionsIngestionProbe = { _ in }
    )
        -> SessionsIngestion
    {
        SessionsIngestion(
            repository: .init(sqliteAccess: BridgeSessionsSQLiteAccess(access: access)),
            limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: probe, openAskSource: bridge,
            sessionEnded: { generation in await bridge.sessionEnded(bindingGenerationId: generation) })
    }

    func bindConversation(_ conversation: String) async throws -> SessionsBindingRecord {
        let committed = try await ingestion.submitHook(
            .init(
                paneId: paneId.uuid, providerIdentifier: provider.identifier, providerVersion: provider.version,
                sessionId: conversation, eventName: .sessionStart, turnId: nil, signal: .sessionStart,
                recordId: UUIDv7.generate(), admittedAt: time.now))
        return committed.binding
    }

    func applyHook(
        _ binding: SessionsBindingRecord, eventName: SessionProviderSignalName, signal: SessionProviderSignal
    ) async throws {
        _ = try await ingestion.submitHook(
            .init(
                paneId: paneId.uuid, providerIdentifier: provider.identifier,
                providerVersion: provider.version, sessionId: binding.providerConversationId, eventName: eventName,
                turnId: "turn", signal: signal, recordId: UUIDv7.generate(), admittedAt: time.now))
    }

    func sender(_ binding: SessionsBindingRecord) throws -> AgentMessageSender {
        .session(
            provider: try BridgeAgentProviderName(binding.providerIdentifier),
            sessionRef: try BridgeAgentSessionRef(binding.providerConversationId),
            bindingGeneration: binding.bindingGenerationId)
    }

    func ask(writer: AgentMessageSender, reason: AskReason) -> PaneMessageSendRequest {
        .init(
            paneId: paneId, messageId: .generateUUIDv7(), sender: writer, sourceOccurredAt: nil, importance: .attention,
            body: "Choose a response", why: nil, actions: [],
            shape: .ask(reason: reason, form: .freeText(placeholder: nil), waiting: .nonBlocking))
    }

    func epoch(writer: AgentMessageSender, stream: PaneWriteStream) async throws -> UInt64 {
        let result = await service.claimEpoch(
            .init(paneId: paneId, writer: writer, stream: stream, claimId: UUIDv7.generate()))
        let epoch: UInt64?
        if case .claimed(let value) = result { epoch = value } else { epoch = nil }
        return try #require(epoch, "Expected real epoch claim, got \(result)")
    }

    func detail() async throws -> PaneContextDetail {
        let result = await service.readDetail(.init(paneId: paneId, page: .first))
        let detail: PaneContextDetail?
        if case .detail(let value) = result { detail = value } else { detail = nil }
        return try #require(detail, "Expected real detail, got \(result)")
    }

    func close() async throws {
        await service.stop()
        await ingestion.finish()
        try await withoutBlockingCooperativePool { [pool, root] in
            try pool.close()
            try FileManager.default.removeItem(at: root)
        }
    }
}

func withPaneContextSessionsBridge(
    ingestionProbe: @escaping SessionsIngestionProbe = { _ in },
    operation: @Sendable (PaneContextSessionsBridgeFixture) async throws -> Void
)
    async throws
{
    let fixture = try await withoutBlockingCooperativePool {
        try PaneContextSessionsBridgeFixture(ingestionProbe: ingestionProbe)
    }
    do {
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}
