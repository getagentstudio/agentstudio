import AgentStudioCore
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextCardControllerTests {
    @Test("same-key display survives held detail and exact reads while stale actions are refused")
    func sameKeyRefreshRetainsDisplayUntilRevalidated() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        await ports.configureExactReads([], held: [1])
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, location: .card, content: .card,
            sources: [pane: PaneContextPreparedDetailFixture.cardSource(pane, selected: target)]
        ) { fixture, handle in
            let committed = try #require(handle.atom.value?.selectedAsk)
            let refresh = Task { try await fixture.refresh(handle) }
            let monitor = Task {
                _ = try? await refresh.value
                await ports.detailProducerEnded(beforeRead: 1)
                await ports.exactProducerEnded(beforeRead: 1)
            }
            do {
                try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
                #expect(
                    handle.atom.value?.selectedAsk == committed,
                    "The same ask must remain displayed during the detail read")
                await ports.release(1)
                try await ports.exactReads.expectNext(in: 1, .started(pane, id))
                #expect(
                    handle.atom.value?.selectedAsk == committed,
                    "The same ask must remain displayed during exact validation")
                try await assertStaleActionsAreRefused(fixture, handle: handle, ports: ports, target: target)
                await ports.releaseExact(1)
                _ = try await refresh.value
                await monitor.value
                #expect(handle.atom.value?.selectedAsk?.key == committed.key)
                #expect(
                    handle.atom.latestAcceptedValue?.selectedAsk?.generation != committed.generation,
                    "Equal paint keeps its value reference; the accepted read metadata must be the new generation")
                var draft = AskFormDraft()
                draft.text = "Current generation"
                _ = await fixture.bindings.performPerson(.answer(target, draft), handle: handle)
                #expect(await ports.answers.map(\.value) == [.text("Current generation")])
            } catch {
                await ports.release(1)
                await ports.releaseExact(1)
                _ = try? await refresh.value
                await monitor.value
                throw error
            }
        }
    }

    private func assertStaleActionsAreRefused(
        _ fixture: PaneContextPreparedDetailFixture,
        handle: PaneContextPopoverConsumerHandle, ports: PaneContextPopoverTestPorts,
        target: PaneContextMessageKey
    ) async throws {
        var draft = AskFormDraft()
        draft.text = "Stale generation"
        _ = await fixture.bindings.performPerson(.answer(target, draft), handle: handle)
        _ = await fixture.bindings.performPerson(.dismiss(target), handle: handle)
        #expect(await ports.answers.isEmpty, "A retained display snapshot cannot authorize an answer")
        #expect(await ports.dismissals.isEmpty, "A retained display snapshot cannot authorize dismissal")
    }

    enum RefreshEnd: Sendable, CaseIterable { case detailUnavailable, exactUnavailable, notFound, settled }

    @Test(
        "every final unavailable, missing or settled read removes the retained request", arguments: RefreshEnd.allCases)
    func finalReadRemovesRetainedAsk(outcome: RefreshEnd) async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let target = PaneContextMessageKey(paneId: pane, messageId: id)
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail)
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports, location: .card, content: .card,
            sources: [pane: PaneContextPreparedDetailFixture.cardSource(pane, selected: target)]
        ) { fixture, handle in
            try #require(handle.atom.value?.selectedAsk != nil)
            switch outcome {
            case .detailUnavailable: await ports.enqueue(.unavailable(.databaseUnavailable))
            case .exactUnavailable: await ports.configureExactReads([.unavailable(.databaseUnavailable)])
            case .notFound: await ports.configureExactReads([.notFound])
            case .settled:
                let settled = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .expired, revision: 2)
                await ports.configureExactReads([.found(settled.messages[0])])
            }
            try await fixture.refresh(handle)
            #expect(handle.atom.value?.selectedAsk == nil)
            try await assertStaleActionsAreRefused(fixture, handle: handle, ports: ports, target: target)
        }
    }

    @Test("changing the selected key immediately clears a committed request before the next read")
    func changedKeyClearsCommittedAskBeforeReading() async throws {
        let pane = PaneId.generateUUIDv7()
        let first = AgentMessageId.generateUUIDv7()
        let second = AgentMessageId.generateUUIDv7()
        let detail = try PaneContextMessageFixtures.askDetail(pane: pane, id: first, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: [1])
        func display(_ id: AgentMessageId, revision: UInt64) -> PaneContextDisplay {
            let counts = PaneMessageCounts(
                kinds: .init(failure: 0, needsYou: 1, done: 0, info: 0),
                newestOpenBlockingAskId: nil, oldestOpenAsk: .init(paneId: pane, messageId: id))
            return .init(
                revision: .init(revision), agentTitle: nil, agentLine: nil,
                own: counts, includingDrawers: counts, pullRequests: .notApplicable)
        }
        let sources = [pane: PaneContextPreparedDetailFixture.source(pane, display: display(first, revision: 1))]
        try await PaneContextPreparedDetailFixture.withOpen(
            pane: pane, ports: ports,
            location: .card, content: .card, sources: sources
        ) { fixture, handle in
            try #require(handle.atom.value?.selectedAsk?.key == .init(paneId: pane, messageId: first))
            fixture.setSource(
                PaneContextPreparedDetailFixture.source(pane, display: display(second, revision: 2)), for: pane)
            let refresh = Task { try await fixture.refresh(handle) }
            let monitor = Task {
                _ = try? await refresh.value
                await ports.detailProducerEnded(beforeRead: 1)
            }
            do {
                try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
                #expect(
                    handle.atom.value?.selectedAsk == nil,
                    "A different canonical selection must clear the old request before the held read")
                await ports.release(1)
                _ = try await refresh.value
                await monitor.value
                #expect(handle.atom.value?.selectedAsk == nil)
            } catch {
                await ports.release(1)
                _ = try? await refresh.value
                await monitor.value
                throw error
            }
        }
    }

}
