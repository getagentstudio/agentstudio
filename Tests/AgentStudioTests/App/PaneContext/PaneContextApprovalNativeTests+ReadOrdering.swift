import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

extension PaneContextApprovalNativeTests {
    @Test(
        "a native settlement wait joins or rejects the winning read before accepting cached form state",
        arguments: [false, true])
    func settlementWaitsForWinningRead(cancelWinningRead: Bool) async throws {
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
        await mounted.observeDetailReads(from: ports)
        do {
            try await mounted.open()
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [settled]))
            try mounted.press("pane-context.approve.\(pane.uuid).\(message.id.uuid)")
            try await mounted.detailReadStarted(
                1, request: .init(paneId: pane, page: .first), producer: .action(0))
            status.apply([pane: .set(.init(status: .working(.active), evidence: .verifiedLive, promptListRevision: 1))])
            mounted.layout()
            try await mounted.detailReadStarted(
                2, request: .init(paneId: pane, page: .first), producer: .opening(1))
            await ports.release(1)
            try await mounted.actionCompleted()
            #expect(mounted.controller?.state?.messages.messageRows.filter { $0.availability == .askForm }.count == 1)
            let waiter = Task {
                defer { mounted.facts.append(scope: .projectionWait, fact: .taskEnded) }
                try await mounted.rendered()
            }
            rendering = waiter
            let first = try await mounted.facts.expectNext(
                in: .projectionWait, where: { _ in true }, "read-wait entry or render-task terminal outcome")
            try #require(first == .waitingForRead(1), "The held later read must precede native rebind: \(first)")
            if cancelWinningRead {
                mounted.cancelReads()
                await #expect(throws: (any Error).self) { try await waiter.value }
            } else {
                await ports.release(2)
                try await waiter.value
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
