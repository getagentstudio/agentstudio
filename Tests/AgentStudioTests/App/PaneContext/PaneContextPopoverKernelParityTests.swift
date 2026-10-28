import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio

struct PaneContextPopoverKernelParityTests {
    struct Boundary: Sendable {
        let elapsed: TimeInterval
        let age: String
        let next: TimeInterval
    }
    static let boundaries: [Boundary] = [
        .init(elapsed: 0, age: "Now", next: 60),
        .init(elapsed: 60, age: "1 min ago", next: 120),
        .init(elapsed: 3599, age: "59 min ago", next: 3600),
        .init(elapsed: 3600, age: "1 hr ago", next: 7200),
        .init(elapsed: 86_400, age: "1 day ago", next: 172_800),
    ]

    @Test("S2 canonical complete shape and age-only output match the pre-extraction contract", arguments: boundaries)
    func completeValuesRemainIdentical(boundary: Boundary) async throws {
        let input = try Fixture()
        let initial = await PaneContextPopoverShaping.shape(
            input.detail, sourceTitles: [input.drawer: "Review"], counts: .zero,
            messagesTarget: .section(.info), now: input.date)
        #expect(initial == input.expected(messageAge: "Now", lineAge: "Now", target: .section(.info)))
        let synchronous = PaneContextPopoverShapingKernel.shape(
            input.detail, sourceTitles: [input.drawer: "Review"], counts: .zero,
            messagesTarget: .section(.info), now: input.date)
        #expect(synchronous == initial)
        let now = input.date.addingTimeInterval(boundary.elapsed)
        let messages = await PaneContextPopoverShaping.refresh(initial, content: .messages, now: now)
        #expect(messages.shape == input.expected(messageAge: boundary.age, lineAge: "Now", target: .section(.info)))
        #expect(messages.nextChange == input.date.addingTimeInterval(boundary.next))
        let synchronousMessages = PaneContextPopoverShapingKernel.refresh(initial, content: .messages, now: now)
        #expect(
            synchronousMessages.shape
                == input.expected(messageAge: boundary.age, lineAge: "Now", target: .section(.info)))
        #expect(synchronousMessages.nextChange == input.date.addingTimeInterval(boundary.next))
        let line = await PaneContextPopoverShaping.refresh(initial, content: .agentLine, now: now)
        #expect(line.shape == input.expected(messageAge: "Now", lineAge: boundary.age, target: .section(.info)))
        #expect(line.nextChange == input.date.addingTimeInterval(boundary.next))
        let absentSection = await PaneContextPopoverShaping.shape(
            input.detail, sourceTitles: [input.drawer: "Review"], counts: .zero,
            messagesTarget: .section(.done), now: now)
        #expect(absentSection == input.expected(messageAge: boundary.age, lineAge: boundary.age, target: .top))
    }

    private struct Fixture {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let ownId = AgentMessageId.generateUUIDv7()
        let drawerId = AgentMessageId.generateUUIDv7()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let detail: PaneContextDetail

        init() throws {
            let own = AgentMessageDetail(
                id: ownId, sourcePaneId: owner, sender: .pane(owner), sentAt: date,
                sourceOccurredAt: nil, importance: .info, body: "Retained info", why: "Explanation",
                actions: [.goToPane(drawer)], shape: .notice(.read))
            let child = AgentMessageDetail(
                id: drawerId, sourcePaneId: drawer, sender: .pane(drawer), sentAt: date,
                sourceOccurredAt: date.addingTimeInterval(-1), importance: .failure, body: "Full\nfailure",
                why: nil, actions: [.openFile(path: "Sources/check.swift", line: 3)], shape: .notice(.unread))
            let session = SessionSummary(
                id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init("session"),
                bindingGeneration: UUIDv7.generate(), status: .needsYou(.question),
                providerPrompts: [.init(reason: .question, observedAt: date, summary: "Provider question")],
                omittedPromptCount: 2)
            detail = PaneContextPopoverShapingTests.detail(
                paneId: owner, messages: [own], drawers: [.init(sourcePaneId: drawer, messages: [child])],
                truncation: .init(
                    omitted: [.init(source: drawer, openAsks: 3, unreadNotices: 4, next: .init(rank: 1, position: 42))],
                    remainingLiveSources: 5, nextSourcesAfter: drawer),
                line: .init(
                    summary: "A full Agent Line", refs: [.goToPane(drawer)], writer: .pane(owner), updatedAt: date),
                scopedSessions: [
                    .init(sourcePaneId: owner, session: session), .init(sourcePaneId: drawer, session: nil),
                ])
        }

        func expected(messageAge: String, lineAge: String, target: PaneContextMessagesTarget) -> PaneContextPopoverShape
        {
            let info = MessageRowModel(
                id: ownId.uuid, sourcePaneId: owner.uuid, sourceLabel: nil, sender: .pane(owner.uuid), sentAt: date,
                sourceOccurredAt: nil, body: "Retained info", bodyFont: .proportional(pointSize: 12),
                why: "Explanation", importance: .info,
                shape: .notice(.read), actions: [.goToPane(drawer.uuid)], kind: .notice(.info),
                kindIcon: .system("info.circle"), age: .init(text: messageAge), isDimmed: true, settledLabel: nil,
                availability: .noticeActions)
            let failed = MessageRowModel(
                id: drawerId.uuid, sourcePaneId: drawer.uuid, sourceLabel: "Review", sender: .pane(drawer.uuid),
                sentAt: date, sourceOccurredAt: date.addingTimeInterval(-1), body: "Full\nfailure",
                bodyFont: .monospaced(pointSize: 11), why: nil,
                importance: .failure, shape: .notice(.unread),
                actions: [.openFile(path: "Sources/check.swift", line: 3)],
                kind: .notice(.failure), kindIcon: .system("xmark"), age: .init(text: messageAge), isDimmed: false,
                settledLabel: nil, availability: .noticeActions)
            let prompt = ProviderPromptRowModel(
                sourcePaneId: owner.uuid, sourceLabel: nil, ordinal: 0, reasonText: "Needs you · question",
                observedAt: date, summary: "Provider question", kindIcon: .system("flag"), age: .init(text: messageAge))
            let groups: [MessagesGroupModel] = [
                .init(kind: .failed, items: [.message(failed)], omittedPromptCount: 0),
                .init(kind: .needsYou, items: [.providerPrompt(prompt)], omittedPromptCount: 2),
                .init(kind: .info, items: [.message(info)], omittedPromptCount: 0),
            ]
            let controls = PaneContextPopoverControlProjection.controls().filters
            let labels = ["All 0", "Needs you 0", "Failed 0", "Done 0", "Info 0"]
            let selections = [groups, [groups[1]], [groups[0]], [], [groups[2]]]
            let filters = labels.enumerated().map { index, label in
                let control = PaneContextControlModel(
                    identifier: controls[index].identifier, label: label, icon: controls[index].icon,
                    tooltip: controls[index].tooltip)
                let status = PaneContextPopoverControlProjection.control(
                    .paneMessageFilterNoLoadedContent, identifier: "pane-context.filter-no-loaded")
                return MessagesFilterModel(
                    id: index, control: control, groups: selections[index], isEnabled: index != 3,
                    noLoadedContent: index == 3 ? status : nil)
            }
            return .init(
                paneId: owner, revision: .init(1), agentTitle: "Agent",
                messages: .init(
                    groups: groups,
                    pages: [.init(sourcePaneId: drawer.uuid, rank: 1, position: 42, openAsks: 3, unreadNotices: 4)],
                    remainingLiveSources: 5, nextSourcesAfter: drawer.uuid, hasNotices: true, unreadCount: 0,
                    filters: filters),
                agentLine: .init(
                    summary: "A full Agent Line", refs: [.goToPane(drawer.uuid)], writer: .pane(owner.uuid),
                    updatedAt: date, age: .init(text: "[" + lineAge + "]")), messagesTarget: target)
        }
    }
}
