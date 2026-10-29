import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

extension PaneContextApprovalNativeTests {
    @Test(
        "a native currentness check rejects cached form state until its winning owner refresh completes",
        arguments: [false, true])
    func settlementWaitsForWinningRead(cancelWinningRead: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane,
            shape: .ask(.approval, .approval, .nonBlocking, .open), importance: .attention)
        let settled = AgentMessageDetail(
            id: message.id, sourcePaneId: pane, sender: message.sender,
            sentAt: message.sentAt, sourceOccurredAt: nil, importance: .attention, body: message.body,
            why: message.why, actions: [],
            shape: .ask(
                .approval, .approval, .nonBlocking,
                .answered(by: .localUser, value: .decision(.approve, reason: nil), receipt: .notYetConfirmed)))
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]),
            heldReads: [1, 2])
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let status = SessionStatusAtom()
        let owners = PaneContextTestSourceOwners(
            sessionStatus: status, presentation: PaneContextPresentationAtom(),
            pane: { _ in nil }, serviceProvider: { adapter })
        let mounted = owners.makeNativeHost(paneId: pane, wallNow: Date(timeIntervalSince1970: 1_800_000_000))
        var monitors: [Task<Void, Never>] = []
        do {
            try await mounted.open()
            try await mounted.rendered()
            await ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [settled]))
            try mounted.native.press("pane-context.approve.\(pane.uuid).\(message.id.uuid)")
            let action = try mounted.actionProducer()
            monitors.append(
                Task {
                    await action.value
                    await ports.detailProducerEnded(beforeRead: 1)
                })
            try await ports.reads.expectNext(in: 1, .started(.init(paneId: pane, page: .first)))
            let handle = try #require(mounted.handle)
            status.apply([pane: .set(.init(status: .working(.active), evidence: .verifiedLive, promptListRevision: 1))])
            let forwarding = mounted.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
            try #require(!forwarding.isEmpty, "Canonical change did not announce its actual forwarding producer")
            for producer in forwarding { await producer.value }
            monitors.append(
                Task {
                    await action.value
                    await ports.detailProducerEnded(beforeRead: 2)
                })
            await ports.release(1)
            try await ports.reads.expectNext(in: 2, .started(.init(paneId: pane, page: .first)))
            await #expect(throws: (any Error).self) { try await mounted.renderedCurrent() }
            if cancelWinningRead {
                await mounted.bindings.beginClose(handle.key).value
                await action.value
                await #expect(throws: (any Error).self) { try await mounted.renderedCurrent() }
            } else {
                await ports.release(2)
                await action.value
                try await mounted.rendered()
                #expect(mounted.native.editableFields.isEmpty, "Native settlement: \(mounted.native.formDiagnostics())")
                #expect(mounted.native.find("pane-context.approve.\(pane.uuid).\(message.id.uuid)") == nil)
            }
            try await mounted.close()
            for monitor in monitors { await monitor.value }
            try await ports.finish()
        } catch {
            await ports.release(1)
            await ports.release(2)
            try? await mounted.close()
            for monitor in monitors { await monitor.value }
            try? await ports.finish()
            throw error
        }
    }
}
