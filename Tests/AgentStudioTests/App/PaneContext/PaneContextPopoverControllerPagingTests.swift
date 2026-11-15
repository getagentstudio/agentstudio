import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverControllerPagingTests {
    @Test("Dismiss all delegates one current-membership call and leaves asks untouched")
    func dismissAllNoticesUsesOneServiceCall() async throws {
        let owner = PaneId.generateUUIDv7()
        let first = try PaneContextPopoverShapingTests.message(
            paneId: owner, shape: .notice(.unread), importance: .info, sentAt: 3)
        let ask = try PaneContextPopoverShapingTests.message(
            paneId: owner,
            shape: .ask(.question, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open),
            importance: .attention, sentAt: 2)
        let initial = PaneContextPopoverShapingTests.detail(paneId: owner, messages: [first, ask])
        let ports = PaneContextPopoverTestPorts(initial)
        await ports.configureDismissAll(.dismissed(count: 1))
        try await PaneContextPreparedDetailFixture.withOpen(pane: owner, ports: ports) { fixture, handle in
            _ = await fixture.bindings.performPerson(.dismissAllNotices, handle: handle)
            #expect(await ports.dismissAllCalls.count == 1)
            #expect(await ports.dismissAllCalls.first?.0 == owner)
            #expect(await ports.dismissAllCalls.first?.1 == true)
            #expect(await ports.dismissals.isEmpty)
            #expect(await ports.answers.isEmpty)
            #expect(handle.atom.value?.content.feedback == "Dismissed 1 notices")
            #expect(await ports.requests.map(\.page) == [.first, .first])
        }
    }

    @Test("Dismiss all surfaces typed storage failure without dismissing messages")
    func dismissAllNoticesSurfacesUnavailable() async throws {
        let owner = PaneId.generateUUIDv7()
        let ask = try PaneContextPopoverShapingTests.message(
            paneId: owner,
            shape: .ask(.question, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open),
            importance: .attention)
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: owner, messages: [ask]))
        await ports.configureDismissAll(.unavailable(.databaseUnavailable))
        try await PaneContextPreparedDetailFixture.withOpen(pane: owner, ports: ports) { fixture, handle in
            _ = await fixture.bindings.performPerson(.dismissAllNotices, handle: handle)
            #expect(await ports.dismissAllCalls.count == 1)
            #expect(await ports.dismissAllCalls.first?.0 == owner)
            #expect(await ports.dismissAllCalls.first?.1 == true)
            #expect(await ports.dismissals.isEmpty)
            #expect(handle.atom.value?.content.feedback == "Dismiss unavailable: database unavailable")
        }
    }

    @Test("Drawer host dismiss-all uses its own membership scope")
    func dismissAllNoticesUsesOwnScopeForDrawerHost() async throws {
        let drawer = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: drawer))
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: drawer, ports: ports, includingDrawers: false
        ) { fixture, handle in
            _ = await fixture.bindings.performPerson(.dismissAllNotices, handle: handle)
            #expect(await ports.dismissAllCalls.count == 1)
            #expect(await ports.dismissAllCalls.first?.0 == drawer)
            #expect(await ports.dismissAllCalls.first?.1 == false)
        }
    }

    @Test
    func messagePagingAndSourcePagingAccumulateWithoutLosingOtherCursors() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let first = try PaneContextPopoverShapingTests.message(
            paneId: owner, shape: .notice(.unread), importance: .info, sentAt: 3)
        let second = try PaneContextPopoverShapingTests.message(
            paneId: owner, shape: .notice(.unread), importance: .attention, sentAt: 2)
        let third = try PaneContextPopoverShapingTests.message(
            paneId: drawer, shape: .notice(.unread), importance: .info, sentAt: 1)
        let initial = PaneContextPopoverShapingTests.detail(
            paneId: owner, messages: [first],
            truncation: .init(
                omitted: [.init(source: owner, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 12))],
                remainingLiveSources: 1, nextSourcesAfter: owner))
        let ports = PaneContextPopoverTestPorts(initial)
        let sources = [
            owner: PaneContextPreparedDetailFixture.source(owner, children: [drawer]),
            drawer: PaneContextPreparedDetailFixture.source(drawer, parent: owner),
        ]
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: owner, ports: ports, sources: sources
        ) { fixture, handle in
            await ports.enqueue(.detail(initial))
            await ports.enqueue(.detail(PaneContextPopoverShapingTests.detail(paneId: owner, messages: [second])))
            #expect(
                await fixture.bindings.loadPage(.messages(source: owner, rank: 1, position: 12), handle: handle)
                    == .loaded)
            #expect(handle.atom.value?.shape?.messages.messageRows.map(\.id) == [second.id.uuid, first.id.uuid])
            #expect(handle.atom.value?.shape?.messages.pages.isEmpty == true)
            #expect(handle.atom.value?.shape?.messages.nextSourcesAfter == owner.uuid)
            await ports.enqueue(.detail(initial))
            await ports.enqueue(
                .detail(
                    PaneContextPopoverShapingTests.detail(
                        paneId: owner, drawers: [.init(sourcePaneId: drawer, messages: [third])])))
            await ports.enqueue(.detail(PaneContextPopoverShapingTests.detail(paneId: owner, messages: [second])))
            #expect(await fixture.bindings.loadPage(.sources(after: owner), handle: handle) == .loaded)
            #expect(
                handle.atom.value?.shape?.messages.messageRows.map(\.id) == [
                    second.id.uuid, first.id.uuid, third.id.uuid,
                ])
            #expect(handle.atom.value?.shape?.messages.nextSourcesAfter == nil)
            #expect(
                await ports.requests.map(\.page) == [
                    .first, .first, .more(source: owner, after: .init(rank: 1, position: 12)),
                    .first, .moreSources(after: owner), .more(source: owner, after: .init(rank: 1, position: 12)),
                ])
        }
    }

    @Test
    func pagingAcrossARevisionRestartsInsteadOfKeepingStaleRows() async throws {
        let owner = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let initial = try PaneContextMessageFixtures.askDetail(pane: owner, id: id, state: .open, revision: 1)
        let current = try PaneContextMessageFixtures.askDetail(pane: owner, id: id, state: .expired, revision: 2)
        let ports = PaneContextPopoverTestPorts(initial)
        try await PaneContextPreparedDetailFixture.withOpen(pane: owner, ports: ports) { fixture, handle in
            await ports.enqueue(.detail(current))
            await ports.setDetail(current)
            #expect(
                await fixture.bindings.loadPage(.messages(source: owner, rank: 0, position: 12), handle: handle)
                    == .restartedOnRevision)
            let execution = try #require(await fixture.bindings.owner.latestExecution(for: handle.key))
            _ = try await fixture.completed(execution, for: handle)
            #expect(handle.atom.value?.shape?.revision == .init(2))
            #expect(await ports.requests.last?.page == .first)
            #expect(
                handle.atom.value?.shape?.messages.messageRows.first?.shape
                    == .ask(
                        reason: .question, form: .freeText(placeholder: "Reply"), waiting: .nonBlocking, state: .expired
                    ))
        }
    }

    @Test
    func booleanDraftAndNumericInputCrossTheTypedAnswerBoundary() async throws {
        let owner = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let message = AgentMessageDetail(
            id: id, sourcePaneId: owner,
            sender: .session(
                provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: UUIDv7.generate()),
            sentAt: .distantPast, sourceOccurredAt: nil, importance: .attention, body: "Form", why: nil, actions: [],
            shape: .ask(
                .question,
                .elicitation(
                    .init(
                        properties: [
                            .init(name: "enabled", title: nil, description: nil, type: .boolean),
                            .init(
                                name: "count", title: nil, description: nil,
                                type: .integer(.init(minimum: 1, maximum: 5))),
                        ], required: ["enabled", "count"])), .nonBlocking, .open))
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: owner, messages: [message]))
        try await PaneContextPreparedDetailFixture.withOpen(pane: owner, ports: ports) { fixture, handle in
            var draft = AskFormDraft()
            draft.booleans["enabled"] = true
            draft.fields["count"] = "3"
            _ = await fixture.bindings.performPerson(
                .answer(.init(paneId: owner, messageId: id), draft), handle: handle)
            #expect(
                await ports.answers.last?.value
                    == .form(.init(properties: ["enabled": .boolean(true), "count": .integer(3)])))
            draft.fields["count"] = "not a number"
            _ = await fixture.bindings.performPerson(
                .answer(.init(paneId: owner, messageId: id), draft), handle: handle)
            #expect(handle.atom.value?.content.feedback == "Invalid answer: field count")
            #expect(await ports.answers.count == 1)
        }
    }
}
