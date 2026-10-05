import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio

@Suite("Sessions recorded provider trace integration")
struct SessionsProviderTraceIntegrationTests {

    @Test(
        "supplied and fallback resume hints survive repository reopen and later SessionStart",
        arguments: [true, false])
    func resumeHintPersistsAcrossReopenAndStart(useSuppliedHint: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        let projected = try projectRecordedStatus(data: recordedStatusData("SessionStart"))
        let event = projected.event
        let suppliedHint = "claude --resume supplied-conversation --verbose"
        let expectedHint = useSuppliedHint ? suppliedHint : "claude --resume \(event.conversationId)"
        var providerFields = event.providerFields
        providerFields.resumeHint = useSuppliedHint ? suppliedHint : nil
        let start = IPCSessionEventParams(
            handle: projected.handle, provider: projected.provider,
            event: .init(
                name: event.name, conversationId: event.conversationId, turnId: event.turnId,
                requestId: event.requestId, toolId: event.toolId, subagentId: event.subagentId,
                occurrenceId: event.occurrenceId, providerFields: providerFields),
            correlationId: projected.correlationId)
        let query = SessionsSnapshotQuery(paneId: paneId)
        let initial = try await fixture.withIngestion { ingestion, adapter in
            let result = try await adapter.recordProviderEvent(paneId: paneId, params: start, provenance: .matchingPane)
            #expect(result.disposition == .admitted)
            let snapshot = try await ingestion.snapshot(query)
            let binding = try #require(snapshot.currentBinding)
            #expect(binding.resumeHint == expectedHint)
            return (snapshot: snapshot, summary: try await ingestion.sessionSummary(paneId: paneId))
        }
        try await fixture.withIngestion { ingestion, adapter in
            let reopened = try await ingestion.snapshot(query)
            #expect(reopened.currentBinding == initial.snapshot.currentBinding)
            #expect(try #require(reopened.currentBinding).resumeHint == expectedHint)
            let replay = IPCSessionEventParams(
                handle: start.handle, provider: start.provider, event: start.event, correlationId: UUIDv7.generate())
            #expect(replay.correlationId != start.correlationId)
            let result = try await adapter.recordProviderEvent(
                paneId: paneId, params: replay, provenance: .matchingPane)
            #expect(result.disposition == .admitted)
            let afterReplay = try await ingestion.snapshot(query)
            #expect(afterReplay.currentBinding == initial.snapshot.currentBinding)
            #expect(try #require(afterReplay.currentBinding).resumeHint == expectedHint)
            let replaySummary = try await ingestion.sessionSummary(paneId: paneId)
            #expect(replaySummary == initial.summary)
            // Another invocation records a new fact while preserving the active binding.
            #expect(afterReplay.staleAttention == initial.snapshot.staleAttention)
            #expect(afterReplay.results == initial.snapshot.results)
            #expect(Set(afterReplay.historicalOccurrenceIds) == Set(initial.snapshot.historicalOccurrenceIds))
            #expect(afterReplay.losses == initial.snapshot.losses)
        }
    }

    @Test("the captured question, permission and completion drive the real Sessions state")
    func questionRoundTripThroughAdapterAndSQLite() async throws {
        try await withRecordedStatusIngestion { ingestion, adapter, paneId in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            try await sendRecordedStatus("AskUserQuestion.PreToolUse", adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.status == .needsYou(.question))
            try await sendRecordedStatus("AskUserQuestion.PermissionRequest", adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.providerPrompts.count == 1)
            try await sendRecordedStatus("AskUserQuestion.PostToolUse", adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.status == .working(.active))
            try await sendRecordedStatus("Stop", adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.status == .idle(.done))
        }
    }

    @Test("the captured no-ID elicitation result remains open until its captured session end")
    func noIdElicitationRoundTrip() async throws {
        try await withRecordedStatusIngestion { ingestion, adapter, paneId in
            try await sendRecordedStatus("Elicitation.SessionStart", adapter: adapter, paneId: paneId)
            try await sendRecordedStatus("Elicitation", adapter: adapter, paneId: paneId)
            try await sendRecordedStatus("ElicitationResult", adapter: adapter, paneId: paneId)
            let waiting = try await ingestion.sessionSummary(paneId: paneId)
            #expect(waiting?.status == .needsYou(.question))
            #expect(waiting?.providerPrompts.count == 1)
            try await sendRecordedStatus("Elicitation.SessionEnd", adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.status == .idle(.ended))
        }
    }

