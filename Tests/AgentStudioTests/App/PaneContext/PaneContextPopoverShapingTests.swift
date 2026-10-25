import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

struct PaneContextPopoverShapingTests {
    struct NoticeCase: Sendable {
        let state: NoticeState
        let importance: MessageImportance
        let group: MessagesGroupModel.Kind?
        let kind: KindChipModel.Kind
        let label: String?
    }
    static let notices: [NoticeCase] = [
        .init(state: .unread, importance: .failure, group: .needsYou, kind: .failure, label: nil),
        .init(state: .unread, importance: .attention, group: .needsYou, kind: .needsYou, label: nil),
        .init(state: .unread, importance: .done, group: .done, kind: .done, label: nil),
        .init(state: .unread, importance: .info, group: .info, kind: .info, label: nil),
        .init(state: .read, importance: .failure, group: .resolved, kind: .failure, label: "Read"),
        .init(state: .read, importance: .attention, group: .resolved, kind: .needsYou, label: "Read"),
        .init(state: .read, importance: .done, group: .done, kind: .done, label: nil),
        .init(state: .read, importance: .info, group: .info, kind: .info, label: nil),
        .init(
            state: .withdrawn, importance: .failure, group: .resolved, kind: .failure, label: "Withdrawn by the agent"),
        .init(
            state: .withdrawn, importance: .attention, group: .resolved, kind: .needsYou,
            label: "Withdrawn by the agent"),
        .init(state: .withdrawn, importance: .done, group: .resolved, kind: .done, label: "Withdrawn by the agent"),
        .init(state: .withdrawn, importance: .info, group: .resolved, kind: .info, label: "Withdrawn by the agent"),
        .init(state: .dismissed, importance: .failure, group: nil, kind: .failure, label: nil),
        .init(state: .dismissed, importance: .attention, group: nil, kind: .needsYou, label: nil),
        .init(state: .dismissed, importance: .done, group: nil, kind: .done, label: nil),
        .init(state: .dismissed, importance: .info, group: nil, kind: .info, label: nil),
    ]
    struct AskCase: Sendable {
        let state: AskState
        let group: MessagesGroupModel.Kind
        let label: String?
        let availability: RowActionAvailabilityModel
    }
    static let asks: [AskCase] = [
        .init(state: .open, group: .needsYou, label: nil, availability: .askForm),
        .init(
            state: .answered(by: .localUser, value: .text("yes"), receipt: .notYetConfirmed),
            group: .resolved, label: "Answer sent, waiting for the agent", availability: .none),
        .init(
            state: .answered(by: .localUser, value: .text("yes"), receipt: .confirmed(at: .distantPast)),
            group: .resolved, label: "Answered: yes", availability: .none),
        .init(
            state: .answered(by: .localUser, value: .text("yes"), receipt: .unconfirmed),
            group: .resolved, label: "Answer sent; the agent didn't confirm it", availability: .none),
        .init(state: .handedBack, group: .resolved, label: "Handed back to the agent", availability: .none),
        .init(state: .dismissed, group: .resolved, label: "Dismissed", availability: .none),
        .init(state: .expired, group: .resolved, label: "Expired", availability: .none),
        .init(state: .withdrawn, group: .resolved, label: "Withdrawn by the agent", availability: .none),
        .init(state: .stale, group: .resolved, label: "No longer current", availability: .none),
    ]

