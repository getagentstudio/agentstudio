import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverActionViewTests {
    @Test
    func messageButtonsKeepSourceIdentityAndDriveEveryCallback() async throws {
        let paneId = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let pr = try ForgePullRequestIdentity(host: "github.com", owner: "org", repository: "repo", number: 7)
        let message = AgentMessageDetail(
            id: id, sourcePaneId: paneId,
            sender: .session(
                provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: UUIDv7.generate()),
            sentAt: .distantPast,
            sourceOccurredAt: nil, importance: .attention, body: "Question", why: nil,
            actions: [.openFile(path: "file.swift", line: 3), .openPullRequest(pr), .goToPane(paneId)],
            shape: .ask(
                .question, .choice(options: [.init(id: try .init("allow"), label: "Allow")], allowsMultiple: false),
                .nonBlocking, .open))
        let shaped = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(
                paneId: paneId, messages: [message],
                truncation: .init(
                    omitted: [.init(source: paneId, openAsks: 1, unreadNotices: 0, next: .init(rank: 0, position: 12))],
                    remainingLiveSources: 2, nextSourcesAfter: paneId)), sourceTitles: [:])
        let controls = PaneContextPopoverControlProjection.controls()
        var submitted: AskFormDraft?
        var dismissed: UUID?
        var actionsRun: [MessageActionModel] = []
        var focused: UUID?
        var moreMessages: MessagePageCursorModel?
        var moreSources: UUID?
        let actions = MessagesPopoverActions(
            answer: { messageId, source, draft in
                #expect(messageId == id.uuid)
                #expect(source == paneId.uuid)
                submitted = draft
            },
            dismiss: { messageId, source in
                #expect(source == paneId.uuid)
                dismissed = messageId
            },
            dismissAllNotices: {},
            markRead: { _, _ in },
            runAction: { messageId, source, action in
                #expect(messageId == id.uuid)
                #expect(source == paneId.uuid)
                actionsRun.append(action)
            },
            goToPane: { focused = $0 }, moreMessages: { moreMessages = $0 }, moreSources: { moreSources = $0 })
        try Self.withMounted(
            MessagesPopover(
                paneId: paneId.uuid, model: shaped.messages, controls: controls, location: .pane, actions: actions)
        ) { host in
            try Self.press(host, "pane-context.choice.allow.\(id.uuid)", label: "Allow")
            host.layoutSubtreeIfNeeded()
            try Self.press(host, controls.answer.identifier(in: id.uuid.uuidString), label: controls.answer.label)
            #expect(submitted?.selectedChoices == ["allow"])
            try Self.press(host, controls.dismiss.identifier(in: id.uuid.uuidString), label: controls.dismiss.label)
            #expect(dismissed == id.uuid)
            try Self.press(host, controls.openFile.identifier(in: id.uuid.uuidString), label: controls.openFile.label)
            try Self.press(
                host, controls.openPullRequest.identifier(in: id.uuid.uuidString), label: controls.openPullRequest.label
            )
            try Self.press(host, controls.goToPane.identifier(in: id.uuid.uuidString), label: controls.goToPane.label)
            #expect(
                actionsRun == [
                    .openFile(path: "file.swift", line: 3),
                    .openPullRequest(.init(host: "github.com", owner: "org", repository: "repo", number: 7)),
                    .goToPane(paneId.uuid),
                ])
            try Self.press(host, controls.goToPane.identifier, label: controls.goToPane.label)
            #expect(focused == paneId.uuid)
            try Self.press(
                host, controls.moreMessages.identifier(in: paneId.uuid.uuidString), label: controls.moreMessages.label)
            #expect(moreMessages?.position == 12)
            try Self.press(host, controls.moreSources.identifier, label: controls.moreSources.label)
            #expect(moreSources == paneId.uuid)
        }
    }

    @Test
    func sidebarNoticesCanBeOpenedReadAndDismissed() async throws {
        let paneId = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: paneId, shape: .notice(.unread), importance: .info)
        let shaped = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [message]), sourceTitles: [:])
        let controls = PaneContextPopoverControlProjection.controls()
        var readCount = 0
        var dismissed = false
        var dismissedAll = false
        let actions = MessagesPopoverActions(
            answer: { _, _, _ in }, dismiss: { _, _ in dismissed = true },
            dismissAllNotices: { dismissedAll = true }, markRead: { _, _ in readCount += 1 },
            runAction: { _, _, _ in }, goToPane: { _ in }, moreMessages: { _ in }, moreSources: { _ in })
        try Self.withMounted(
            MessagesPopover(
                paneId: paneId.uuid, model: shaped.messages, controls: controls, location: .sidebar, actions: actions)
        ) { host in
            try Self.press(
                host, controls.messageDetails.identifier(in: message.id.uuid.uuidString),
                label: controls.messageDetails.label)
            host.layoutSubtreeIfNeeded()
            let before = readCount
            try Self.press(
                host, controls.markRead.identifier(in: message.id.uuid.uuidString), label: controls.markRead.label)
            #expect(readCount == before + 1)
            try Self.press(
                host, controls.dismiss.identifier(in: message.id.uuid.uuidString), label: controls.dismiss.label)
            #expect(dismissed)
            try Self.press(host, controls.dismissAllNotices.identifier, label: controls.dismissAllNotices.label)
            #expect(dismissedAll)
            #expect(Self.find(host, controls.answer.identifier(in: message.id.uuid.uuidString)) == nil)
        }
    }

    @Test
    func sidebarAsksOfferNavigationWithoutAnswerOrMessageActions() async throws {
        let paneId = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: paneId,
            shape: .ask(.approval, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open),
            importance: .attention)
        let shaped = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [message]), sourceTitles: [:])
        let controls = PaneContextPopoverControlProjection.controls()
        var focused: UUID?
        let actions = MessagesPopoverActions(
            answer: { _, _, _ in }, dismiss: { _, _ in },
            dismissAllNotices: {},
            markRead: { _, _ in },
            runAction: { _, _, _ in }, goToPane: { focused = $0 }, moreMessages: { _ in }, moreSources: { _ in })
        try Self.withMounted(
            MessagesPopover(
                paneId: paneId.uuid, model: shaped.messages, controls: controls, location: .sidebar, actions: actions)
        ) { host in
            #expect(Self.find(host, controls.answer.identifier(in: message.id.uuid.uuidString)) == nil)
            #expect(Self.find(host, controls.dismiss.identifier(in: message.id.uuid.uuidString)) == nil)
            try Self.press(host, controls.goToPane.identifier, label: controls.goToPane.label)
            #expect(focused == paneId.uuid)
        }
    }

    @Test
    func pullRequestButtonsDriveOpenAndNavigation() throws {
        let worktreeId = UUIDv7.generate()
        let model = GitPRSummaryPopoverModel(
            state: .allGood,
            members: [
                .pullRequest(worktreeId: worktreeId, number: 7, checks: .passed, review: .approved),
                .unknown(worktreeId: UUIDv7.generate()),
            ])
        let controls = PaneContextPopoverControlProjection.controls()
        var opened: UUID?
        var focused = false
        try Self.withMounted(
            GitPRSummaryPopover(
                model: model, presentation: PaneContextPopoverControlProjection.pullRequestPresentation(model),
                controls: controls, onGoToPane: { focused = true },
                onOpenPullRequest: { id, number in
                    #expect(number == 7)
                    opened = id
                })
        ) { host in
            try Self.press(
                host, controls.openPullRequest.identifier(in: worktreeId.uuidString),
                label: controls.openPullRequest.label)
            #expect(opened == worktreeId)
            try Self.press(host, controls.goToPane.identifier, label: controls.goToPane.label)
            #expect(focused)
        }
    }

    private static func withMounted<Content: View>(
        _ content: Content, assertions: (NSHostingView<Content>) throws -> Void
    ) throws {
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try assertions(host)
    }

    private static func press(_ root: NSView, _ identifier: String, label: String) throws {
        let button = try #require(
            Self.find(root, identifier) as? AccessibilityPressBridgeView, "Missing control: \(identifier)")
        #expect(button.accessibilityLabel() == label)
        #expect(button.accessibilityPerformPress())
    }

    private static func find(_ root: AnyObject, _ identifier: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        return find(root, identifier, visited: &visited)
    }

    private static func find(_ element: AnyObject, _ identifier: String, visited: inout Set<ObjectIdentifier>)
        -> AnyObject?
    {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol {
            if accessible.accessibilityIdentifier() == identifier { return element }
            for child in accessible.accessibilityChildren() ?? [] {
                if let found = find(child as AnyObject, identifier, visited: &visited) { return found }
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            if let found = find(child, identifier, visited: &visited) { return found }
        }
        return nil
    }
}
