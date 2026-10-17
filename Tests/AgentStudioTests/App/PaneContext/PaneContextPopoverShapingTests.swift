import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

struct PaneContextPopoverShapingTests {
    struct ImportanceOracle: Sendable {
        let importance: MessageImportance
        let noticeType: MessageAttentionTypeModel
    }

    struct NoticeOracle: Sendable {
        let state: NoticeState
        let outstanding: Bool
    }

    struct AskOracle: Sendable {
        let state: AskState
        let outstanding: Bool
    }

    struct WaitingOracle: Sendable {
        let waiting: AskWaiting
        let attentionType: MessageAttentionTypeModel
    }

    // Independent oracle: Specification R20 classifies type; only unread notices
    // and open asks count. Never call the product classifier to build expectations.
    static let importances: [ImportanceOracle] = [
        .init(importance: .info, noticeType: .informational),
        .init(importance: .done, noticeType: .informational),
        .init(importance: .attention, noticeType: .attention),
        .init(importance: .failure, noticeType: .attention),
    ]
    static let notices: [NoticeOracle] = [
        .init(state: .unread, outstanding: true),
        .init(state: .read, outstanding: false),
        .init(state: .dismissed, outstanding: false),
        .init(state: .withdrawn, outstanding: false),
    ]
    static let asks: [AskOracle] = [
        .init(state: .open, outstanding: true),
        .init(state: .answered(by: .localUser, value: .text("yes"), receipt: .notYetConfirmed), outstanding: false),
        .init(
            state: .answered(
                by: .localUser, value: .text("yes"), receipt: .confirmed(at: Date(timeIntervalSince1970: 4))),
            outstanding: false),
        .init(state: .answered(by: .localUser, value: .text("yes"), receipt: .unconfirmed), outstanding: false),
        .init(state: .handedBack, outstanding: false),
        .init(state: .dismissed, outstanding: false),
        .init(state: .expired, outstanding: false),
        .init(state: .withdrawn, outstanding: false),
        .init(state: .stale, outstanding: false),
    ]
    static let waiting: [WaitingOracle] = [
        .init(waiting: .blocking(deadline: Date(timeIntervalSince1970: 100)), attentionType: .needsApproval),
        .init(waiting: .nonBlocking, attentionType: .needsReply),
    ]

    @Test(arguments: notices, importances)
    func noticeTableMatchesTheSpec(state: NoticeOracle, importance: ImportanceOracle) async throws {
        let paneId = PaneId.generateUUIDv7()
        let row = try await Self.onlyRow(
            Self.message(paneId: paneId, shape: .notice(state.state), importance: importance.importance))
        #expect(row.attentionType == importance.noticeType)
        #expect(row.isOutstanding == state.outstanding)
    }

    struct AskScenario: Sendable {
        let state: AskOracle
        let waiting: WaitingOracle
        let importance: ImportanceOracle
    }

    static let askScenarios: [AskScenario] = asks.flatMap { state in
        waiting.flatMap { wait in
            importances.map { importance in
                AskScenario(state: state, waiting: wait, importance: importance)
            }
        }
    }

    @Test(arguments: askScenarios)
    func askTableMatchesTheSpec(scenario: AskScenario) async throws {
        let paneId = PaneId.generateUUIDv7()
        let row = try await Self.onlyRow(
            Self.message(
                paneId: paneId,
                shape: .ask(.question, .freeText(placeholder: nil), scenario.waiting.waiting, scenario.state.state),
                importance: scenario.importance.importance))
        #expect(row.attentionType == scenario.waiting.attentionType)
        #expect(row.isOutstanding == scenario.state.outstanding)
    }

