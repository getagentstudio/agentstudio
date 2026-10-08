import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverControllerTests {
    @Test
    func staleGenerationCannotReplaceTheNewPane() async throws {
        let first = PaneId.generateUUIDv7()
        let second = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: second),
            results: [.detail(PaneContextPopoverShapingTests.detail(paneId: first))], heldReads: [0])
        let controller = makePopoverController(ports: ports)
        let oldOpen = Task { await controller.open(first) }
        try await ports.reads.expectNext(in: 0, .started(.init(paneId: first, page: .first)))
        await controller.open(second)
        await ports.release(0)
        await oldOpen.value
        #expect(controller.state?.paneId == second)
        controller.close()
        try await ports.finish()
    }

    @Test
    func unavailableKeepsLastStateAndPaneGoneCloses() async throws {
        let pane = PaneId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: pane))
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        let original = controller.state
        await ports.enqueue(.unavailable(.databaseUnavailable))
        await controller.refresh()
        #expect(controller.state == original)
        #expect(controller.unavailableNote == "Context unavailable: database unavailable")
        await ports.enqueue(.paneGone)
        await controller.refresh()
        #expect(controller.state == nil)
        #expect(controller.paneId == nil)
        try await ports.finish()
    }

    @Test
    func movedSourceIsDroppedAndFirstPageIsReadAgain() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: drawer, shape: .notice(.unread), importance: .info)
        let initial = PaneContextPopoverShapingTests.detail(
            paneId: owner, drawers: [.init(sourcePaneId: drawer, messages: [message])])
        let ports = PaneContextPopoverTestPorts(initial)
        let controller = makePopoverController(ports: ports)
        await controller.open(owner)
        await ports.enqueue(.sourceNotInView)
        await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: owner))
        await controller.moreMessages(source: drawer, after: .init(rank: 0, position: 12))
        #expect(controller.state?.messages.partitions.all.isEmpty == true)
        #expect(await ports.requests.last?.page == .first)
        controller.close()
        try await ports.finish()
    }

    @Test
    func keyedTitlesAreCapturedAndMissingTitlesUseReadableFallbacks() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let own = try PaneContextPopoverShapingTests.message(paneId: owner, shape: .notice(.unread), importance: .info)
        let child = try PaneContextPopoverShapingTests.message(
            paneId: drawer, shape: .notice(.unread), importance: .attention)
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(
                paneId: owner, messages: [own], drawers: [.init(sourcePaneId: drawer, messages: [child])]))
        var captured: [PaneId] = []
        let controller = makePopoverController(
            ports: ports,
            titleForPane: { id in
                captured.append(id)
                return id == owner ? "Implementation" : nil
            })
        await controller.open(owner)
        #expect(captured == [owner, drawer])
        let groups = try #require(controller.state?.messages.partitions.all)
        #expect(groups.contains { $0.sourceLabel == "Implementation" })
        #expect(groups.contains { $0.sourceLabel == "Drawer pane" })
        controller.close()
        try await ports.finish()
    }

    @Test
    func revisionRereadShowsAnAskExpiringAndReceiptTransitions() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let ports = PaneContextPopoverTestPorts(try Self.askDetail(pane: pane, id: id, state: .open, revision: 1))
        let revisions = PopoverTestRevision(.init(1))
        let controller = makePopoverController(ports: ports, revisionForPane: { _ in revisions.value })
        await controller.open(pane)
        await controller.refreshIfRevisionChanged()
        #expect(await ports.requests.count == 1)
        await ports.setDetail(try Self.askDetail(pane: pane, id: id, state: .expired, revision: 2))
        revisions.value = .init(2)
        await controller.refreshIfRevisionChanged()
        #expect(
            Self.firstRow(controller)?.shape
                == .ask(
                    reason: .question, form: .freeText(placeholder: "Reply"), waiting: .nonBlocking, state: .expired))
        for receipt in [AnswerReceipt.notYetConfirmed, .confirmed(at: .distantPast), .unconfirmed] {
            await ports.setDetail(
                try Self.askDetail(
                    pane: pane, id: id, state: .answered(by: .localUser, value: .text("Yes"), receipt: receipt),
                    revision: 3))
            await controller.refresh()
            if case .ask(_, _, _, .answered(_, .text("Yes"), let shown)) = Self.firstRow(controller)?.shape {
                switch receipt {
                case .notYetConfirmed: #expect(shown == .notYetConfirmed)
                case .confirmed: #expect(shown == .confirmed(at: .distantPast))
                case .unconfirmed: #expect(shown == .unconfirmed)
                }
            } else {
                Issue.record("The re-read must show the answered ask and its receipt")
            }
        }
        controller.close()
        try await ports.finish()
    }

    static func askDetail(pane: PaneId, id: AgentMessageId, state: AskState, revision: UInt64) throws
        -> PaneContextDetail
    {
        let message = AgentMessageDetail(
            id: id, sourcePaneId: pane,
            sender: .session(
                provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: UUIDv7.generate()),
            sentAt: .distantPast, sourceOccurredAt: nil, importance: .info, body: "Question", why: nil,
            actions: [], shape: .ask(.question, .freeText(placeholder: "Reply"), .nonBlocking, state))
        return .init(
            paneId: pane, revision: .init(revision), agentTitle: nil, agentLine: nil, session: nil,
            messages: [message], drawerMessages: [], links: .unknown, pullRequests: .notApplicable, truncation: nil)
    }
    static func firstRow(_ controller: PaneContextPopoverController) -> MessageRowModel? {
        controller.state?.messages.partitions.all.first?.rows.first
    }
}

@MainActor
private final class PopoverTestRevision {
    var value: PaneContextRevision
    init(_ value: PaneContextRevision) { self.value = value }
}
