import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Testing

@testable import AgentStudio

extension PaneContextPopoverRefreshOwnerTests {
    @Test("S4 a person result waits for its superseding immediate refresh before completion")
    func personCompletionIncludesItsCurrentRefresh() async throws {
        let pane = PaneId.generateUUIDv7()
        let notice = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info)
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [notice]))
        let held = HeldStep<Void>(
            "person refresh superseded by canonical change", cancellation: .holdThroughCancellation)
        var command: Task<PaneContextPopoverPersonCompletion, Never>?
        var monitor: Task<Void, Never>?
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            await harness.ports.configureDismissAll(.dismissed(count: 1))
            await harness.ports.holdRead(1, at: held)
            let operation = Task {
                await harness.owner.performPerson(.dismissAllNotices, for: harness.key, opening: opened.epoch)
            }
            command = operation
            monitor = Task {
                _ = await operation.value
                held.retire()
            }
            _ = try await held.firstArrival()
            await harness.ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane))
            harness.capture.setSource(
                .init(
                    structuralFacts: nil, title: "Changed during person refresh", note: nil,
                    session: nil, display: nil, activity: nil), for: pane)
            await harness.owner.receive(harness.capture.snapshot(for: [pane]), for: harness.key, opening: opened.epoch)
            held.release()
            let result = await operation.value
            #expect(result.resolution == .dismissAll(.dismissed(count: 1)))
            #expect(await harness.ports.dismissAllCalls.count == 1)
            #expect(await harness.projections.requests.last?.actionFeedback == "Dismissed 1 notices")
            #expect(
                await harness.projections.shapes[harness.key]?.messages.messageRows.isEmpty == true,
                "Person completion returned before its current resulting detail was published")
            try await harness.finish()
            await monitor?.value
        } catch {
            held.release()
            command?.cancel()
            try? await harness.finish()
            _ = await command?.value
            await monitor?.value
            throw error
        }
    }
}
