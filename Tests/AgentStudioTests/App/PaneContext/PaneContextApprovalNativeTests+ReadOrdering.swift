import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

extension PaneContextApprovalNativeTests {
    @Test("a native settlement wait joins the later winning read before accepting cached form state")
    func settlementWaitsForWinningRead() async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .ask(.approval, .approval, .nonBlocking, .open), importance: .attention)
        let settled = AgentMessageDetail(
            id: message.id, sourcePaneId: pane, sender: message.sender, sentAt: message.sentAt,
            sourceOccurredAt: nil, importance: .attention, body: message.body, why: message.why, actions: [],
            shape: .ask(
                .approval, .approval, .nonBlocking,
                .answered(by: .localUser, value: .decision(.approve, reason: nil), receipt: .notYetConfirmed)))
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]), heldReads: [1, 2])
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let status = SessionStatusAtom()
        let readers = PaneContextUIReaders(
            sessionStatus: status, presentation: PaneContextPresentationAtom(), pane: { _ in nil },
            serviceProvider: { adapter })
        let mounted = PaneContextNativePopoverWindow(
            paneId: pane, readers: readers, location: .pane,
            wallNow: Date(timeIntervalSince1970: 1_800_000_000))
        var rendering: Task<Void, any Error>?
        do {
            try await mounted.open()
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [settled]))
            try mounted.press("pane-context.approve.\(pane.uuid).\(message.id.uuid)")
            try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
            status.apply([pane: .set(.init(status: .working(.active), evidence: .verifiedLive, promptListRevision: 1))])
            mounted.layout()
            try await ports.reads.expectNext(in: 2, .started(.init(paneId: pane, page: .first)))
            await ports.release(1)
            try await mounted.actionCompleted()
            #expect(mounted.editableFields.count == 1)
            let waiter = Task {
                defer { mounted.facts.append(scope: .projectionWait, fact: .taskEnded) }
                try await mounted.rendered()
            }
            rendering = waiter
            let first = try await mounted.facts.expectNext(
                in: .projectionWait, where: { _ in true }, "read-wait entry or render-task terminal outcome")
            #expect(first == .waitingForRead(1), "The held later read must precede native rebind: \(first)")
            await ports.release(2)
            if first != .waitingForRead(1) { try await mounted.readCompleted() }
            try await waiter.value
            if first == .waitingForRead(1) {
                #expect(mounted.editableFields.isEmpty)
                #expect(mounted.find("pane-context.approve.\(pane.uuid).\(message.id.uuid)") == nil)
            }
            try await mounted.close()
            try await ports.finish()
        } catch {
            await ports.release(1)
            await ports.release(2)
            mounted.retireView()
            try? await rendering?.value
            try? await mounted.close()
            try? await ports.finish()
            throw error
        }
    }
}
