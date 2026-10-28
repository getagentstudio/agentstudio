import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

@Suite("Owner execution outcome correlation")
struct PaneContextPopoverCompletionAttributionTests {
    @Test("F12 reverse-order completion reads preserve both real execution outcomes")
    func reverseOrderCompletionsKeepTheirOwnOutcome() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        do {
            let executions = try await twoEqualReads(harness)
            #expect(try await harness.completed(executions.second) == .equal)
            #expect(try await harness.completed(executions.first) == .published)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("F12 an unconsumed earlier completion cannot replace the requested execution outcome")
    func unconsumedCompletionCannotReplaceTheRequestedOutcome() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        do {
            let executions = try await twoEqualReads(harness)
            #expect(try await harness.completed(executions.second) == .equal)
            #expect(await harness.projections.requests.count == 2)
            let quiet = await harness.bridge.facts.mark(
                .init(channel: .lifetime(harness.key, executions.second.opening)))
            await harness.owner.close(harness.key)
            try await harness.bridge.facts.expectNone(
                of: { if case .admitted? = $0.ownerFact { true } else { false } },
                "work after acknowledging both completed executions", from: quiet,
                closedBy: { $0 == .owner(.retired) })
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("F12 lifetime negatives still reject a real new owner execution after duplicate acknowledgement")
    func lifetimeNegativeStillSeesActualWork() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        do {
            let first = try await harness.open()
            _ = try await harness.completed(first.initialExecution)
            let quiet = await harness.bridge.facts.mark(
                .init(channel: .lifetime(harness.key, first.epoch)))
            await harness.owner.refreshImmediately(harness.key, opening: first.epoch)
            let next = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(next.id != first.initialExecution.id)
            await next.task.value
            await harness.owner.close(harness.key)
            await #expect(throws: UnexpectedFact.self) {
                try await harness.bridge.facts.expectNone(
                    of: { if case .admitted? = $0.ownerFact { true } else { false } },
                    "a deliberately requested real execution", from: quiet,
                    closedBy: { $0 == .owner(.retired) })
            }
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    private func twoEqualReads(_ harness: PopoverOwnerHarness) async throws
        -> (first: PaneContextPopoverExecution, second: PaneContextPopoverExecution)
    {
        let first = try await harness.open()
        await first.initialExecution.task.value
        await harness.owner.refreshImmediately(harness.key, opening: first.epoch)
        let second = try #require(await harness.owner.latestExecution(for: harness.key))
        try #require(first.initialExecution.id != second.id)
        await second.task.value
        return (first.initialExecution, second)
    }
}
