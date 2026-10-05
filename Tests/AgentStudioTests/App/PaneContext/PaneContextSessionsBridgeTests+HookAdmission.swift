import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio

extension PaneContextSessionsBridgeTests {
    @Test("fractional hook admission dates preserve exact prompt observedAt after SQLite restore")
    func fractionalPromptObservationRestoresExactly() async throws {
        let admissionDate = Date(timeIntervalSinceReferenceDate: 821_692_800.1234568)
        let storedDate = Date(timeIntervalSince1970: admissionDate.timeIntervalSince1970)
        #expect(admissionDate != storedDate)
        try await withPaneContextSessionsBridge { fixture in
            let adapter = AgentStudioIPCSessionsAdapter(
                ingestion: fixture.ingestion, providerRegistry: fixture.registry, now: { admissionDate })
            let conversation = UUIDv7.generate().uuidString
            for name in [IPCSessionEventName.sessionStart, .permission] {
                let params = hookParams(fixture: fixture, name: name, conversation: conversation)
                #expect(
                    try await adapter.recordProviderEvent(
                        paneId: fixture.paneId.uuid, params: params, provenance: .matchingPane
                    ).disposition == .admitted)
            }
            let initial = try #require(try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid))
            #expect(initial.providerPrompts.count == 1)
            #expect(initial.providerPrompts.first?.observedAt == storedDate)
            await fixture.ingestion.finish()
            let restored = fixture.makeIngestion()
            fixture.bridge.connect(service: fixture.service, ingestion: restored)
            do {
                let reopened = try await restored.sessionSummary(paneId: fixture.paneId.uuid)
                #expect(reopened == initial)
                #expect(reopened?.providerPrompts.first?.observedAt == storedDate)
                await restored.finish()
            } catch {
                await restored.finish()
                throw error
            }
        }
    }

    @Test("serial replacement End keeps the new ended conversation current through restore")
    func replacementEndKeepsOrderedBindingRevisions() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let previous = try await fixture.bindConversation("previous-conversation")
            let conversation = UUIDv7.generate().uuidString
            let end = hookParams(fixture: fixture, name: .sessionEnd, conversation: conversation)
            let adapter = hookAdapter(fixture: fixture, ingestion: fixture.ingestion)
            #expect(
                try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid, params: end, provenance: .matchingPane
                ).disposition == .admitted)
            let current = try #require(try await fixture.ingestion.snapshot(.pane(fixture.paneId.uuid)).currentBinding)
            #expect(current.providerConversationId == conversation)
            #expect(current.status == .ended)
            #expect(current.bindingGenerationId != previous.bindingGenerationId)
            let retained = try await fixture.ingestion.bindingForProviderConversation(
                paneId: fixture.paneId.uuid, providerIdentifier: fixture.provider.providerIdentifier,
                providerConversationId: previous.providerConversationId)
            #expect(retained?.status == .ended)
            let revisions = try await fixture.sqliteAccess.read { database in
                try Int64.fetchAll(
                    database,
                    sql:
                        "SELECT committed_revision FROM sessions_pane_binding WHERE binding_generation_id IN (?, ?) ORDER BY committed_revision",
                    arguments: [previous.bindingGenerationId.uuidString, current.bindingGenerationId.uuidString])
            }
            #expect(revisions.count == 2)
            #expect(try #require(revisions.first) < #require(revisions.last))
            let operationRevisions = try await fixture.sqliteAccess.read { database in
                try Int64.fetchAll(
                    database,
                    sql:
                        "SELECT commit_revision FROM sessions_operation WHERE outcome_occurrence_id = ? ORDER BY commit_revision",
                    arguments: [end.event.occurrenceId.uuidString])
            }
            #expect(operationRevisions.count == 2)
            #expect(operationRevisions == revisions)
            let ended = try await hookRead(fixture: fixture, ingestion: fixture.ingestion)
            #expect(ended.sourceHealth == .ended)
            #expect(ended.session?.status == .idle(state: .ended))
            let lateStart = hookParams(fixture: fixture, name: .sessionStart, conversation: conversation)
            #expect(
                try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid, params: lateStart, provenance: .matchingPane
                ).disposition == .admitted)
            #expect(try await hookRead(fixture: fixture, ingestion: fixture.ingestion) == ended)
            await fixture.ingestion.finish()
            let restored = fixture.makeIngestion()
            fixture.bridge.connect(service: fixture.service, ingestion: restored)
            do {
                #expect(try await restored.snapshot(.pane(fixture.paneId.uuid)).currentBinding == current)
                #expect(try await hookRead(fixture: fixture, ingestion: restored) == ended)
                await restored.finish()
            } catch {
                await restored.finish()
                throw error
            }
        }
    }

    @Test(
        "concurrent first hooks resolve one generation inside the held writer",
        arguments: FirstHookRaceSchedule.allCases)
    func concurrentFirstHooksRemainEnded(schedule: FirstHookRaceSchedule) async throws {
        let scope = UUIDv7.generate()
        let facts = LocalFactSource<UUID, Int>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String($0) }, isClosing: { _, _ in false }))
        let recorder = try facts.attach()
        let held = HeldStep<Void>("first qualified hook before its serialized transaction")
        do {
            try await withPaneContextSessionsBridge(
                ingestionProbe: { observation in
                    if observation.event == .depthChanged, observation.pendingForPane >= 2 {
                        facts.sink(scope, observation.pendingForPane)
                    }
                },
                operation: { fixture in
                    let adapter = hookAdapter(fixture: fixture, ingestion: fixture.ingestion)
                    #expect(try await fixture.ingestion.readSessionStatus(paneId: fixture.paneId.uuid) == .unbound)
                    let conversation = UUIDv7.generate().uuidString
                    let names: [IPCSessionEventName] =
                        switch schedule {
                        case .endBeforeStaleBind: [.sessionEnd, .sessionStart]
                        case .endMappedBeforeReplacement: [.toolActivity, .sessionEnd, .toolActivity]
                        }
                    let requests = names.map { hookParams(fixture: fixture, name: $0, conversation: conversation) }
                    var pending: [HookSubmissionTask] = []
                    await fixture.sqliteAccess.holdNextWrite(held)
                    let first = requests[0]
                    pending.append(startHookSubmission(adapter: adapter, fixture: fixture, params: first))
                    do {
                        try await held.firstArrival()
                        // Both inputs exist while the real database still has no
                        // generation. Neither may pre-generate one from this state.
                        #expect(try await fixture.ingestion.snapshot(.pane(fixture.paneId.uuid)).currentBinding == nil)
                        let second = requests[1]
                        pending.append(startHookSubmission(adapter: adapter, fixture: fixture, params: second))
                        try await recorder.expectNext(in: scope, 2)
                        #expect(try await fixture.ingestion.snapshot(.pane(fixture.paneId.uuid)).currentBinding == nil)
                        if schedule == .endMappedBeforeReplacement {
                            // End is already queued before the competing first
                            // activity could replace its mapped generation.
                            let third = requests[2]
                            pending.append(startHookSubmission(adapter: adapter, fixture: fixture, params: third))
                            try await recorder.expectNext(in: scope, 3)
                        }
                        held.release()
                        for task in pending {
                            let result = await task.value
                            #expect(try result.get().disposition == .admitted)
                        }
                        try await assertEndedHooksAndRestore(
                            fixture: fixture, conversation: conversation, requests: requests)
                    } catch {
                        held.retire()
                        for task in pending {
                            if case .failure(let taskError) = await task.value {
                                Issue.record("Hook submission failed while joining: \(taskError)")
                            }
                        }
                        throw error
                    }
                })
            try await recorder.finish()
        } catch {
            held.retire()
            try? await recorder.finish()
            throw error
        }
    }

    @Test("a conflicting original hook cannot imply a replacement", arguments: HookConflictIdentity.allCases)
    func conflictingHookLeavesEveryEffectUnchanged(identity: HookConflictIdentity) async throws {
        try await withPaneContextSessionsBridge { fixture in
            let adapter = hookAdapter(fixture: fixture, ingestion: fixture.ingestion)
            let binding = try await fixture.bindConversation("current-conversation")
            let original = hookParams(
                fixture: fixture, name: .toolActivity, conversation: binding.providerConversationId)
            #expect(
                try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid, params: original, provenance: .matchingPane
                ).disposition == .admitted)
            let ask = PaneMessageSendRequest(
                paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: try fixture.sender(binding),
                sourceOccurredAt: nil, importance: .attention, body: "Remain open across the refusal", why: nil,
                actions: [],
                shape: .ask(
                    reason: .approval, form: .freeText(placeholder: nil),
                    waiting: .blocking(deadline: fixture.time.now.addingTimeInterval(60))))
            #expect(await fixture.service.send(ask) == .created(ask.messageId))
            let writer = try fixture.sender(binding)
            let answeredAsk = fixture.ask(writer: writer, reason: .question)
            #expect(await fixture.service.send(answeredAsk) == .created(answeredAsk.messageId))
            #expect(
                await fixture.service.answer(
                    .init(
                        messageId: answeredAsk.messageId, paneId: fixture.paneId,
                        by: .localUser, value: .text("retain this receipt"))) == .answered)
            let epoch = try await fixture.epoch(writer: writer, stream: .line)
            #expect(
                await fixture.service.setLine(
                    .init(
                        paneId: fixture.paneId, writer: writer,
                        line: .init(
                            summary: "Keep this live", work: .monitoring("checks"), detail: nil,
                            refs: [], lifetime: .untilReplaced),
                        writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
            let beforeSnapshot = try await fixture.ingestion.snapshot(.pane(fixture.paneId.uuid))
            let beforeRead = try await hookRead(fixture: fixture, ingestion: fixture.ingestion)
            let beforeDetail = try await fixture.detail()
            #expect(beforeDetail.agentLine?.stale == false)
            #expect(
                beforeDetail.messages.first { $0.id == answeredAsk.messageId }?.shape
                    == .ask(
                        .question, .freeText(placeholder: nil), .nonBlocking,
                        .answered(by: .localUser, value: .text("retain this receipt"), receipt: .notYetConfirmed)))
            let beforeRows = try await hookEffectRows(fixture)
            let conflict = hookParams(
                fixture: fixture, name: .toolActivity, conversation: "never-bound-conflict",
                occurrence: identity == .occurrence ? original.event.occurrenceId : UUIDv7.generate(),
                correlation: identity == .correlation ? original.correlationId : UUIDv7.generate())
            await #expect(throws: AppIPCSessionsError(reason: .correlationConflict)) {
                _ = try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid, params: conflict, provenance: .matchingPane)
            }
            #expect(try await fixture.ingestion.snapshot(.pane(fixture.paneId.uuid)) == beforeSnapshot)
            #expect(try await hookRead(fixture: fixture, ingestion: fixture.ingestion) == beforeRead)
            #expect(try await fixture.detail() == beforeDetail)
            #expect(try await hookEffectRows(fixture) == beforeRows)
            #expect(
                try await fixture.ingestion.bindingForProviderConversation(
                    paneId: fixture.paneId.uuid, providerIdentifier: fixture.provider.providerIdentifier,
                    providerConversationId: "never-bound-conflict") == nil)
            let retained = try await fixture.ingestion.bindingForProviderConversation(
                paneId: fixture.paneId.uuid, providerIdentifier: fixture.provider.providerIdentifier,
                providerConversationId: binding.providerConversationId)
            #expect(retained == binding)
            let replay = IPCSessionEventParams(
                handle: original.handle, provider: original.provider, event: original.event,
                correlationId: UUIDv7.generate())
            #expect(
                try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid, params: replay, provenance: .matchingPane
                ).disposition == .admitted)
            #expect(try await hookRead(fixture: fixture, ingestion: fixture.ingestion) == beforeRead)
            #expect(try await fixture.detail() == beforeDetail)
        }
    }
}

