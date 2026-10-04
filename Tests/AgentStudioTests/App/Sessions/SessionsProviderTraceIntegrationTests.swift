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
    @Test("a keyed hook records source time and a later source time replays without a second effect")
    func keyedHookSourceTimeIsRecordedButNotCanonicalIntent() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        let projected = try projectRecordedStatus(data: recordedStatusData("AskUserQuestion.PreToolUse"))
        let event = projected.event
        let firstTime = Date(timeIntervalSince1970: 1_700_000_000)
        let laterTime = firstTime.addingTimeInterval(1)
        func params(at sourceTime: Date) -> IPCSessionEventParams {
            var fields = event.providerFields
            fields.sourceOccurredAt = sourceTime
            return .init(
                handle: projected.handle, provider: projected.provider,
                event: .init(
                    name: event.name, conversationId: event.conversationId, turnId: event.turnId,
                    requestId: event.requestId, toolId: event.toolId, subagentId: event.subagentId,
                    occurrenceId: event.occurrenceId, providerFields: fields), correlationId: UUIDv7.generate())
        }
        let first = params(at: firstTime)
        let replay = params(at: laterTime)
        #expect(first.event.occurrenceId == replay.event.occurrenceId)
        #expect(first.event.sourceOccurredAt != replay.event.sourceOccurredAt)
        #expect(first.correlationId != replay.correlationId)
        try await fixture.withIngestion { ingestion, adapter in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            let firstResult = try await adapter.recordProviderEvent(
                paneId: paneId, params: first, provenance: .matchingPane)
            #expect(firstResult.disposition == .admitted)
            let before = try await ingestion.sessionSummary(paneId: paneId)
            let replayResult = try await adapter.recordProviderEvent(
                paneId: paneId, params: replay, provenance: .matchingPane)
            #expect(replayResult.disposition == .admitted)
            let after = try await ingestion.sessionSummary(paneId: paneId)
            #expect(after == before)
        }
        let databaseURL = fixture.databaseURL
        let stored = try await valueFromDedicatedThread {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { database in
                let count = try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM sessions_evidence WHERE occurrence_id = ?",
                    arguments: [event.occurrenceId.uuidString])
                let sourceTime = try Double.fetchOne(
                    database, sql: "SELECT source_occurred_at FROM sessions_evidence WHERE occurrence_id = ?",
                    arguments: [event.occurrenceId.uuidString])
                return (count, sourceTime)
            }
        }
        #expect(stored.0 == 1)
        #expect(stored.1 == firstTime.timeIntervalSince1970)
    }
    @Test(
        "populated supplied and fallback resume hints survive repository reopen and occurrence replay",
        arguments: [true, false])
    func resumeHintPersistsAcrossReopenAndReplay(useSuppliedHint: Bool) async throws {
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
        let query = SessionsSnapshotQuery(paneId: paneId, page: .init(limit: 100, after: nil))
        let initial = try await fixture.withIngestion { ingestion, adapter in
            let result = try await adapter.recordProviderEvent(paneId: paneId, params: start, provenance: .matchingPane)
            #expect(result.disposition == .admitted)
            let snapshot = try await ingestion.snapshot(query)
            let binding = try #require(snapshot.currentBinding)
            #expect(binding.resumeHint == expectedHint)
            return snapshot
        }
        try await fixture.withIngestion { ingestion, adapter in
            let reopened = try await ingestion.snapshot(query)
            #expect(reopened.currentBinding == initial.currentBinding)
            #expect(try #require(reopened.currentBinding).resumeHint == expectedHint)
            let replay = IPCSessionEventParams(
                handle: start.handle, provider: start.provider, event: start.event, correlationId: UUIDv7.generate())
            #expect(replay.correlationId != start.correlationId)
            let result = try await adapter.recordProviderEvent(
                paneId: paneId, params: replay, provenance: .matchingPane)
            #expect(result.disposition == .admitted)
            let afterReplay = try await ingestion.snapshot(query)
            #expect(afterReplay.currentBinding == initial.currentBinding)
            #expect(try #require(afterReplay.currentBinding).resumeHint == expectedHint)
            // Correlation aliases advance the operation ledger, not the domain state.
            #expect(afterReplay.state == initial.state)
            #expect(afterReplay.stateOrigin == initial.stateOrigin)
            #expect(afterReplay.messages == initial.messages)
            #expect(afterReplay.currentAttention == initial.currentAttention)
            #expect(afterReplay.staleAttention == initial.staleAttention)
            #expect(afterReplay.results == initial.results)
            #expect(Set(afterReplay.historicalOccurrenceIds) == Set(initial.historicalOccurrenceIds))
            #expect(afterReplay.losses == initial.losses)
        }
    }

    @Test(
        "discarded provider schema, answer and server metadata do not change canonical replay",
        arguments: ["Elicitation", "ElicitationResult"])
    func discardedElicitationMetadataReplays(fixtureName: String) async throws {
        try await withRecordedStatusIngestion { ingestion, adapter, paneId in
            try await sendRecordedStatus("Elicitation.SessionStart", adapter: adapter, paneId: paneId)
            let occurrenceId = UUIDv7.generate()
            let captured = try recordedStatusData(fixtureName)
            let first = try projectRecordedStatus(data: captured, occurrenceId: occurrenceId)
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: first, provenance: .matchingPane)
            let before = try await ingestion.sessionSummary(paneId: paneId)
            guard case .object(var changed) = try JSONDecoder().decode(JSONValue.self, from: captured) else {
                throw ClaudeCodeHookInvocationError.reportRejected
            }
            changed["mcp_server_name"] = .string("different-discarded-server")
            if fixtureName == "Elicitation" {
                changed["requested_schema"] = .object([
                    "type": .string("object"), "title": .string("A different discarded form"),
                ])
            } else {
                changed["content"] = .object(["color": .string("a different discarded answer")])
                changed["action"] = .string("cancel")
            }
            let replay = try projectRecordedStatus(
                data: JSONEncoder().encode(JSONValue.object(changed)), occurrenceId: occurrenceId)
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: replay, provenance: .matchingPane)
            #expect(try await ingestion.sessionSummary(paneId: paneId) == before)
        }
    }

    @Test("a lifecycle occurrence replays across correlations and rejects changed canonical intent")
    func sessionEndReplaysBySuppliedOccurrence() async throws {
        try await withRecordedStatusIngestion { ingestion, adapter, paneId in
            try await sendRecordedStatus("Elicitation.SessionStart", adapter: adapter, paneId: paneId)
            let occurrenceId = UUIDv7.generate()
            let capturedEnd = try recordedStatusData("Elicitation.SessionEnd")
            let end = try projectRecordedStatus(data: capturedEnd, occurrenceId: occurrenceId)
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: end, provenance: .matchingPane)
            let ended = try await ingestion.sessionSummary(paneId: paneId)
            #expect(ended?.status == .idle(.ended))
            let replay = IPCSessionEventParams(
                handle: end.handle, provider: end.provider, event: end.event, correlationId: UUIDv7.generate())
            _ = try await adapter.recordProviderEvent(paneId: paneId, params: replay, provenance: .matchingPane)
            #expect(try await ingestion.sessionSummary(paneId: paneId) == ended)
            guard case .object(var changed) = try JSONDecoder().decode(JSONValue.self, from: capturedEnd) else {
                throw ClaudeCodeHookInvocationError.reportRejected
            }
            changed["prompt_id"] = .string("different-recorded-turn")
            let changedEnd = try projectRecordedStatus(
                data: JSONEncoder().encode(JSONValue.object(changed)), occurrenceId: occurrenceId)
            await #expect(throws: AppIPCSessionsError(reason: .correlationConflict)) {
                _ = try await adapter.recordProviderEvent(paneId: paneId, params: changedEnd, provenance: .matchingPane)
            }
            #expect(try await ingestion.sessionSummary(paneId: paneId) == ended)
        }
    }

    @Test("a changed projected question conflicts, while changed discarded duration replays")
    func replayUsesRecordedCanonicalContent() async throws {
        try await withRecordedStatusIngestion { ingestion, adapter, paneId in
            try await sendRecordedStatus("AskUserQuestion.SessionStart", adapter: adapter, paneId: paneId)
            try await sendRecordedStatus("AskUserQuestion.PreToolUse", adapter: adapter, paneId: paneId)
            let before = try await ingestion.sessionSummary(paneId: paneId)
            let original = try recordedStatusData("AskUserQuestion.PreToolUse")
            guard case .object(var changed) = try JSONDecoder().decode(JSONValue.self, from: original),
                case .object(var input)? = changed["tool_input"], case .array(var questions)? = input["questions"],
                case .object(var firstQuestion)? = questions.first
            else { throw ClaudeCodeHookInvocationError.reportRejected }
            firstQuestion["question"] = .string("A different projected question.")
            questions[0] = .object(firstQuestion)
            input["questions"] = .array(questions)
            changed["tool_input"] = .object(input)
            let changedData = try JSONEncoder().encode(JSONValue.object(changed))
            await #expect(throws: AppIPCSessionsError(reason: .correlationConflict)) {
                try await submitRecordedStatus(data: changedData, adapter: adapter, paneId: paneId)
            }
            #expect(try await ingestion.sessionSummary(paneId: paneId) == before)
            try await sendRecordedStatus("AskUserQuestion.PostToolUse", adapter: adapter, paneId: paneId)
            let completed = try await ingestion.sessionSummary(paneId: paneId)
            guard
                case .object(var discardedChange) = try JSONDecoder().decode(
                    JSONValue.self, from: recordedStatusData("AskUserQuestion.PostToolUse"))
            else {
                throw ClaudeCodeHookInvocationError.reportRejected
            }
            discardedChange["duration_ms"] = .number(777)
            try await submitRecordedStatus(
                data: JSONEncoder().encode(JSONValue.object(discardedChange)), adapter: adapter, paneId: paneId)
            #expect(try await ingestion.sessionSummary(paneId: paneId) == completed)
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

private struct RecordedStatusDatabase: Sendable {
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
            ingestion: ingestion, providerRegistry: .init(profiles: [.claudeCodeCommandLine]))
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

private func sendRecordedStatus(_ fixtureName: String, adapter: AgentStudioIPCSessionsAdapter, paneId: UUID)
    async throws
{
    try await submitRecordedStatus(data: recordedStatusData(fixtureName), adapter: adapter, paneId: paneId)
}

private func recordedStatusData(_ fixtureName: String) throws -> Data {
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

private func projectRecordedStatus(data: Data, occurrenceId: UUID = UUIDv7.generate()) throws -> IPCSessionEventParams {
    let payload = try JSONDecoder().decode(ClaudeCodeHookPayload.self, from: data)
    let projection = ClaudeCodeHookProjection.project(
        announcedEvent: payload.hookEventName, payload: payload, providerVersion: "2.1.286",
        correlationIdentifier: UUIDv7.generate(), freshOccurrenceIdentifier: { occurrenceId })
    guard case .projected(let params) = projection else { throw ClaudeCodeHookInvocationError.reportRejected }
    return params
}
