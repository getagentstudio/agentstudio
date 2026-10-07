import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionsProviderTraceIntegrationTests {
    @Test("refusal on a bound pane preserves session status and evidence")
    func boundRefusalHasNoStatusEffect() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = UUIDv7.generate()
        try await fixture.withIngestion { ingestion, adapter in
            _ = try await adapter.recordProviderEvent(
                paneId: pane,
                params: .init(
                    handle: "self", provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
                    event: .init(
                        name: .toolActivity, conversationId: "bound", turnId: "turn", requestId: nil,
                        toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                    correlationId: UUIDv7.generate()), provenance: .matchingPane)
            let before = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
            _ = try await adapter.recordRefusal(
                paneId: pane, params: .init(handle: "self", reason: .noSessionId, correlationId: UUIDv7.generate()),
                provenance: .matchingPane)
            let after = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
            #expect(after.session == before.session)
            #expect(after.sourceHealth == before.sourceHealth)
            #expect(after.lastRefusal?.reason == .noSessionId)
            let context = try await ingestion.repository.statusContext(paneId: pane)
            #expect(context.evidence.count == 1)
        }
    }

    @Test("adapter refusal overwrites without hook admission and remains readable on an unbound pane")
    func adapterRefusalIsIndependentOfBinding() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = UUIDv7.generate()
        let correlation = UUIDv7.generate()
        try await fixture.withIngestion { ingestion, adapter in
            for reason in [IPCSessionRefusalReason.noSessionId, .undecodablePayload] {
                _ = try await adapter.recordRefusal(
                    paneId: pane,
                    params: .init(handle: "self", reason: reason, event: "SessionStart", correlationId: correlation),
                    provenance: .matchingPane)
            }
            let result = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
            #expect(result.sourceHealth == .unbound)
            #expect(result.session == nil)
            #expect(result.lastRefusal?.reason == .undecodablePayload)
            #expect(result.lastRefusal?.event == "SessionStart")
            let context = try await ingestion.repository.statusContext(paneId: pane)
            #expect(context.bindings.isEmpty)
            #expect(context.evidence.isEmpty)
            await #expect(throws: AppIPCSessionsError.self) {
                try await adapter.recordRefusal(
                    paneId: pane, params: .init(handle: "self", reason: .noSessionId, correlationId: UUIDv7.generate()),
                    provenance: .other)
            }
            let unchanged = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
            #expect(unchanged == result)
        }
        try await fixture.withIngestion { _, adapter in
            let result = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
            #expect(result.lastRefusal == nil)
            #expect(result.sourceHealth == .unbound)
        }
    }

    @Test(
        "full pane and global queues publish queueFull before the adapter returns rejection", arguments: [false, true])
    func adapterQueueRefusalIsSynchronous(global: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queue = try DatabaseQueue(path: fixture.databaseURL.path)
        try WorkspaceLocalMigrations.migrate(queue)
        let held = HeldStep<Void>("first hook write is held before SQLite")
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: RefusalQueueSQLiteAccess(queue: queue, held: held)),
            limits: .init(maximumPendingPerPane: global ? 2 : 1, maximumPendingGlobal: global ? 1 : 2), probe: { _ in })
        let at = Date(timeIntervalSince1970: 1000)
        let adapter = AgentStudioIPCSessionsAdapter(ingestion: ingestion, now: { at })
        let pane = UUIDv7.generate()
        let params = IPCSessionEventParams(
            handle: "self", provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
            event: .init(
                name: .toolActivity, conversationId: "full-queue", turnId: "turn", requestId: nil,
                toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()), correlationId: UUIDv7.generate())
        let first = Task {
            try await adapter.recordProviderEvent(paneId: pane, params: params, provenance: .matchingPane)
        }
        do {
            try await held.firstArrival()
            await #expect(throws: AppIPCSessionsError.self) {
                try await adapter.recordProviderEvent(paneId: pane, params: params, provenance: .matchingPane)
            }
            let result = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
            #expect(result.lastRefusal == .init(reason: .queueFull, event: "toolActivity", at: at))
            #expect(result.sourceHealth == .unbound)
            held.release()
            _ = try await first.value
            let afterCommit = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
            #expect(afterCommit.lastRefusal == result.lastRefusal)
            #expect(afterCommit.sourceHealth == .live)
            await ingestion.finish()
        } catch {
            held.release()
            _ = try? await first.value
            await ingestion.finish()
            throw error
        }
    }
}

private actor RefusalQueueSQLiteAccess: SessionsSQLiteAccess {
    let queue: DatabaseQueue
    let held: HeldStep<Void>
    var holdsNextWrite = true
    init(queue: DatabaseQueue, held: HeldStep<Void>) {
        self.queue = queue
        self.held = held
    }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await queue.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        if holdsNextWrite {
            holdsNextWrite = false
            try await held.arrive(())
        }
        return try await queue.write(operation)
    }
}
