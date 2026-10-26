import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverShapingTests {
    @Test(
        "Done and Info header chips use full unread counters, excluding their retained read rows", arguments: [0, 1, 7])
    func sectionChipsKeepFullUnreadCounts(unreadDone: Int) async throws {
        let pane = PaneId.generateUUIDv7()
        let readDone = try Self.message(paneId: pane, shape: .notice(.read), importance: .done)
        let readInfo = try Self.message(paneId: pane, shape: .notice(.read), importance: .info)
        let readFailure = try Self.message(paneId: pane, shape: .notice(.read), importance: .failure)
        var messages = [readDone, readInfo, readFailure]
        if unreadDone > 0 {
            messages.append(try Self.message(paneId: pane, shape: .notice(.unread), importance: .done))
        }
        let truncation: DetailTruncation? =
            unreadDone > 1
            ? .init(
                omitted: [
                    .init(source: pane, openAsks: 0, unreadNotices: unreadDone - 1, next: .init(rank: 1, position: 2))
                ],
                remainingLiveSources: 0, nextSourcesAfter: nil)
            : nil
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(paneId: pane, messages: messages, truncation: truncation), sourceTitles: [:],
            counts: .init(failure: 0, needsYou: 0, done: unreadDone, info: 0), now: .distantPast)
        #expect(shape.messages.groups.map(\.kind) == [.done, .info, .resolved])
        let done = try #require(shape.messages.groups.first)
        if unreadDone == 0 {
            #expect(done.header == .plain)
        } else {
            guard case .kindChip(let chip, _) = done.header else {
                Issue.record("The Done section lost its scoped unread chip: \(unreadDone)")
                return
            }
            #expect(chip == .init(kind: .done, count: unreadDone))
        }
        #expect(shape.messages.groups.dropFirst().allSatisfy { $0.header == .plain })
        #expect(Self.rows(shape).filter { $0.isDimmed }.count == 3)
        #expect(shape.messages.pages.count == (unreadDone > 1 ? 1 : 0))
    }

    @Test("E7 prompts and their omitted count do not inflate the Needs you header chip")
    func providerPromptsDoNotCountAsHeaderMessages() async throws {
        let pane = PaneId.generateUUIDv7()
        let ask = try Self.message(
            paneId: pane, shape: .ask(.question, .freeText(placeholder: nil), .nonBlocking, .open),
            importance: .attention)
        let attention = try Self.message(paneId: pane, shape: .notice(.unread), importance: .attention)
        let failure = try Self.message(paneId: pane, shape: .notice(.unread), importance: .failure)
        let session = SessionSummary(
            id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init("session"),
            bindingGeneration: UUIDv7.generate(), status: .needsYou(.question),
            providerPrompts: [.init(reason: .question, observedAt: .distantPast, summary: "A provider prompt")],
            omittedPromptCount: 4)
        let shape = await PaneContextPopoverShaping.shape(
            Self.detail(paneId: pane, messages: [ask, attention, failure], session: session), sourceTitles: [:],
            counts: .init(failure: 1, needsYou: 2, done: 0, info: 0), now: .distantPast)
        #expect(shape.messages.groups.map(\.kind) == [.failed, .needsYou])
        let failed = try #require(shape.messages.groups.first)
        let needsYou = try #require(shape.messages.groups.last)
        guard case .kindChip(let failedChip, _) = failed.header,
            case .kindChip(let needsChip, _) = needsYou.header
        else {
            Issue.record("Scoped message sections must retain their kind chips")
            return
        }
        #expect(failedChip == .init(kind: .failure, count: 1))
        #expect(needsChip == .init(kind: .needsYou, count: 2))
        #expect(needsYou.items.count == 3)
        #expect(needsYou.omittedPromptCount == 4)
    }
}