    @Test("captured StopFailure stores and derives its error category")
    func failureCategoryThroughAdapter() async throws {
        try await withRecordedStatusIngestion { ingestion, adapter, paneId in
            try await sendRecordedStatus("SessionStart", adapter: adapter, paneId: paneId)
            try await sendRecordedStatus("UserPromptSubmit", adapter: adapter, paneId: paneId)
            try await sendRecordedStatus("StopFailure", adapter: adapter, paneId: paneId)
            #expect(
                try await ingestion.sessionSummary(paneId: paneId)?.status
                    == .failed(.init(category: "authentication_failed")))
        }
    }

    @Test("typed question rows restore the same prompt after closing and reopening the SQLite owner")
    func providerQuestionPersistsWithoutJSON() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        let initial = try await fixture.withIngestion { ingestion, adapter in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            try await sendRecordedStatus("AskUserQuestion.PreToolUse", adapter: adapter, paneId: paneId)
            return try await ingestion.sessionSummary(paneId: paneId)
        }
        let reopened = try await fixture.withIngestion { ingestion, adapter in
            #expect(try await ingestion.sessionSummary(paneId: paneId) == initial)
            try await sendRecordedStatus("AskUserQuestion.PermissionRequest", adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.providerPrompts.count == 1)
            try await sendRecordedStatus("AskUserQuestion.PostToolUse", adapter: adapter, paneId: paneId)
            return try await ingestion.sessionSummary(paneId: paneId)
        }
        #expect(reopened?.status == .working(.active))
    }

    @Test("the sequenced ask port wins after an ended binding and ignores delayed summaries")
    func openAsksJoinTheirOwnBinding() async throws {
        try await withRecordedStatusIngestion { ingestion, adapter, paneId in
            try await sendRecordedStatus("Elicitation.SessionStart", adapter: adapter, paneId: paneId)
            let generation = try #require(try await ingestion.sessionSummary(paneId: paneId)?.bindingGeneration)
            await ingestion.receiveOpenAskSummary(
                .init(
                    bindingGenerationId: generation, summary: .init(sequence: 1, approval: 1, question: 0, blocked: 0)))
            try await sendRecordedStatus("Elicitation.SessionEnd", adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.status == .needsYou(.approval))
            await ingestion.receiveOpenAskSummary(
                .init(
                    bindingGenerationId: generation, summary: .init(sequence: 2, approval: 0, question: 0, blocked: 0)))
            await ingestion.receiveOpenAskSummary(
                .init(
                    bindingGenerationId: generation, summary: .init(sequence: 1, approval: 1, question: 0, blocked: 0)))
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.status == .idle(.ended))
        }
    }
}

struct RecordedStatusDatabase: Sendable {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "agentstudio-recorded-status-\(UUIDv7.generate())")
        databaseURL = root.appending(path: "local.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func withIngestion<Output: Sendable>(
        operation: @Sendable (SessionsIngestion, AgentStudioIPCSessionsAdapter) async throws -> Output
    ) async throws -> Output {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try WorkspaceLocalMigrations.migrate(queue)
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: RecordedStatusSQLiteAccess(queue: queue)),
            limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in })
        let adapter = AgentStudioIPCSessionsAdapter(
            ingestion: ingestion)
        do {
            let result = try await operation(ingestion, adapter)
            await ingestion.finish()
            return result
        } catch {
            await ingestion.finish()
            throw error
        }
    }
}

private struct RecordedStatusSQLiteAccess: SessionsSQLiteAccess {
    let queue: DatabaseQueue
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await queue.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await queue.write(operation)
    }
}

private func withRecordedStatusIngestion(
    operation: @Sendable (SessionsIngestion, AgentStudioIPCSessionsAdapter, UUID) async throws -> Void
) async throws {
    let fixture = try RecordedStatusDatabase()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.withIngestion { ingestion, adapter in try await operation(ingestion, adapter, UUIDv7.generate()) }
}

func sendRecordedStatus(_ fixtureName: String, adapter: AgentStudioIPCSessionsAdapter, paneId: UUID)
    async throws
{
    try await submitRecordedStatus(data: recordedStatusData(fixtureName), adapter: adapter, paneId: paneId)
}

func recordedStatusData(_ fixtureName: String) throws -> Data {
    let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(
        contentsOf: repositoryRoot.appending(
            path: "Tests/AgentStudioIPCClientTests/Fixtures/claude-code-2.1.286/\(fixtureName).json"))
}

private func submitRecordedStatus(data: Data, adapter: AgentStudioIPCSessionsAdapter, paneId: UUID) async throws {
    let params = try projectRecordedStatus(data: data)
    let result = try await adapter.recordProviderEvent(paneId: paneId, params: params, provenance: .matchingPane)
    #expect(result.disposition == .admitted)
}

func projectRecordedStatus(data: Data, occurrenceId: UUID = UUIDv7.generate()) throws -> IPCSessionEventParams {
    let payload = try JSONDecoder().decode(ClaudeCodeHookPayload.self, from: data)
    let projection = ClaudeCodeHookProjection.project(
        announcedEvent: payload.hookEventName, payload: payload, providerVersion: "2.1.286",
        correlationIdentifier: UUIDv7.generate(), freshOccurrenceIdentifier: { occurrenceId })
    guard case .projected(let params) = projection else { throw ClaudeCodeHookInvocationError.reportRejected }
    return params
}