    @Test
    func drawerApprovalPrecedesOwnerInformationAndNoticesAreNewestFirst() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let older = try Self.message(paneId: owner, shape: .notice(.unread), importance: .info, sentAt: 1)
        let newer = try Self.message(paneId: owner, shape: .notice(.unread), importance: .failure, sentAt: 3)
        let approval = try Self.message(
            paneId: drawer,
            shape: .ask(
                .blocked, .freeText(placeholder: nil), .blocking(deadline: Date(timeIntervalSince1970: 100)), .open),
            importance: .done, sentAt: 0)
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(
                paneId: owner, messages: [older, newer], drawers: [.init(sourcePaneId: drawer, messages: [approval])]),
            sourceTitles: [:])
        let rows = shape.messages.partitions.all.flatMap(\.rows)
        #expect(rows.map(\.id) == [approval.id.uuid, newer.id.uuid, older.id.uuid])
        #expect(rows.first?.sourcePaneId == drawer.uuid)
        #expect(rows.first?.sourcePaneLabel == "Drawer pane")
        #expect(shape.messages.partitions.needsApproval.first?.rows.map(\.id) == [approval.id.uuid])
        #expect(shape.messages.partitions.informational.first?.rows.map(\.id) == [older.id.uuid])
    }

    @Test
    func providedSourceTitlesAndReadableFallbacksNeverUseIdentifiers() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let own = try Self.message(paneId: owner, shape: .notice(.unread), importance: .info)
        let child = try Self.message(paneId: drawer, shape: .notice(.unread), importance: .attention)
        let detail = Self.detail(
            paneId: owner, messages: [own], drawers: [.init(sourcePaneId: drawer, messages: [child])])
        let titled = await PaneContextPopoverShaping.shape(detail, sourceTitles: [owner: "Build", drawer: "Review"])
        #expect(titled.messages.partitions.all.map(\.sourceLabel).contains("Build"))
        #expect(titled.messages.partitions.all.map(\.sourceLabel).contains("Review"))
        let fallback = await PaneContextPopoverShaping.shape(detail, sourceTitles: [:])
        #expect(Set(fallback.messages.partitions.all.map(\.sourceLabel)) == ["This pane", "Drawer pane"])
    }

    @Test
    func truncationCarriesBothMessageAndSourceCursors() async {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(
                paneId: owner,
                truncation: .init(
                    omitted: [.init(source: drawer, openAsks: 3, unreadNotices: 2, next: .init(rank: 1, position: 42))],
                    remainingLiveSources: 5, nextSourcesAfter: drawer)), sourceTitles: [:])
        #expect(
            shape.messages.pages == [
                .init(sourcePaneId: drawer.uuid, rank: 1, position: 42, openAsks: 3, unreadNotices: 2)
            ])
        #expect(shape.messages.remainingLiveSources == 5)
        #expect(shape.messages.nextSourcesAfter == drawer.uuid)
    }

    static func message(
        paneId: PaneId, shape: AgentMessageShape, importance: MessageImportance, sentAt: TimeInterval = 2
    ) throws -> AgentMessageDetail {
        AgentMessageDetail(
            id: .generateUUIDv7(), sourcePaneId: paneId,
            sender: .session(
                provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: UUIDv7.generate()),
            sentAt: Date(timeIntervalSince1970: sentAt), sourceOccurredAt: nil, importance: importance,
            body: "Message", why: "Why", actions: [], shape: shape)
    }

    static func detail(
        paneId: PaneId, messages: [AgentMessageDetail] = [], drawers: [DrawerMessageGroup] = [],
        truncation: DetailTruncation? = nil, line: AgentLineDetail? = nil, session: SessionSummary? = nil,
        pullRequests: PullRequestSummaryDetail = .notApplicable
    ) -> PaneContextDetail {
        PaneContextDetail(
            paneId: paneId, revision: .init(1), agentTitle: "Agent", agentLine: line, session: session,
            messages: messages, drawerMessages: drawers, links: .unknown, pullRequests: pullRequests,
            truncation: truncation)
    }

    static func onlyRow(_ message: AgentMessageDetail) async throws -> MessageRowModel {
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(paneId: message.sourcePaneId, messages: [message]), sourceTitles: [:])
        return try #require(shape.messages.partitions.all.first?.rows.first)
    }
}
