import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Approval forms on every native surface", .serialized)
struct PaneContextApprovalNativeTests {
    struct Surface: Sendable {
        let location: PaneContextPopoverLocation
        let width: Double
        static let all = [PaneContextPopoverLocation.sidebar, .pane, .card].flatMap { location in
            [390.0, 520.0, 1400.0].map { Self(location: location, width: $0) }
        }
    }
    @Test(
        "G14/S15 Approve with reason and Deny without one submit once through the real service and rebind",
        arguments: [true, false], Surface.all)
    func nativeApprovalSubmitsExactlyOnce(approve: Bool, surface: Surface) async throws {
        let location = surface.location
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let owner = store.createPane(title: "Approval owner")
        defer { store.removePane(owner.id) }
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: owner.id))
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: try fixture.sender(binding),
                        sourceOccurredAt: nil, importance: .attention, body: "Approve running the migration?",
                        why: nil, actions: [], shape: .ask(reason: .approval, form: .approval, waiting: .nonBlocking)))
                    == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let person = PaneContextNativePersonRecorder(service)
            let adapter = PaneContextUIAdapter(reader: service, person: person)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted: PaneContextPreparedNativeHost
            if location == .card {
                mounted = owners.makeNativeCardHost(
                    context: .project(paneId: owner.id, store: store),
                    wallNow: fixture.now, viewportWidth: CGFloat(surface.width))
            } else {
                mounted = owners.makeNativeHost(
                    paneId: fixture.ownerId,
                    entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                    location: location,
                    wallNow: fixture.now, viewportWidth: CGFloat(surface.width))
            }
            window = mounted
            try await mounted.open()
            try await renderApproval(mounted, location: location, phase: .initial)
            let scope = "\(fixture.ownerId.uuid).\(id.uuid)"
            try #require(mounted.native.window.contentView?.bounds.width == CGFloat(surface.width))
            try assertS15Placement(mounted.native, scope: scope, location: location)
            #expect(
                (mounted.native.find("pane-context.approve.\(scope)") as? any NSAccessibilityProtocol)?
                    .accessibilityLabel()
                    == "Approve")
            #expect(
                (mounted.native.find("pane-context.deny.\(scope)") as? any NSAccessibilityProtocol)?
                    .accessibilityLabel()
                    == "Deny")
            #expect(mounted.native.editableFields.count == 1)
            #expect(mounted.native.find("pane-context.submit.\(scope)") == nil)
            let reason = approve ? "Reviewed the migration" : nil
            if let reason {
                try mounted.native.typeText(placeholder: location == .card ? "Reason (optional)" : "", value: reason)
            }

            try mounted.native.press("pane-context.\(approve ? "approve" : "deny").\(scope)")
            try await mounted.actionCompleted()
            let expected = AskAnswerValue.decision(approve ? .approve : .deny, reason: reason)
            try #require(
                await person.answers == [
                    .init(
                        messageId: id, paneId: fixture.ownerId, by: .localUser, value: expected)
                ])
            try await renderApproval(mounted, location: location, phase: .answered)
            #expect(mounted.native.editableFields.isEmpty)
            for prefix in ["pane-context.approve", "pane-context.deny", "pane-context.submit", "pane-context.dismiss"] {
                #expect(mounted.native.find(prefix + "." + scope) == nil, "Settled approval retained \(prefix)")
            }
            try await assertStoredApproval(
                service, source: fixture.ownerId, id: id,
                sender: try fixture.sender(binding), expected: expected)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func renderApproval(
        _ mounted: PaneContextPreparedNativeHost, location: PaneContextPopoverLocation, phase: ApprovalRenderingPhase
    ) async throws {
        do {
            if location == .card { try await mounted.renderedCard() } else { try await mounted.rendered() }
        } catch {
            throw ApprovalRenderingFailure(phase: phase, underlying: error)
        }
    }

    private func assertS15Placement(
        _ mounted: PaneContextNativePopoverWindow, scope: String, location: PaneContextPopoverLocation
    ) throws {
        mounted.layout()
        let body = try #require(
            mounted.find("pane-context.message-text." + scope) as? any NSAccessibilityProtocol)
        let dismiss = try #require(mounted.find("pane-context.dismiss." + scope) as? any NSAccessibilityProtocol)
        let approve = try #require(mounted.find("pane-context.approve." + scope) as? any NSAccessibilityProtocol)
        let deny = try #require(mounted.find("pane-context.deny." + scope) as? any NSAccessibilityProtocol)
        let reason = try #require(mounted.editableFields.first)
        if location != .card {
            let panel = try #require(mounted.find("pane-context.popover-panel") as? NSView)
            #expect(panel.bounds.width == 480)
            let reasonLabel = try #require(
                mounted.find("pane-context.field." + scope + ".reason-label") as? any NSAccessibilityProtocol)
            #expect(reasonLabel.accessibilityLabel() == "Reason (optional)")
            #expect(
                reasonLabel.accessibilityFrame().minY >= reason.accessibilityFrame().maxY,
                "The persistent catalog label belongs above the blank native reason field")
        }
        let bodyFrame = body.accessibilityFrame()
        let dismissFrame = dismiss.accessibilityFrame()
        let reasonFrame = reason.accessibilityFrame()
        #expect(body.accessibilityLabel() == "Approve running the migration? Now")
        #expect(bodyFrame.width > 0 && dismissFrame.width > 0 && reasonFrame.width > 0)
        #expect(dismissFrame.minX >= bodyFrame.maxX, "S15 Dismiss belongs beside the body")
        #expect(
            dismissFrame.maxY >= bodyFrame.minY && bodyFrame.maxY >= dismissFrame.minY,
            "S15 body and Dismiss must share the row head")
        #expect(bodyFrame.minY >= reasonFrame.maxY, "S15 body must precede the form")
        #expect(reasonFrame.minY >= approve.accessibilityFrame().maxY, "S15 reason must precede decisions")
        if location == .card {
            let unread = try #require(mounted.find("paneManagement.card.unread") as? any NSAccessibilityProtocol)
            #expect(
                unread.accessibilityFrame().maxY <= deny.accessibilityFrame().minY,
                "S15 unread summary must follow the request block")
        }
    }

    private func assertStoredApproval(
        _ service: PaneContextService, source: PaneId, id: AgentMessageId,
        sender: AgentMessageSender, expected: AskAnswerValue
    ) async throws {
        let result = await service.readMessage(source: source, message: id)
        let stored = try #require(
            { () -> AgentMessageDetail? in
                if case .found(let detail) = result { return detail }
                return nil
            }())
        #expect(
            stored.shape
                == .ask(
                    .approval, .approval, .nonBlocking,
                    .answered(by: .localUser, value: expected, receipt: .notYetConfirmed)))
        let read = await service.changes(.init(paneId: source, writer: sender, after: .init(0)))
        let changes = try #require(
            { () -> PaneMessageChangesPage? in
                if case .page(let page) = read { return page }
                return nil
            }())
        #expect(changes.entries.map(\.kind) == [.answer(expected)])
    }
}

private struct ApprovalRenderingFailure: Error {
    let phase: ApprovalRenderingPhase
    let underlying: any Error
}

private enum ApprovalRenderingPhase: Sendable { case initial, answered }
