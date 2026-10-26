import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AppKit
import Foundation
import Testing

@testable import AgentStudio

@MainActor
struct PaneContextNativeScrollFixture {
    let pane: PaneId
    let info: AgentMessageDetail
    let ports: PaneContextPopoverTestPorts
    let readers: PaneContextUIReaders

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
        readers = PaneContextUIReaders(
            sessionStatus: SessionStatusAtom(), presentation: presentation, pane: { _ in nil },
            serviceProvider: { adapter })
    }

    func window(
        kind: KindChipModel.Kind = .info, entry: PaneContextPopoverEntry? = nil
    ) -> PaneContextNativePopoverWindow {
        PaneContextNativePopoverWindow(
            paneId: pane, readers: readers, location: .pane, wallNow: Date(timeIntervalSince1970: 2),
            messageEntryKind: kind, messageEntry: entry)
    }

    func run(
        _ mounted: PaneContextNativePopoverWindow,
        body: @MainActor (PaneContextNativePopoverWindow) async throws -> Void
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

    static func scrollView(in mounted: PaneContextNativePopoverWindow) throws -> NSScrollView {
        let root = try #require(mounted.popoverWindow?.contentView)
        return try #require(descendant(NSScrollView.self, in: root))
    }

    static func frame(_ identifier: String, in mounted: PaneContextNativePopoverWindow, document: NSView) throws
        -> CGRect
    {
        let view = try #require(mounted.find(identifier) as? NSView)
        return document.convert(view.bounds, from: view)
    }

    static func assertTop(_ scroll: NSScrollView, in mounted: PaneContextNativePopoverWindow) async throws {
        let document = try #require(scroll.documentView)
        try await mounted.scrolling.viewport(scroll) { visible in
            document.isFlipped
                ? visible.minY == document.bounds.minY : visible.maxY == document.bounds.maxY
        }
        let visible = scroll.documentVisibleRect
        if document.isFlipped {
            #expect(visible.minY == document.bounds.minY)
        } else {
            #expect(visible.maxY == document.bounds.maxY)
        }
        #expect(try frame("pane-context.group.failed", in: mounted, document: document).intersects(visible))
        #expect(try !frame("pane-context.group.info", in: mounted, document: document).intersects(visible))
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

    private static func descendant<Child: NSView>(_ type: Child.Type, in root: NSView) -> Child? {
        if let found = root as? Child { return found }
        for view in root.subviews {
            if let found = descendant(type, in: view) { return found }
        }
        return nil
    }
}
