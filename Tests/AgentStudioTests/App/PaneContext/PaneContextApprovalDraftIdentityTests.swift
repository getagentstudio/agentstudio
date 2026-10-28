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
        var prepared: PaneContextPreparedDetailFixture?
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
            let detailOwner = PaneContextPreparedDetailFixture(adapter: adapter, wallNow: fixture.now)
            prepared = detailOwner
            detailOwner.setSource(
                PaneContextPreparedDetailFixture.source(
                    fixture.ownerId,
                    display: await service.readDisplay(paneId: fixture.ownerId)), for: fixture.ownerId)
            let handle = try await detailOwner.open(fixture.ownerId, location: .card, content: .card)
            let readers = PaneContextUIReaders(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, popoverBindings: detailOwner.bindings)
            let model = ApprovalDraftSubjectModel(request: try request(handle, id: first))
            subjectModel = model
            let actions = PaneContextPopoverHostActions.messages(
                handle: handle, bindings: detailOwner.bindings, isCurrentOpening: { true },
                onGoToPane: { _ in }, onActionCompleted: {},
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
            #expect(
                model.applications.last == .applied(model.request),
                "The real native request must apply in its owning update")
            let initial = try #require(fields(in: host).first)
            try typeReason("Do not reuse this reason", in: initial, window: mounted)
            #expect(initial.stringValue == "Do not reuse this reason")

            try #require(await service.dismiss(messageId: first, paneId: fixture.ownerId) == .done)
            detailOwner.setSource(
                PaneContextPreparedDetailFixture.source(
                    fixture.ownerId,
                    display: await service.readDisplay(paneId: fixture.ownerId)), for: fixture.ownerId)
            try await detailOwner.refresh(handle)
            // Latest-state publication may skip an intermediate empty request. The production
            // request block must still give the next composite identity a fresh local draft.
            model.request = try request(handle, id: second)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            #expect(
                model.applications.last == .applied(model.request),
                "The real native request must apply in its owning update")

            var visited = Set<ObjectIdentifier>()
            try #require(
                hasIdentifier(
                    "pane-context.deny.\(fixture.ownerId.uuid).\(second.uuid)", in: host, visited: &visited),
                "The native request block did not render the second composite identity")
            let next = try #require(fields(in: host).first)
            #expect(next.placeholderString == "Reason (optional)")
            #expect(next.stringValue.isEmpty, "The next approval inherited the previous request's reason")
            #expect(handle.atom.value?.selectedAsk?.key == .init(paneId: fixture.ownerId, messageId: second))
            model.isVisible = false
            host.layoutSubtreeIfNeeded()
            #expect(model.applications.last == .retired)
            try await prepared?.finish()
            mounted.contentView = nil
            mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            subjectModel?.isVisible = false
            subjectHost?.layoutSubtreeIfNeeded()
            try? await prepared?.finish()
            window?.contentView = nil
            window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func request(_ handle: PaneContextPopoverConsumerHandle, id: AgentMessageId) throws -> CardModel.Request {
        let value = try #require(handle.atom.value)
        try #require(value.selectedAsk?.key.messageId == id)
        return try #require(value.card).request
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
    @ObservationIgnored var applications: [ApprovalDraftApplication] = []
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
                octiconLoader: makeTestOcticonLoader(), onActionCompleted: {},
                onActionTaskStarted: { _ in }
            )
            .background {
                NativePresentationApplication(
                    value: model.request,
                    onApplied: { model.applications.append(.applied($0)) },
                    onRetired: { _ in model.applications.append(.retired) })
            }
        }
    }
}

private enum ApprovalDraftApplication: Equatable, Sendable {
    case applied(CardModel.Request)
    case retired
}
