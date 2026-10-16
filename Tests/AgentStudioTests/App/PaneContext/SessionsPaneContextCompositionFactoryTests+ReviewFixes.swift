import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension SessionsPaneContextCompositionFactoryTests {

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

            let binding = try await fixture.bind(paneId: fixture.ownerId)
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
