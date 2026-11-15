import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

@MainActor
struct PaneContextNativeScrollFixture {
    let pane: PaneId
    let info: AgentMessageDetail
    let ports: PaneContextPopoverTestPorts
    let owners: PaneContextTestSourceOwners

    init(pane: PaneId = .generateUUIDv7(), omitDone: Bool = false) {
        self.pane = pane
        let infoMessage = Self.message(pane, importance: .info, state: .unread, lines: 3)
        let rows: [AgentMessageDetail] =
            [
                Self.message(pane, importance: .failure, state: .unread, lines: 18),
                Self.message(pane, importance: .attention, state: .unread, lines: 18),
            ] + (omitDone ? [] : [Self.message(pane, importance: .done, state: .unread, lines: 18)]) + [
                infoMessage,
                Self.message(pane, importance: .failure, state: .read, lines: 24),
            ]
        info = infoMessage
        let truncation: DetailTruncation? =
            omitDone
            ? .init(
                omitted: [.init(source: pane, openAsks: 0, unreadNotices: 1, next: .init(rank: 1, position: 1))],
                remainingLiveSources: 0, nextSourcesAfter: nil)
            : nil
        ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: rows, truncation: truncation))
        let presentation = PaneContextPresentationAtom()
        let counts = PaneMessageCounts(
            kinds: .init(failure: 1, needsYou: 1, done: 1, info: 1), newestOpenBlockingAskId: nil)
        presentation.apply([
            pane: .set(
                .init(
                    revision: .init(1), agentTitle: nil, agentLine: nil, own: counts,
                    includingDrawers: counts, pullRequests: .notApplicable))
        ])
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: presentation, pane: { _ in nil },
            serviceProvider: { adapter })
    }

    func window(
        kind: KindChipModel.Kind = .info, entry: PaneContextPopoverEntry? = nil
    ) -> PaneContextPreparedNativeHost {
        owners.makeNativeHost(
            paneId: pane, entry: entry ?? .kind(.init(kind: kind, count: 1)),
            wallNow: Date(timeIntervalSince1970: 2))
    }

    func run(
        _ mounted: PaneContextPreparedNativeHost,
        body: @MainActor (PaneContextPreparedNativeHost) async throws -> Void
    ) async throws {
        do {
            try await body(mounted)
            try await mounted.close()
            try await ports.finish()
        } catch {
            try? await mounted.close()
            try? await ports.finish()
            throw error
        }
    }

    private static func message(
        _ pane: PaneId, importance: MessageImportance, state: NoticeState, lines: Int
    ) -> AgentMessageDetail {
        AgentMessageDetail(
            id: .generateUUIDv7(), sourcePaneId: pane, sender: .pane(pane),
            sentAt: Date(timeIntervalSince1970: 2), sourceOccurredAt: nil, importance: importance,
            body: (1...lines).map { "\(importance) message line \($0)" }.joined(separator: "\n"),
            why: nil, actions: [], shape: .notice(state))
    }

}
