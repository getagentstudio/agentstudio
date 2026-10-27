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
            let ask = try PaneContextPopoverControllerTests.askDetail(pane: paneId, id: id, state: .open, revision: 1)
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
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = PaneContextNativePopoverWindow(
                paneId: paneId, readers: readers, location: .card, wallNow: Date(timeIntervalSince1970: 2),
                card: (.project(paneId: pane.id, store: store), store))
            do {
                try await mounted.readCompleted()
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
        _ mounted: PaneContextNativePopoverWindow, ports: PaneContextPopoverTestPorts,
        ask: AgentMessageDetail, notice: AgentMessageDetail, publish: @MainActor (UInt64, Int) -> Void
    ) async throws {
        let pane = ask.sourcePaneId
        let key = PaneContextMessageKey(paneId: pane, messageId: ask.id)
        let card = try #require(mounted.sink.cardController)
        let committed = try #require(card.selectedAsk)
        let openingPress = try mounted.press("pane-context.card-more")
        let opening = try mounted.presentationDecisions.opening(for: openingPress)
        try await mounted.readCompleted()
        try await mounted.rendered()
        let initial = try opening.read()
        #expect(initial.isPresented && initial.paneId == pane)
        #expect(initial.controllerIdentity != nil)
        #expect(await ports.requests.count == 2)
        #expect(await ports.exactRequests == [key])
        let refresh = Task {
            await card.refresh()
            await ports.detailProducerEnded(beforeRead: 2)
            await ports.exactProducerEnded(beforeRead: 1)
        }
        var detailReleased = false
        var exactReleased = false
        do {
            try await ports.reads.expectNext(in: 2, .started(.init(paneId: pane, page: .first)))
            #expect(card.selectedAsk == committed, "F09 must retain the request while its detail read is held")
            #expect(try opening.read() == initial, "Held detail must keep the original installed opening")
            await ports.release(2)
            detailReleased = true
            try await ports.exactReads.expectNext(in: 1, .started(pane, ask.id))
            #expect(card.selectedAsk == committed, "F09 must retain the request while its exact read is held")
            #expect(try opening.read() == initial, "Held exact validation must keep the original installed opening")
            var draft = AskFormDraft()
            draft.text = "Stale"
            await card.answerDraft(messageId: ask.id, source: pane, draft: draft)
            await card.dismiss(messageId: ask.id, source: pane)
            #expect(await ports.answers.isEmpty)
            #expect(await ports.dismissals.isEmpty)
            await ports.releaseExact(1)
            exactReleased = true
            await refresh.value
            let info = try PaneContextPopoverShapingTests.message(
                paneId: pane, shape: .notice(.unread), importance: .info)
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [ask, notice, info]))
            publish(2, 1)
            mounted.layout()
            try await mounted.readCompleted()
            try #require(try opening.read() == initial, "A normal same-key revision must keep the original opening")
            try await mounted.rendered()
            try await mounted.renderedCard()
            let closePress = try mounted.press("pane-context.go-to-pane")
            #expect(try await !mounted.presentationDecisions.decision(for: closePress))
            #expect(try !opening.read().isPresented, "The accessor must read live State after a real closing action")
            try await mounted.close()
            #expect(throws: PaneContextPopoverOpeningReadback.Failure.retired) { try opening.read() }
        } catch {
            if !detailReleased { await ports.release(2) }
            if !exactReleased { await ports.releaseExact(1) }
            await refresh.value
            throw error
        }
    }
}
