import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneContextPopoverControllerNativeTests {
    @Test
    func nativeAnswerPressReachesPersonSeamAndShowsTheCommittedReceipt() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let initial = try PaneContextPopoverControllerTests.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(initial)
        let controller = makePopoverController(ports: ports)
        await controller.open(pane)
        await ports.setDetail(
            try PaneContextPopoverControllerTests.askDetail(
                pane: pane, id: id,
                state: .answered(by: .localUser, value: .text(""), receipt: .confirmed(at: .distantPast)), revision: 2))
        let completed = FactRecorder<Int, PopoverReleaseFact>(
            vocabulary: .init(
                describeScope: { "native action \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in true }))
        var task: Task<Void, Never>?
        let actions = MessagesPopoverActions(
            answer: { messageId, source, draft in
                task = Task {
                    await controller.answerDraft(
                        messageId: .init(existingUUID: messageId),
                        source: .init(existingUUID: source), draft: draft)
                    completed.append(scope: 0, fact: .released)
                }
            },
            dismiss: { _, _ in }, dismissAllNotices: {}, markRead: { _, _ in }, runAction: { _, _, _ in },
            goToPane: { _ in }, moreMessages: { _ in }, moreSources: { _ in })
        let controls = PaneContextPopoverControlProjection.controls()
        let state = try #require(controller.state)
        let host = NSHostingView(
            rootView: MessagesPopover(
                paneId: pane.uuid, model: state.messages, controls: controls, location: .pane, actions: actions))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        var visited = Set<ObjectIdentifier>()
        let button = try #require(
            Self.find(
                host, identifier: controls.answer.identifier(in: id.uuid.uuidString),
                visited: &visited) as? AccessibilityPressBridgeView)
        #expect(button.accessibilityLabel() == LocalActionSpec.answerPaneMessage.actionSpec.label)
        #expect(button.accessibilityPerformPress())
        try await completed.expectNext(in: 0, .released)
        await task?.value
        #expect(await ports.answers == [.init(messageId: id, paneId: pane, by: .localUser, value: .text(""))])
        #expect(controller.actionFeedback == "Answered")
        #expect(
            PaneContextPopoverControllerTests.firstRow(controller)?.shape
                == .ask(
                    reason: .question, form: .freeText(placeholder: "Reply"), waiting: .nonBlocking,
                    state: .answered(by: .localUser, value: .text(""), receipt: .confirmed(at: .distantPast))))
        controller.close()
        try await completed.finish()
        try await ports.finish()
    }

    private static func find(_ element: AnyObject, identifier: String, visited: inout Set<ObjectIdentifier>)
        -> AnyObject?
    {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol {
            if accessible.accessibilityIdentifier() == identifier { return element }
            for child in accessible.accessibilityChildren() ?? [] {
                if let found = find(child as AnyObject, identifier: identifier, visited: &visited) { return found }
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            if let found = find(child, identifier: identifier, visited: &visited) { return found }
        }
        return nil
    }
}
