import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Native card lifecycle", .serialized)
struct PaneContextCardLifecycleTests {
    @Test("G15 a real refused answer keeps the open form and displays feedback after the exact reread")
    func refusedAnswerKeepsTheOpenFormAndShowsFeedback() async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"))
        do {
            try await host.open()
            let oversized = String(repeating: "r", count: 8193)
            try host.window.native.typeText(placeholder: "Reply", value: oversized)
            try host.window.native.press("pane-context.submit.\(host.scope)")
            try await host.window.actionCompleted()
            try await host.window.renderedCard()
            #expect(
                await host.person.answers == [
                    .init(
                        messageId: host.id, paneId: host.fixture.ownerId,
                        by: .localUser, value: .text(oversized))
                ])
            #expect(host.window.cardValue?.content.feedback == "Invalid answer: text too large")
            #expect(host.window.native.labels().contains("Invalid answer: text too large"))
            #expect(host.window.native.find("pane-context.submit.\(host.scope)") != nil)
            guard
                case .found(let row) = await host.fixture.composition.paneContextService.readMessage(
                    source: host.fixture.ownerId, message: host.id), case .ask(_, _, _, let state) = row.shape
            else {
                throw CardLifecycleFailure.missingAnswer
            }
            #expect(state == .open)
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }
    @Test("the notice-only card displays its unread count and opens the real Messages list")
    func unreadCardLinkOpensMessagesWithoutARequestBlock() async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"))
        let fixture = host.fixture
        let service = fixture.composition.paneContextService
        do {
            try await host.open()
            try #require(await service.dismiss(messageId: host.id, paneId: fixture.ownerId) == .done)
            let notice = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: notice, sender: .pane(fixture.ownerId),
                        sourceOccurredAt: nil, importance: .info, body: "A retained unread notice", why: nil,
                        actions: [], shape: .notice)) == .created(notice))
            await fixture.composition.presentationLane.publishPending()
            try await host.window.refresh()
            try await host.window.renderedCard()
            #expect(host.window.native.labels().contains("1 unread ·"))
            #expect(host.window.native.labels().contains("Show messages"))
            #expect(host.window.native.find("pane-context.card-more") == nil)
            #expect(host.window.native.find("pane-context.answer-in-messages") == nil)
            let messagesOpening = try host.window.beginOpening()
            try await host.window.completeOpening(messagesOpening)
            try await host.window.rendered()
            #expect(
                host.window.value?.shape?.messages.messageRows.contains {
                    $0.id == notice.uuid && $0.body == "A retained unread notice"
                } == true)
            #expect(await service.readDisplay(paneId: fixture.ownerId)?.own.kinds.unread == 1)
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }
    @Test(
        "G13/G15 pending, cursor-confirmed and sender-unconfirmed card forms stay absent; independent prompt keeps Needs you",
        arguments: [true, false])
    func receiptTransitionsKeepCardControlsAbsent(confirm: Bool) async throws {
        let host = try await PaneContextCardServiceHost.make(
            form: ExistingPopoverForm.singleChoice.request(), independentPrompt: true)
        let fixture = host.fixture
        let service = fixture.composition.paneContextService
        do {
            try await host.open()
            try host.window.native.press("pane-context.choice.blue.\(host.scope)")
            try await host.window.actionCompleted()
            try await host.window.renderedCard()
            host.expectSettledControlsAbsent()
            guard
                case .found(let pendingMessage) = await service.readMessage(source: fixture.ownerId, message: host.id),
                case .ask(_, _, _, .answered(_, _, .notYetConfirmed)) = pendingMessage.shape,
                case .page(let pending) = await service.changes(
                    .init(paneId: fixture.ownerId, writer: host.sender, after: .init(0)))
            else {
                Issue.record("Missing pending answer")
                throw CardLifecycleFailure.missingAnswer
            }
            #expect(pending.entries.map(\.kind) == [.answer(.choices([try .init("blue")]))])
            if confirm {
                guard
                    case .page(let ack) = await service.changes(
                        .init(
                            paneId: fixture.ownerId,
                            writer: host.sender, after: pending.nextPosition))
                else { throw CardLifecycleFailure.missingAnswer }
                #expect(ack.entries.isEmpty)
            } else {
                let ended = try await fixture.composition.liveSessionsAdapter.recordProviderEvent(
                    paneId: fixture.ownerId.uuid,
                    params: .init(
                        handle: "self",
                        provider: .init(
                            identifier: ClaudeCodeProviderIdentity.identifier,
                            version: ClaudeCodeProviderIdentity.supportedExactVersion,
                            mode: ClaudeCodeProviderIdentity.operatingMode),
                        event: .init(
                            name: .sessionEnd, conversationId: host.binding.providerConversationId,
                            turnId: nil, requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                        correlationId: UUIDv7.generate()), provenance: .matchingPane)
                #expect(ended.disposition == .admitted)
            }
            await fixture.composition.presentationLane.publishPending()
            try await host.window.refresh()
            try await host.window.renderedCard()
            host.expectSettledControlsAbsent()
            guard case .found(let settled) = await service.readMessage(source: fixture.ownerId, message: host.id),
                case .ask(_, _, _, .answered(_, _, let receipt)) = settled.shape
            else { throw CardLifecycleFailure.missingAnswer }
            #expect(receipt == (confirm ? .confirmed(at: fixture.now) : .unconfirmed))
            #expect(host.status.value(for: fixture.drawerId)?.status == .needsYou(.approval))
            #expect(host.window.native.labels().contains { $0.contains("Needs you · approval") })
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }

    @Test("G15 blocking and nonblocking card dismissals settle the real request", arguments: [true, false])
    func dismissalsRemoveCardControls(blocking: Bool) async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"), blocking: blocking)
        do {
            try await host.open()
            try host.window.native.press("pane-context.dismiss.\(host.scope)")
            try await host.window.actionCompleted()
            try await host.window.renderedCard()
            host.expectSettledControlsAbsent()
            guard
                case .found(let row) = await host.fixture.composition.paneContextService.readMessage(
                    source: host.fixture.ownerId, message: host.id), case .ask(_, _, _, let state) = row.shape
            else {
                throw CardLifecycleFailure.missingAnswer
            }
            #expect(state == (blocking ? .handedBack : .dismissed))
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }

    @Test("G17 a failed exact refresh clears native controls while the cached page still has an open ask")
    func failedExactRefreshRemovesNativeControls() async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"))
        do {
            try await host.open()
            #expect(host.window.native.find("pane-context.submit.\(host.scope)") != nil)
            await host.reader.failExactRead()
            try await host.window.refresh()
            try await host.window.renderedCard()
            host.expectSettledControlsAbsent()
            #expect(host.window.cardValue?.content.feedback == "Context unavailable: database unavailable")
            #expect(host.window.native.labels().contains("Context unavailable: database unavailable"))
            #expect(await host.person.answers.isEmpty)
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }

    @Test("G14 native card Answer opens Messages for the intended schema and submits exactly once")
    func elicitationNavigatesToItsMessagesForm() async throws {
        let form = ExistingPopoverForm.elicitation
        let host = try await PaneContextCardServiceHost.make(form: form.request(), omittedTarget: true)
        do {
            try await host.open()
            #expect(host.window.value?.shape?.messages.messageRows.contains { $0.id == host.id.uuid } == false)
            #expect(host.window.native.find("pane-context.submit.\(host.scope)") == nil)
            #expect(host.window.native.labels().contains("Answer…"))
            let answerOpening = try host.window.beginOpening("pane-context.answer-in-messages")
            try await host.window.completeOpening(answerOpening)
            try await host.window.rendered()
            #expect(host.window.value?.shape?.messages.messageRows.contains { $0.id == host.id.uuid } == true)
            try host.window.native.typeText(placeholder: "Project", value: "staging")
            try host.window.native.typeText(placeholder: "Workers", value: "2")
            try host.window.native.press("pane-context.field.\(host.scope).enabled")
            host.window.native.layout()
            try host.window.native.press("pane-context.submit.\(host.scope)")
            try await host.window.actionCompleted()
            #expect(
                await host.person.answers == [
                    .init(
                        messageId: host.id, paneId: host.fixture.ownerId,
                        by: .localUser, value: try form.expectedAnswer())
                ])
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }
}
private enum CardLifecycleFailure: Error { case missingAnswer }
