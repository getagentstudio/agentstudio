import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextPopoverRefreshOwnerTests {
    @Test("F11 a newer host handshake cannot acknowledge an older host's held invalidation")
    func aHandshakeCannotLoseAnotherHostsInvalidation() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        let deliveryHeld = HeldStep<Void>("committed source notification before owner ingress")
        var delivery: Task<Void, Never>?
        do {
            let older = try await harness.open()
            _ = try await harness.completed(older.initialExecution)
            try #require(await harness.owner.scheduledWake() == nil, "The older empty host must have no deadline")
            let message = try PaneContextPopoverShapingTests.message(
                paneId: pane, shape: .notice(.unread), importance: .info)
            await harness.ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
            await harness.invalidations.bump(pane, emit: false)
            try #require(await harness.invalidations.invalidationGenerations(for: [pane]) == [pane: 1])
            let epoch = older.initialExecution.serviceEpoch
            delivery = Task {
                defer { deliveryHeld.retire() }
                do { try await deliveryHeld.arrive(()) } catch { return }
                // Drive the actual ingress handler. Transport is outside this owner-scope proof.
                await harness.owner.sourceInvalidated(.init(sourcePaneId: pane, generation: 1), epoch: epoch)
            }
            try await deliveryHeld.firstArrival()
            let newerKey = PaneContextPopoverConsumerKey(
                hostId: UUIDv7.generate(), surface: .paneMessages, paneId: pane)
            let newer = try await harness.open(newerKey)
            _ = try await harness.completed(newer.initialExecution, for: newerKey)
            #expect(await harness.projections.shapes[newerKey]?.messages.messageRows.map(\.id) == [message.id.uuid])
            #expect(await harness.projections.shapes[harness.key]?.messages.messageRows.isEmpty == true)

            deliveryHeld.release()
            await delivery?.value
            let trailing = try await harness.timer()
            try #require(
                trailing.deadline == harness.clock.now.advanced(by: .seconds(10)),
                "The held invalidation must schedule the older host's cadence-respecting trailing read")
            harness.clock.advance(by: .seconds(10))
            await trailing.task.value
            let refreshed = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(refreshed.id != older.initialExecution.id, "The older host never refreshed")
            _ = try await harness.completed(refreshed)
            #expect(await harness.projections.shapes[harness.key]?.messages.messageRows.map(\.id) == [message.id.uuid])
            #expect(await harness.projections.requests.filter { $0.identity.key == harness.key }.count == 2)
            try await harness.finish()
        } catch {
            deliveryHeld.retire()
            await delivery?.value
            try? await harness.finish()
            throw error
        }
    }
}
