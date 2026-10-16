import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane message count fold")
struct PaneMessageCountFoldTests {
    @Test(
        "Outstanding counts follow every shape, waiting mode, reason and importance", arguments: paneMessageCountCases)
    func outstandingStateTable(scenario: PaneMessageCountCase) throws {
        let source = PaneId.generateUUIDv7()
        let message = try countedMessage(source: source, importance: scenario.importance, shape: scenario.shape)
        let expected = PaneMessageCounts(
            needsApprovalCount: scenario.expectedType == .needsApproval ? 1 : 0,
            needsReplyCount: scenario.expectedType == .needsReply ? 1 : 0,
            attentionCount: scenario.expectedType == .attention ? 1 : 0,
            informationalCount: scenario.expectedType == .informational ? 1 : 0,
            newestOpenBlockingAskId: scenario.expectedType == .needsApproval ? message.detail.id : nil)
        #expect(PaneMessageCountFold.summarize(messages: [message], sourceOrder: [source]) == expected)
    }

    @Test("Counts are additive across outstanding messages and exclude settled rows")
    func mixedOutstandingMessages() throws {
        let owner = PaneId.generateUUIDv7()
        let blocking = try countedMessage(
            source: owner,
            shape: .ask(
                .blocked, .freeText(placeholder: nil), .blocking(deadline: Date(timeIntervalSince1970: 200)), .open))
        let reply = try countedMessage(
            source: owner, shape: .ask(.approval, .freeText(placeholder: nil), .nonBlocking, .open))
        let attention = try countedMessage(source: owner, importance: .failure, shape: .notice(.unread))
        let info = try countedMessage(source: owner, importance: .done, shape: .notice(.unread))
        let settled = try countedMessage(source: owner, importance: .failure, shape: .notice(.read))
        #expect(
            PaneMessageCountFold.summarize(messages: [blocking, reply, attention, info, settled], sourceOrder: [owner])
                == PaneMessageCounts(
                    needsApprovalCount: 1, needsReplyCount: 1, attentionCount: 1, informationalCount: 1,
                    newestOpenBlockingAskId: blocking.detail.id))
    }

    @Test("Later drawer receive time wins even with a lower source position")
    func newestUsesReceiveTimeAcrossSources() throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let shape = AgentMessageShape.ask(
            .question, .freeText(placeholder: nil), .blocking(deadline: Date(timeIntervalSince1970: 300)), .open)
        let ownAsk = try countedMessage(
            source: owner, position: 99, sentAt: Date(timeIntervalSince1970: 100), shape: shape)
        let drawerAsk = try countedMessage(
            source: drawer, position: 1, sentAt: Date(timeIntervalSince1970: 101), shape: shape)
        #expect(
            PaneMessageCountFold.summarize(messages: [ownAsk, drawerAsk], sourceOrder: [owner, drawer])
                .newestOpenBlockingAskId == drawerAsk.detail.id)
    }

    @Test("Receive-time ties prefer composed view order over cross-source positions")
    func composedOrderBreaksCrossSourceTie() throws {
        let owner = PaneId.generateUUIDv7()
        let firstDrawer = PaneId.generateUUIDv7()
        let secondDrawer = PaneId.generateUUIDv7()
        let shape = AgentMessageShape.ask(
            .approval, .freeText(placeholder: nil), .blocking(deadline: Date(timeIntervalSince1970: 200)), .open)
        let ownAsk = try countedMessage(source: owner, position: 1, shape: shape)
        let first = try countedMessage(source: firstDrawer, position: 50, shape: shape)
        let second = try countedMessage(source: secondDrawer, position: 100, shape: shape)
        #expect(
            PaneMessageCountFold.summarize(
                messages: [second, first, ownAsk], sourceOrder: [owner, firstDrawer, secondDrawer]
            ).newestOpenBlockingAskId == ownAsk.detail.id)
        #expect(
            PaneMessageCountFold.summarize(messages: [second, first], sourceOrder: [owner, firstDrawer, secondDrawer])
                .newestOpenBlockingAskId == first.detail.id)
    }

    @Test("Within one source, equal receive times prefer the newer position")
    func sourcePositionBreaksWithinSourceTie() throws {
        let source = PaneId.generateUUIDv7()
        let shape = AgentMessageShape.ask(
            .question, .freeText(placeholder: nil), .blocking(deadline: Date(timeIntervalSince1970: 200)), .open)
        let old = try countedMessage(source: source, position: 1, shape: shape)
        let new = try countedMessage(source: source, position: 2, shape: shape)
        #expect(
            PaneMessageCountFold.summarize(messages: [old, new], sourceOrder: [source]).newestOpenBlockingAskId
                == new.detail.id)
    }

    @Test("A newer nonblocking ask cannot become the blocking affordance")
    func newestBlockingIdExcludesReplyAsks() throws {
        let source = PaneId.generateUUIDv7()
        let blocking = try countedMessage(
            source: source,
            shape: .ask(
                .question, .freeText(placeholder: nil), .blocking(deadline: Date(timeIntervalSince1970: 200)), .open))
        let reply = try countedMessage(
            source: source, position: 2, sentAt: Date(timeIntervalSince1970: 101),
            shape: .ask(.approval, .freeText(placeholder: nil), .nonBlocking, .open))
        #expect(
            PaneMessageCountFold.summarize(messages: [blocking, reply], sourceOrder: [source]).newestOpenBlockingAskId
                == blocking.detail.id)
    }

    @Test("No outstanding messages yields zero counts")
    func emptyCounts() {
        #expect(PaneMessageCountFold.summarize(messages: [], sourceOrder: []) == .zero)
    }
}