enum FirstHookRaceSchedule: CaseIterable, Equatable, Sendable { case endBeforeStaleBind, endMappedBeforeReplacement }
enum HookConflictIdentity: CaseIterable, Equatable, Sendable { case occurrence, correlation }

private typealias HookSubmissionTask = Task<Result<IPCSessionEventResult, any Error>, Never>

private func startHookSubmission(
    adapter: AgentStudioIPCSessionsAdapter, fixture: PaneContextSessionsBridgeFixture, params: IPCSessionEventParams
) -> HookSubmissionTask {
    Task {
        do {
            return .success(
                try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid, params: params, provenance: .matchingPane))
        } catch {
            return .failure(error)
        }
    }
}

private func assertEndedHooksAndRestore(
    fixture: PaneContextSessionsBridgeFixture, conversation: String, requests: [IPCSessionEventParams]
) async throws {
    let adapter = hookAdapter(fixture: fixture, ingestion: fixture.ingestion)
    let binding = try #require(
        try await fixture.ingestion.bindingForProviderConversation(
            paneId: fixture.paneId.uuid, providerIdentifier: fixture.provider.providerIdentifier,
            providerConversationId: conversation))
    #expect(binding.status == .ended)
    let counts = try await fixture.sqliteAccess.read { database in
        (
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_pane_binding"),
            try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM sessions_source WHERE status = 'ended'")
        )
    }
    #expect(counts.0 == 1)
    #expect(counts.1 == 1)
    let beforeLateStart = try await hookRead(fixture: fixture, ingestion: fixture.ingestion)
    #expect(beforeLateStart.sourceHealth == .ended)
    #expect(beforeLateStart.session?.status == .idle(state: .ended))
    let lateStart = hookParams(fixture: fixture, name: .sessionStart, conversation: conversation)
    #expect(
        try await adapter.recordProviderEvent(
            paneId: fixture.paneId.uuid, params: lateStart, provenance: .matchingPane
        ).disposition == .admitted)
    #expect(try await hookRead(fixture: fixture, ingestion: fixture.ingestion) == beforeLateStart)
    for request in requests {
        #expect(
            try await adapter.recordProviderEvent(
                paneId: fixture.paneId.uuid, params: request, provenance: .matchingPane
            ).disposition == .admitted)
    }
    #expect(try await hookRead(fixture: fixture, ingestion: fixture.ingestion) == beforeLateStart)
    await fixture.ingestion.finish()
    let restored = fixture.makeIngestion()
    fixture.bridge.connect(service: fixture.service, ingestion: restored)
    do {
        #expect(try await hookRead(fixture: fixture, ingestion: restored) == beforeLateStart)
        let restoredAdapter = hookAdapter(fixture: fixture, ingestion: restored)
        #expect(
            try await restoredAdapter.recordProviderEvent(
                paneId: fixture.paneId.uuid, params: lateStart, provenance: .matchingPane
            ).disposition == .admitted)
        #expect(try await hookRead(fixture: fixture, ingestion: restored) == beforeLateStart)
        let after = try await restored.bindingForProviderConversation(
            paneId: fixture.paneId.uuid, providerIdentifier: fixture.provider.providerIdentifier,
            providerConversationId: conversation)
        #expect(after == binding)
        await restored.finish()
    } catch {
        await restored.finish()
        throw error
    }
}