    @Test(arguments: notices)
    func noticeTableMatchesTheSpec(scenario: NoticeCase) async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try Self.message(paneId: pane, shape: .notice(scenario.state), importance: scenario.importance)
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(paneId: pane, messages: [message]),
            sourceTitles: [:], now: Date(timeIntervalSince1970: 62))
        guard let expectedGroup = scenario.group else {
            #expect(shape.messages.groups.isEmpty)
            #expect(!shape.messages.hasNotices)
            return
        }
        #expect(shape.messages.groups.map(\.kind) == [expectedGroup])
        let row = try #require(Self.rows(shape).first)
        #expect(row.kind == .notice(scenario.kind))
        #expect(row.isDimmed == (scenario.state == .read))
        #expect(row.settledLabel == scenario.label)
        #expect(row.availability == (scenario.state == .withdrawn ? .none : .noticeActions))
        #expect(row.age.text == "1 min ago")
        #expect(shape.messages.hasNotices == (scenario.state != .withdrawn))
    }

    @Test(arguments: asks, [MessageImportance.info, .attention, .done, .failure])
    func askTableMatchesTheSpec(scenario: AskCase, importance: MessageImportance) async throws {
        let pane = PaneId.generateUUIDv7()
        for waiting in [AskWaiting.nonBlocking, .blocking(deadline: .distantFuture)] {
            let message = try Self.message(
                paneId: pane,
                shape: .ask(.question, .freeText(placeholder: nil), waiting, scenario.state), importance: importance)
            let shape = await PaneContextPopoverShaping.shape(
                Self.detail(paneId: pane, messages: [message]),
                sourceTitles: [:], now: .distantPast)
            #expect(shape.messages.groups.map(\.kind) == [scenario.group])
            let row = try #require(Self.rows(shape).first)
            #expect(row.kind == (scenario.state == .open ? .openAsk : .settledAsk))
            #expect(row.kindIcon == .system("questionmark"))
            #expect(row.availability == scenario.availability)
            #expect(row.settledLabel == scenario.label)
            #expect(!row.isDimmed)
            #expect(!shape.messages.hasNotices)
        }
    }

    @Test
    func groupsAreUrgencyOrderedAndRowsAreNewestFirstAcrossSources() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let older = try Self.message(paneId: owner, shape: .notice(.unread), importance: .info, sentAt: 1)
        let newer = try Self.message(paneId: owner, shape: .notice(.unread), importance: .failure, sentAt: 3)
        let ask = try Self.message(
            paneId: drawer,
            shape: .ask(.blocked, .freeText(placeholder: nil), .nonBlocking, .open), importance: .done, sentAt: 0)
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(
                paneId: owner, messages: [older, newer], drawers: [.init(sourcePaneId: drawer, messages: [ask])]),
            sourceTitles: [drawer: "Review"], now: .distantPast)
        #expect(shape.messages.groups.map(\.kind) == [.needsYou, .info])
        #expect(Self.rows(shape).map(\.id) == [newer.id.uuid, ask.id.uuid, older.id.uuid])
        #expect(Self.rows(shape).map(\.sourceLabel) == [nil, "Review", nil])
        #expect(Self.rows(shape).map(\.sourcePaneId) == [owner.uuid, drawer.uuid, owner.uuid])
    }

    @Test
    func providedDrawerTitlesAndReadableFallbacksNeverUseIdentifiers() async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let own = try Self.message(paneId: owner, shape: .notice(.unread), importance: .info)
        let child = try Self.message(paneId: drawer, shape: .notice(.unread), importance: .attention)
        let detail = Self.detail(
            paneId: owner, messages: [own], drawers: [.init(sourcePaneId: drawer, messages: [child])])
        let titled = await PaneContextPopoverShaping.shape(
            detail, sourceTitles: [owner: "Build", drawer: "Review"], now: .distantPast)
        #expect(Self.rows(titled).map(\.sourceLabel) == ["Review", nil])
        let fallback = await PaneContextPopoverShaping.shape(detail, sourceTitles: [:], now: .distantPast)
        #expect(Self.rows(fallback).map(\.sourceLabel) == ["Drawer pane", nil])
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
                    remainingLiveSources: 5, nextSourcesAfter: drawer)), sourceTitles: [:], now: .distantPast)
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
        pullRequests: PullRequestSummaryDetail = .notApplicable,
        scopedSessions: [PaneContextScopedSessionSummary]? = nil
    ) -> PaneContextDetail {
        let sources =
            scopedSessions ?? [.init(sourcePaneId: paneId, session: session)]
            + drawers.map { PaneContextScopedSessionSummary(sourcePaneId: $0.sourcePaneId, session: nil) }
        let hasNotices = (messages + drawers.flatMap(\.messages)).contains {
            if case .notice(let state) = $0.shape { return state == .unread || state == .read }
            return false
        }
        return PaneContextDetail(
            paneId: paneId, revision: .init(1), agentTitle: "Agent", agentLine: line,
            scopedSessions: sources, hasDismissibleNotices: hasNotices,
            messages: messages, drawerMessages: drawers, links: .unknown, pullRequests: pullRequests,
            truncation: truncation)
    }

    static func rows(_ shape: PaneContextPopoverShape) -> [MessageRowModel] {
        shape.messages.groups.flatMap(\.items).compactMap {
            if case .message(let row) = $0 { return row }
            return nil
        }
    }
    static func prompts(_ shape: PaneContextPopoverShape) -> [ProviderPromptRowModel] {
        shape.messages.groups.flatMap(\.items).compactMap {
            if case .providerPrompt(let row) = $0 { return row }
            return nil
        }
    }

    static func onlyRow(_ message: AgentMessageDetail) async throws -> MessageRowModel {
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(paneId: message.sourcePaneId, messages: [message]), sourceTitles: [:], now: .distantPast)
        return try #require(rows(shape).first)
    }
}
