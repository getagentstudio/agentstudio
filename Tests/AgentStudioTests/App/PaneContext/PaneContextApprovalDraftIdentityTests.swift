import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

@testable import AgentStudio

@MainActor
@Suite("Card approval draft identity", .serialized)
struct PaneContextApprovalDraftIdentityTests {
    @Test("A new canonical card request starts with its own empty optional reason")
    func theNextApprovalDoesNotInheritThePreviousReason() async throws {
        _ = NSApplication.shared
        let fixture = try await CompositionFactoryFixture.make()
        var window: NSWindow?
        var controller: PaneContextPopoverController?
        var subjectModel: ApprovalDraftSubjectModel?
        var subjectHost: NSHostingView<ApprovalDraftSubject>?
        do {
            let service = fixture.composition.paneContextService
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let first = AgentMessageId.generateUUIDv7()
            let second = AgentMessageId.generateUUIDv7()
            for (id, body) in [(first, "First approval"), (second, "Second approval")] {
                try #require(
                    await service.send(
                        .init(
                            paneId: fixture.ownerId, messageId: id, sender: try fixture.sender(binding),
                            sourceOccurredAt: nil, importance: .attention, body: body, why: nil, actions: [],
                            shape: .ask(reason: .approval, form: .approval, waiting: .nonBlocking))) == .created(id))
            }
            let adapter = PaneContextUIAdapter(service: service)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let live = readers.makePopoverController(reader: adapter, person: adapter, location: .card)
            controller = live
            await live.openCard(fixture.ownerId, selection: .ask(source: fixture.ownerId, message: first))
            let model = ApprovalDraftSubjectModel(request: try request(live, id: first))
            subjectModel = model
            let actions = PaneContextPopoverHostActions.messages(
                controller: live, readers: readers, onGoToPane: { _ in }, onActionCompleted: {},
                onActionTaskStarted: { _ in })
            let host = NSHostingView(
                rootView: ApprovalDraftSubject(
                    model: model, actions: actions, readers: readers, owner: fixture.ownerId))
            host.frame = .init(x: 0, y: 0, width: 390, height: 400)
            subjectHost = host
            let mounted = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            mounted.isReleasedWhenClosed = false
            mounted.contentView = host
            window = mounted
            mounted.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await model.applications.expectNext(in: 0, .applied(model.request))
            let initial = try #require(fields(in: host).first)
            try typeReason("Do not reuse this reason", in: initial, window: mounted)
            #expect(initial.stringValue == "Do not reuse this reason")

            try #require(await service.dismiss(messageId: first, paneId: fixture.ownerId) == .done)
            await live.openCard(fixture.ownerId, selection: .ask(source: fixture.ownerId, message: second))
            // Latest-state publication may skip an intermediate empty request. The production
            // request block must still give the next composite identity a fresh local draft.
            model.request = try request(live, id: second)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await model.applications.expectNext(in: 0, .applied(model.request))

            var visited = Set<ObjectIdentifier>()
            try #require(
                hasIdentifier(
                    "pane-context.deny.\(fixture.ownerId.uuid).\(second.uuid)", in: host, visited: &visited),
                "The native request block did not render the second composite identity")
            let next = try #require(fields(in: host).first)
            #expect(next.placeholderString == "Reason (optional)")
            #expect(next.stringValue.isEmpty, "The next approval inherited the previous request's reason")
            #expect(live.selectedAsk?.key == .init(paneId: fixture.ownerId, messageId: second))
            model.isVisible = false
            host.layoutSubtreeIfNeeded()
            try await model.applications.expectNext(in: 0, .retired)
            controller?.close()
            mounted.contentView = nil
            mounted.close()
            model.applications.receive(.ended)
            try await model.applications.finish()
            window = nil
            try await fixture.close()
        } catch {
            subjectModel?.isVisible = false
            subjectHost?.layoutSubtreeIfNeeded()
            controller?.close()
            window?.contentView = nil
            window?.close()
            subjectModel?.applications.receive(.ended)
            try? await subjectModel?.applications.finish()
            try? await fixture.close()
            throw error
        }
    }

    private func request(_ controller: PaneContextPopoverController, id: AgentMessageId) throws -> CardModel.Request {
        let selected = try #require(controller.selectedAsk)
        try #require(selected.key.messageId == id)
        return .ask(PaneContextPopoverShapingKernel.row(selected.detail, sourceLabel: nil, age: "Now"))
    }

    private func fields(in root: NSView) -> [NSTextField] {
        let own = (root as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + root.subviews.flatMap { fields(in: $0) }
    }

    private func hasIdentifier(
        _ identifier: String, in element: AnyObject, visited: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return false }
        if let accessible = element as? any NSAccessibilityProtocol {
            if accessible.accessibilityIdentifier() == identifier { return true }
            for child in accessible.accessibilityChildren() ?? [] {
                if hasIdentifier(identifier, in: child as AnyObject, visited: &visited) { return true }
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            if hasIdentifier(identifier, in: child, visited: &visited) { return true }
        }
        return false
    }

    private func typeReason(_ text: String, in field: NSTextField, window: NSWindow) throws {
        field.selectText(nil)
        let editor = try #require(window.fieldEditor(true, for: field) as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
    }
}

@MainActor
@Observable
private final class ApprovalDraftSubjectModel {
    var isVisible = true
    var request: CardModel.Request
    let applications = FactRecorder<Int, ApprovalDraftApplication>(
        vocabulary: .init(
            describeScope: { "native approval draft \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .retired }))
    init(request: CardModel.Request) { self.request = request }
}

private struct ApprovalDraftSubject: View {
    let model: ApprovalDraftSubjectModel
    let actions: MessagesPopoverActions
    let readers: PaneContextUIReaders
    let owner: PaneId
    var body: some View {
        if model.isVisible {
            PaneContextCardRequestBlock(
                request: model.request, actions: actions, readers: readers, owner: owner,
                octiconLoader: makeTestOcticonLoader(), onReadCompleted: { _, _ in }, onActionCompleted: {},
                onActionTaskStarted: { _ in }, onRelativeTimeEvent: { _ in }
            )
            .background {
                NativePresentationApplication(
                    value: model.request,
                    onApplied: { model.applications.append(scope: 0, fact: .applied($0)) },
                    onRetired: { _ in model.applications.append(scope: 0, fact: .retired) })
            }
        }
    }
}

private enum ApprovalDraftApplication: Equatable, Sendable {
    case applied(CardModel.Request)
    case retired
}