private func hookAdapter(fixture: PaneContextSessionsBridgeFixture, ingestion: SessionsIngestion)
    -> AgentStudioIPCSessionsAdapter
{
    AgentStudioIPCSessionsAdapter(ingestion: ingestion, providerRegistry: fixture.registry, now: { fixture.time.now })
}

private func hookParams(
    fixture: PaneContextSessionsBridgeFixture, name: IPCSessionEventName, conversation: String,
    occurrence: UUID = UUIDv7.generate(), correlation: UUID = UUIDv7.generate()
) -> IPCSessionEventParams {
    var fields = IPCSessionProviderEventFields()
    fields.sourceOccurredAt = fixture.time.now.addingTimeInterval(-10)
    return .init(
        handle: fixture.paneId.uuidString,
        provider: .init(
            identifier: fixture.provider.providerIdentifier, version: fixture.provider.exactVersion,
            mode: fixture.provider.operatingMode),
        event: .init(
            name: name, conversationId: conversation, turnId: "race-turn", requestId: nil,
            toolId: nil, subagentId: nil, occurrenceId: occurrence, providerFields: fields),
        correlationId: correlation)
}

private func hookRead(fixture: PaneContextSessionsBridgeFixture, ingestion: SessionsIngestion) async throws
    -> IPCSessionQueryResult
{
    let query = try await hookAdapter(fixture: fixture, ingestion: ingestion).readSessionState(
        paneId: fixture.paneId.uuid, params: .init(handle: fixture.paneId.uuidString))
    let detail = try await AgentStudioIPCPaneContextAdapter(service: fixture.service, ingestion: ingestion).readContext(
        paneId: fixture.paneId.uuid, params: .init(handle: fixture.paneId.uuidString, page: .first),
        replyEnvelopeOverheadBytes: 128)
    #expect(detail.session == query.session)
    return query
}

private func hookEffectRows(_ fixture: PaneContextSessionsBridgeFixture) async throws -> [String: [String]] {
    try await fixture.sqliteAccess.read { database in
        var rows: [String: [String]] = [:]
        for table in [
            "sessions_conversation", "sessions_operation", "sessions_pane_binding", "sessions_source",
            "sessions_evidence", "sessions_attention", "sessions_result", "pane_state", "pane_request", "pane_event",
        ] {
            rows[table] = try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY rowid").map {
                String(describing: $0)
            }
        }
        return rows
    }
}
