import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Card Messages opening survives same-key refresh", .serialized)
struct PaneContextCardRefreshNativeTests {
    @Test("F09 held card reads retain the original opening and ordinary revisions never dismiss it")
    func sameAskKeepsItsInstalledMessagesOpening() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "F09 owner")
            defer { store.removePane(pane.id) }
            let paneId = PaneId(existingUUID: pane.id)
            let id = AgentMessageId.generateUUIDv7()
            let ask = try PaneContextMessageFixtures.askDetail(pane: paneId, id: id, state: .open, revision: 1)
                .messages[0]
            let notice = AgentMessageDetail(
                id: .generateUUIDv7(), sourcePaneId: paneId, sender: ask.sender,
                sentAt: ask.sentAt, sourceOccurredAt: nil, importance: .failure,
                body: "Failure first line\nFailure second line", why: nil, actions: [], shape: .notice(.unread))
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [ask, notice]), heldReads: [2])
            await ports.configureExactReads([], held: [1])
            let publish: @MainActor (UInt64, Int) -> Void = { revision, infoCount in
                let counts = PaneMessageCounts(
                    kinds: .init(failure: 1, needsYou: 1, done: 0, info: infoCount), newestOpenBlockingAskId: nil,
                    oldestOpenAsk: .init(paneId: paneId, messageId: id))
                atoms.paneContextPresentation.apply([
                    paneId: .set(
                        .init(
                            revision: .init(revision), agentTitle: nil, agentLine: nil,
                            own: counts, includingDrawers: counts, pullRequests: .notApplicable))
                ])
            }
            publish(1, 0)
            let adapter = PaneContextUIAdapter(reader: ports, person: ports)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = owners.makeNativeCardHost(
                context: .project(paneId: pane.id, store: store),
                wallNow: Date(timeIntervalSince1970: 2))
            do {
                try await mounted.open()
                try await mounted.renderedCard()
                try await verifyOpening(mounted, ports: ports, ask: ask, notice: notice, publish: publish)
                try await ports.finish()
            } catch {
                try? await mounted.close()
                try? await ports.finish()
                throw error
            }
        }
    }

    private func verifyOpening(
        _ mounted: PaneContextPreparedNativeHost, ports: PaneContextPopoverTestPorts,
        ask: AgentMessageDetail, notice: AgentMessageDetail, publish: @MainActor (UInt64, Int) -> Void
    ) async throws {
        let pane = ask.sourcePaneId
        let key = PaneContextMessageKey(paneId: pane, messageId: ask.id)
        let card = try #require(mounted.cardHandle)
        let committed = try #require(mounted.cardValue?.selectedAsk)
        let producer = try mounted.beginOpening("pane-context.card-more")
        let opening = try mounted.native.presentationDecisions.opening(for: try #require(producer.press))
        try await mounted.completeOpening(producer)
        try await mounted.rendered()
        let initial = try readOpening(opening, phase: "initial installed opening")
        #expect(initial.isPresented && initial.paneId == pane)
        #expect(initial.controllerIdentity != nil)
        #expect(await ports.requests.count == 2)
        #expect(await ports.exactRequests == [key])
        let refresh = Task {
            await mounted.bindings.owner.refreshImmediately(card.key, opening: card.opening.epoch)
            let execution = try #require(await mounted.bindings.owner.latestExecution(for: card.key))
            await execution.task.value
        }
        let monitor = Task {
            _ = try? await refresh.value
            await ports.detailProducerEnded(beforeRead: 2)
            await ports.exactProducerEnded(beforeRead: 1)
        }
        do {
            try await ports.reads.expectNext(in: 2, .started(.init(paneId: pane, page: .first)))
            #expect(
                mounted.cardValue?.selectedAsk == committed, "F09 must retain the request during its held detail read")
            #expect(
                try readOpening(opening, phase: "held detail") == initial,
                "Held detail keeps the original installed Messages opening")
            await ports.release(2)
            try await ports.exactReads.expectNext(in: 1, .started(pane, ask.id))
            #expect(mounted.cardValue?.selectedAsk == committed, "F09 must retain the request during exact validation")
            #expect(
                try readOpening(opening, phase: "held exact") == initial,
                "Held exact validation keeps the original installed opening")
            var draft = AskFormDraft()
            draft.text = "Stale"
            _ = await mounted.bindings.performPerson(.answer(key, draft), handle: card)
            _ = await mounted.bindings.performPerson(.dismiss(key), handle: card)
            #expect(await ports.answers.isEmpty)
            #expect(await ports.dismissals.isEmpty)
            await ports.releaseExact(1)
            try await refresh.value
            await monitor.value
            let info = try PaneContextPopoverShapingTests.message(
                paneId: pane, shape: .notice(.unread), importance: .info)
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [ask, notice, info]))
            publish(2, 1)
            let child = try #require(mounted.handle)
            let forwarding = mounted.bindings.inputs.forwardingTasks(for: child.key, opening: child.opening.epoch)
            try await mounted.canonicalChangeCompleted(forwarding)
            let cardRefresh = try #require(await mounted.bindings.owner.latestExecution(for: card.key))
            await cardRefresh.task.value
            try #require(
                try readOpening(opening, phase: "canonical revision") == initial,
                "A same-key canonical revision keeps the exact installed opening")
            try await mounted.rendered()
            try await mounted.renderedCard()
            let closing = try mounted.native.press("pane-context.go-to-pane")
            #expect(try await !mounted.native.presentationDecisions.decision(for: closing))
            #expect(
                try !readOpening(opening, phase: "closing action live State").isPresented,
                "The accessor reads actual live State after the closing action")
            try await mounted.close()
            #expect(throws: PaneContextPopoverOpeningReadback.Failure.retired) { try opening.read() }
        } catch {
            await ports.release(2)
            await ports.releaseExact(1)
            _ = try? await refresh.value
            await monitor.value
            throw error
        }
    }
    private func readOpening(_ opening: PaneContextPopoverOpeningReadback, phase: String) throws
        -> PaneContextPopoverOpeningReadback.Snapshot
    {
        do { return try opening.read() } catch { throw NativeCardOpeningFailure.phase(phase, underlying: error) }
    }

}

private enum NativeCardOpeningFailure: Error { case phase(String, underlying: any Error) }
