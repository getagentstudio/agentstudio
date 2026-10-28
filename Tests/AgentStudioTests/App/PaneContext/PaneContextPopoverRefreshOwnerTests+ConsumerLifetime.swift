import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverRefreshOwnerTests {
    @Test("S4 an obsolete host close cannot retire a reopened consumer")
    func obsoleteCloseCannotRetireReopenedConsumer() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        do {
            let first = try await harness.open()
            _ = try await harness.completed(first.initialExecution)
            await harness.owner.close(harness.key, opening: first.epoch)
            let second = try await harness.open()
            _ = try await harness.completed(second.initialExecution)
            let current = try #require(await harness.owner.latestExecution(for: harness.key))
            let quiet = await harness.bridge.facts.mark(.init(channel: .lifetime(harness.key, second.epoch)))
            await harness.owner.close(harness.key, opening: first.epoch)
            #expect(await harness.owner.latestExecution(for: harness.key)?.id == current.id)
            await harness.owner.close(harness.key, opening: second.epoch)
            try await harness.bridge.facts.expectNone(
                of: { fact in if case .admitted? = fact.ownerFact { true } else { false } },
                "work caused by an old opening's close", from: quiet, closedBy: { $0 == .owner(.retired) })
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S4 a cancelled host opener creates no consumer or background task")
    func cancelledOpenerDoesNotCreateDemand() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        let held = HeldStep<Void>("host before actor open", cancellation: .holdThroughCancellation)
        let port = await harness.projections.port(for: harness.key)
        let opener = Task {
            defer { held.retire() }
            try? await held.arrive(())
            return await harness.owner.open(
                harness.key,
                demand: .init(content: .toolbar, location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
                projection: port)
        }
        do {
            try await held.firstArrival()
            opener.cancel()
            held.release()
            #expect(await opener.value == nil)
            #expect(await harness.owner.latestExecution(for: harness.key) == nil)
            #expect(await harness.ports.requests.isEmpty)
            #expect(harness.clock.pendingSleepCount == 0)
            try await harness.finish()
        } catch {
            held.retire()
            _ = await opener.value
            try? await harness.finish()
            throw error
        }
    }
}
