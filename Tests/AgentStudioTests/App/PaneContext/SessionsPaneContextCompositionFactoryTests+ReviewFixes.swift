import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension SessionsPaneContextCompositionFactoryTests {
    @Test(
        "first qualified lifecycle/activity hooks bind before applying and late Starts do not reopen",
        arguments: FirstHookScenario.allCases)
    func firstHookAdmissionAndRestore(scenario: FirstHookScenario) async throws {
        try await withCompositionFactory { fixture in
            let composition = fixture.composition
            _ = try await composition.prepareForLaunch(at: fixture.now)
            var oldBinding: SessionsBindingRecord?
            if scenario == .replacementEnd {
                oldBinding = try await fixture.bind(paneId: fixture.ownerId, usingLateAdapter: false)
            }
            let conversation = UUIDv7.generate().uuidString
            let occurrence = UUIDv7.generate()
            let expected: IPCPaneSessionStatus = scenario == .activity ? .working(state: .active) : .idle(state: .ended)
            let provider = IPCSessionProviderIdentity(
                identifier: ClaudeCodeProviderIdentity.identifier,
                version: ClaudeCodeProviderIdentity.supportedExactVersion,
                mode: ClaudeCodeProviderIdentity.operatingMode)
            var fields = IPCSessionProviderEventFields()
            fields.sourceOccurredAt = fixture.now.addingTimeInterval(-10)
            let first = IPCSessionEventParams(
                handle: fixture.ownerId.uuidString, provider: provider,
                event: .init(
                    name: scenario == .activity ? .toolActivity : .sessionEnd, conversationId: conversation,
                    turnId: "first-turn", requestId: nil, toolId: nil, subagentId: nil, occurrenceId: occurrence,
                    providerFields: fields),
                correlationId: UUIDv7.generate())
            let admitted = try await composition.liveSessionsAdapter.recordProviderEvent(
                paneId: fixture.ownerId.uuid, params: first, provenance: .matchingPane)
            #expect(admitted.disposition == .admitted)
            let before = try await composition.liveSessionsAdapter.readSessionState(
                paneId: fixture.ownerId.uuid, params: .init(handle: fixture.ownerId.uuidString))
            #expect(before.session?.status == expected)
            let binding = try #require(
                try await composition.ingestion.snapshot(.pane(fixture.ownerId.uuid)).currentBinding)
            #expect(binding.transitionOccurrenceId == occurrence)
            #expect(binding.resumeHint == "claude --resume \(conversation)")
            let sourceTime = try await fixture.localPool.read {
                try Double.fetchOne(
                    $0,
                    sql:
                        "SELECT source_occurred_at FROM sessions_operation WHERE operation_kind = 'bind' AND binding_generation_id = ?",
                    arguments: [binding.bindingGenerationId.uuidString])
            }
            #expect(sourceTime == fields.sourceOccurredAt?.timeIntervalSince1970)
            if let oldBinding {
                let retained = try await composition.ingestion.bindingForProviderConversation(
                    paneId: fixture.ownerId.uuid, providerIdentifier: oldBinding.providerIdentifier,
                    providerConversationId: oldBinding.providerConversationId)
                #expect(retained?.status == .ended)
                #expect(retained?.bindingGenerationId != binding.bindingGenerationId)
            }
            fields.resumeHint = "a late provider hint must not write"
            fields.sourceOccurredAt = fixture.now.addingTimeInterval(-20)
            let start = IPCSessionEventParams(
                handle: first.handle, provider: provider,
                event: .init(
                    name: .sessionStart, conversationId: conversation, turnId: nil, requestId: nil,
                    toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate(), providerFields: fields),
                correlationId: UUIDv7.generate())
            let late = try await composition.liveSessionsAdapter.recordProviderEvent(
                paneId: fixture.ownerId.uuid, params: start, provenance: .matchingPane)
            #expect(late.disposition == .admitted)
            let after = try await composition.liveSessionsAdapter.readSessionState(
                paneId: fixture.ownerId.uuid, params: .init(handle: first.handle))
            #expect(after == before)
            let unchanged = try await composition.ingestion.snapshot(.pane(fixture.ownerId.uuid)).currentBinding
            #expect(unchanged == binding)
            let detail = try await composition.paneContextIPCAdapter.readContext(
                paneId: fixture.ownerId.uuid, params: .init(handle: first.handle, page: .first),
                replyEnvelopeOverheadBytes: 128)
            #expect(detail.session == after.session)
            await composition.shutdown()
            let restored = fixture.restartComposition()
            do {
                let reopened = try await restored.liveSessionsAdapter.readSessionState(
                    paneId: fixture.ownerId.uuid, params: .init(handle: first.handle))
                let reopenedDetail = try await restored.paneContextIPCAdapter.readContext(
                    paneId: fixture.ownerId.uuid, params: .init(handle: first.handle, page: .first),
                    replyEnvelopeOverheadBytes: 128)
                #expect(reopened == after)
                #expect(reopenedDetail.session == after.session)
                await restored.shutdown()
            } catch {
                await restored.shutdown()
                throw error
            }
        }
    }

    @Test("the full domain form size agrees with the native tagged IPC encoding for escaping and elicitation framing")
    func formSizeAgreesWithNativeEncoding() throws {
        let text = "Quote \" slash / backslash \\ newline\n漢😀"
        let forms: [AskForm] = [
            .freeText(placeholder: nil), .freeText(placeholder: text),
            .choice(options: [.init(id: try AskChoiceId(text), label: text)], allowsMultiple: false),
            .elicitation(
                .init(
                    properties: [
                        .init(
                            name: text, title: text, description: text,
                            type: .string(.init(choices: [text], minLength: 1, maxLength: 100, format: .email))),
                        .init(
                            name: "count", title: nil, description: nil,
                            type: .number(.init(minimum: 1.25, maximum: 10))),
                        .init(name: "flag", title: nil, description: nil, type: .boolean),
                    ], required: [text])),
        ]
        for form in forms {
            let native = try JSONEncoder().encode(PaneContextIPCMapping.form(form)).count
            let domain = PaneContextAdmission.formBytes(form)
            #expect(domain == native)
        }
    }

    @Test("boot-composed hydration retries a failed persisted ask read on later IPC demand")
    func bootHydrationRetriesFailedAskRead() async throws {
        try await withCompositionFactory { fixture in
            _ = try await fixture.composition.prepareForLaunch(at: fixture.now)
            let binding = try await fixture.bind(paneId: fixture.ownerId, usingLateAdapter: false)
            let askId = AgentMessageId.generateUUIDv7()
            let sent = await fixture.composition.paneContextService.send(
                .init(
                    paneId: fixture.ownerId, messageId: askId, sender: try fixture.sender(binding),
                    sourceOccurredAt: nil, importance: .attention, body: "Persisted approval", why: nil, actions: [],
                    shape: .ask(reason: .approval, form: .freeText(placeholder: nil), waiting: .nonBlocking)))
            #expect(sent == .created(askId))
            await fixture.composition.shutdown()
            try await fixture.localPool.write {
                try $0.execute(
                    sql: "UPDATE pane_request SET reason = 'failed-first-read' WHERE message_id = ?",
                    arguments: [askId.uuid.uuidString])
            }
            let restored = fixture.restartComposition()
            do {
                // The same assembly/prepare path Boot uses reads the malformed
                // summary once; repair storage without sending an ask mutation.
                _ = try await restored.prepareForLaunch(at: fixture.now)
                try await fixture.localPool.write {
                    try $0.execute(
                        sql: "UPDATE pane_request SET reason = 'approval' WHERE message_id = ?",
                        arguments: [askId.uuid.uuidString])
                }
                let queried = try await restored.liveSessionsAdapter.readSessionState(
                    paneId: fixture.ownerId.uuid, params: .init(handle: fixture.ownerId.uuidString))
                let detail = try await restored.paneContextIPCAdapter.readContext(
                    paneId: fixture.ownerId.uuid, params: .init(handle: fixture.ownerId.uuidString, page: .first),
                    replyEnvelopeOverheadBytes: 128)
                #expect(queried.session?.status == .needsYou(reason: .approval))
                #expect(detail.session == queried.session)
                #expect(detail.messages.first?.id == askId.uuid)
                await restored.shutdown()
            } catch {
                await restored.shutdown()
                throw error
            }
        }
    }

}

enum FirstHookScenario: CaseIterable, Equatable, Sendable { case end, activity, replacementEnd }
