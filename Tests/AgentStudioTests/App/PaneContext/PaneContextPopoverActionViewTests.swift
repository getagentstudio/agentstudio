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
    @Test("Choice binding input waits for native Submit; message controls keep every source identity and callback")
    func choiceBindingAndNativeSubmitKeepSourceIdentityAndEveryCallback() async throws {
        let paneId = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let noticeId = AgentMessageId.generateUUIDv7()
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
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: paneId,
            messages: [
                message,
                .init(
                    id: noticeId, sourcePaneId: paneId,
                    sender: message.sender, sentAt: .distantPast, sourceOccurredAt: nil, importance: .info,
                    body: "A targeted notice", why: nil, actions: message.actions, shape: .notice(.unread)),
            ],
            truncation: .init(
                omitted: [.init(source: paneId, openAsks: 1, unreadNotices: 0, next: .init(rank: 0, position: 12))],
                remainingLiveSources: 2, nextSourcesAfter: paneId))
        let shaped = await PaneContextPopoverShaping.shape(
            detail, sourceTitles: [:], counts: .zero, now: .distantPast)
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
            runAction: { messageId, source, action in
                #expect(messageId == noticeId.uuid)
                #expect(source == paneId.uuid)
                actionsRun.append(action)
            },
            goToPane: { focused = $0 }, moreMessages: { moreMessages = $0 }, moreSources: { moreSources = $0 },
            dismissPopover: {}, captureBodyGeometry: { _, _ in })
        let inputs = Self.interactions(shaped.messages)
        try Self.withMounted(
            MessagesPopover(
                paneId: paneId.uuid, model: shaped.messages, controls: controls, octiconLoader: makeTestOcticonLoader(),
                location: .pane, height: .contentSized(maximumHeight: 480), actions: actions, interactions: inputs)
        ) { host in
            let scope = "\(paneId.uuid).\(id.uuid)"
            let noticeScope = "\(paneId.uuid).\(noticeId.uuid)"
            #expect(submitted == nil)
            var draft = AskFormDraft()
            draft.setChoice("allow", selected: true, allowsMultiple: false)
            inputs.draft(.init(sourcePaneId: paneId.uuid, messageId: id.uuid)).wrappedValue = draft
            host.layoutSubtreeIfNeeded()
            #expect(submitted == nil, "Ordinary choice input must not invoke the answer callback")
            try Self.press(host, controls.submit.identifier(in: scope), label: controls.submit.label)
            #expect(submitted?.selectedChoices == ["allow"])
            try Self.press(host, controls.dismiss.identifier(in: scope), label: controls.dismiss.label)
            #expect(dismissed == id.uuid)
            try Self.press(host, controls.openFile.identifier(in: noticeScope + ".0"), label: controls.openFile.label)
            try Self.press(
                host, controls.openPullRequest.identifier(in: noticeScope + ".1"), label: controls.openPullRequest.label
            )
            try Self.press(
                host, controls.goToPane.identifier(in: noticeScope + ".2"), label: controls.goToPane.accessibilityLabel)
            #expect(
                actionsRun == [
                    .openFile(path: "file.swift", line: 3),
                    .openPullRequest(.init(host: "github.com", owner: "org", repository: "repo", number: 7)),
                    .goToPane(paneId.uuid),
                ])
            try Self.press(host, controls.goToPane.identifier, label: controls.goToPane.accessibilityLabel)
            #expect(focused == paneId.uuid)
            try Self.press(
                host, controls.moreMessages.identifier(in: paneId.uuid.uuidString), label: controls.moreMessages.label)
            #expect(moreMessages?.position == 12)
            try Self.press(host, controls.moreSources.identifier, label: controls.moreSources.label)
            #expect(moreSources == paneId.uuid)
        }
    }

    @Test
    func sidebarNoticesAreFlatAndDismissibleWithoutReadControls() async throws {
        let paneId = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: paneId, shape: .notice(.unread), importance: .info)
        let shaped = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [message]), sourceTitles: [:],
            counts: .zero, now: .distantPast)
        let controls = PaneContextPopoverControlProjection.controls()
        var dismissed = false
        var dismissedAll = false
        let actions = MessagesPopoverActions(
            answer: { _, _, _ in }, dismiss: { _, _ in dismissed = true },
            dismissAllNotices: { dismissedAll = true },
            runAction: { _, _, _ in }, goToPane: { _ in }, moreMessages: { _ in }, moreSources: { _ in },
            dismissPopover: {}, captureBodyGeometry: { _, _ in })
        try Self.withMounted(
            MessagesPopover(
                paneId: paneId.uuid, model: shaped.messages, controls: controls, octiconLoader: makeTestOcticonLoader(),
                location: .sidebar, height: .contentSized(maximumHeight: 480), actions: actions,
                interactions: Self.interactions(shaped.messages))
        ) { host in
            let scope = "\(paneId.uuid).\(message.id.uuid)"
            #expect(Self.find(host, "pane-context.message-details.\(scope)") == nil)
            #expect(Self.find(host, "pane-context.mark-read.\(scope)") == nil)
            try Self.press(
                host, controls.dismiss.identifier(in: scope), label: controls.dismiss.label)
            #expect(dismissed)
            try Self.press(
                host, controls.dismissAllNotices.identifier, label: controls.dismissAllNotices.accessibilityLabel)
            #expect(dismissedAll)
            #expect(Self.find(host, controls.submit.identifier(in: scope)) == nil)
        }
    }

    @Test
    func sidebarAsksOfferAnswerDismissAndNavigationWithoutANoticeFooter() async throws {
        let paneId = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: paneId,
            shape: .ask(.approval, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open),
            importance: .attention)
        let shaped = await PaneContextPopoverShaping.shape(
            PaneContextPopoverShapingTests.detail(paneId: paneId, messages: [message]), sourceTitles: [:],
            counts: .zero, now: .distantPast)
        let controls = PaneContextPopoverControlProjection.controls()
        var focused: UUID?
        var answers = 0
        var dismissals = 0
        let actions = MessagesPopoverActions(
            answer: { _, _, _ in answers += 1 }, dismiss: { _, _ in dismissals += 1 },
            dismissAllNotices: {},
            runAction: { _, _, _ in }, goToPane: { focused = $0 }, moreMessages: { _ in }, moreSources: { _ in },
            dismissPopover: {}, captureBodyGeometry: { _, _ in })
        try Self.withMounted(
            MessagesPopover(
                paneId: paneId.uuid, model: shaped.messages, controls: controls, octiconLoader: makeTestOcticonLoader(),
                location: .sidebar, height: .contentSized(maximumHeight: 480), actions: actions,
                interactions: Self.interactions(shaped.messages))
        ) { host in
            let scope = "\(paneId.uuid).\(message.id.uuid)"
            try Self.press(host, controls.submit.identifier(in: scope), label: "Submit")
            try Self.press(host, controls.dismiss.identifier(in: scope), label: "Dismiss")
            #expect(answers == 1)
            #expect(dismissals == 1)
            #expect(Self.find(host, controls.dismissAllNotices.identifier) == nil)
            try Self.press(host, controls.goToPane.identifier, label: controls.goToPane.accessibilityLabel)
            #expect(focused == paneId.uuid)
        }
    }

    private static func interactions(_ model: MessagesPopoverModel) -> MessagesPopoverBindings {
        let owner = PaneContextPopoverInteractionState()
        owner.beginOpening(1, initialSelection: 15)
        let versions = Dictionary(uniqueKeysWithValues: model.messageRows.map { ($0.key, UUIDv7.generate()) })
        return owner.bindings(versions: versions, opening: 1, currentVersions: { versions })
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
