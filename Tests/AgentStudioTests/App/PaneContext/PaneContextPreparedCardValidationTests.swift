import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Pending card validation and resolved obligations", .serialized)
struct PaneContextPreparedCardValidationTests {
    enum Command: Sendable, CaseIterable { case answer, dismiss }

    @Test("Card identity never authorizes an ask command", arguments: Command.allCases)
    func cardMetadataHasNoAskActionAuthority(_ command: Command) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let ports = PaneContextPopoverTestPorts(
            try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1))
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, content: .card,
            sources: [pane: PaneContextPreparedDetailFixture.cardSource(pane, selected: target)]
        ) { fixture, handle in
            let intent: PaneContextPopoverPersonIntent
            switch command {
            case .answer:
                var draft = AskFormDraft()
                draft.text = "Card has no answer authority"
                intent = .answer(target, draft)
            case .dismiss: intent = .dismiss(target)
            }
            let result = await fixture.bindings.performPerson(intent, handle: handle)
            #expect(result.resolution == .refused(.requestNotCurrent))
            #expect(result.presentation == .keepPopover)
            #expect(await ports.answers.isEmpty)
            #expect(await ports.dismissals.isEmpty)
            #expect(await ports.requests.isEmpty)
        }
    }

    @Test("Messages page completion waits for its resolved read")
    func pendingPublicationDoesNotCloseAnOperation() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let ask = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1).messages[0]
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: pane, messages: [ask],
            truncation: .init(
                omitted: [.init(source: pane, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 1))],
                remainingLiveSources: 0, nextSourcesAfter: nil))
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, location: .pane, content: .messages(.top),
            sources: [pane: PaneContextPreparedDetailFixture.cardSource(pane, selected: target)]
        ) { fixture, handle in
            let owner = try #require(fixture.bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
            let operation = Task {
                await fixture.bindings.loadPage(.messages(source: pane, rank: 1, position: 1), handle: handle)
            }
            let monitor = Task {
                _ = await operation.value
                await ports.detailProducerEnded(beforeRead: 1)
            }
            do {
                try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
                #expect(await owner.pageWaiters.count == 1)
                #expect(await owner.consumers[handle.key]?.pendingPages.count == 1)
                await ports.release(1)
                let completed = await operation.value
                await monitor.value
                #expect(completed == .loaded)
                #expect(handle.atom.latestAcceptedValue?.publication.request.validationPhase == .resolved)
                #expect(await owner.pageWaiters.isEmpty)
                #expect(await owner.consumers[handle.key]?.pendingPersonRefreshes.isEmpty == true)
            } catch {
                await ports.release(1)
                _ = await operation.value
                await monitor.value
                throw error
            }
        }
    }

    @Test("Messages opening width freezes only after the resolved multiline read")
    func pendingPublicationDoesNotFreezeOpeningWidth() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let original = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1).messages[
            0]
        let multiline = AgentMessageDetail(
            id: id, sourcePaneId: pane, sender: original.sender, sentAt: original.sentAt,
            sourceOccurredAt: nil, importance: original.importance, body: "Line one\nLine two", why: nil,
            actions: [], shape: original.shape)
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [multiline]), heldReads: [0])
        let fixture = PaneContextPreparedDetailFixture(adapter: .init(reader: ports, person: ports))
        fixture.setSource(PaneContextPreparedDetailFixture.cardSource(pane, selected: target), for: pane)
        let key = PaneContextPopoverConsumerKey(hostId: UUIDv7.generate(), surface: .paneMessages, paneId: pane)
        let setup = fixture.bindings.beginOpen(
            key,
            demand: .init(
                content: .messages(.top), location: .pane,
                includingDrawers: true, screenVisibleWidth: 1400))
        var monitor: Task<Void, Never>?
        do {
            let handle = try #require(await setup.value)
            monitor = Task {
                await handle.opening.initialExecution.task.value
                await ports.detailProducerEnded(beforeRead: 0)
            }
            try await ports.reads.expectNext(in: 0, .started(.init(paneId: pane, page: .first)))
            let owner = try #require(fixture.bindings.owner as? PaneContextPopoverRefreshOwner<TestPushClock>)
            #expect(handle.atom.latestAcceptedValue == nil)
            #expect(await owner.consumers[key]?.frozenWidth == nil)
            await ports.release(0)
            _ = try await fixture.completed(handle.opening.initialExecution, for: handle)
            await monitor?.value
            #expect(handle.atom.latestAcceptedValue?.publication.request.validationPhase == .resolved)
            #expect(handle.atom.value?.content.width == 560)
            #expect(await owner.consumers[key]?.frozenWidth == 560)
            try await fixture.finish()
            try await ports.finish()
        } catch {
            await ports.release(0)
            await monitor?.value
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }
}
