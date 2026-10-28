import AgentStudioCore
import AgentStudioInfrastructure
import Testing

@testable import AgentStudio

extension PaneContextPopoverRefreshOwnerTests {
    enum PageCompletion: Sendable, CaseIterable { case loaded, unavailable, paneGone, removedSource, closed }

    @Test(
        "S4 awaited page actions return their own terminal result on every owner exit",
        arguments: PageCompletion.allCases)
    func awaitedPageReturnsTerminalResult(_ scenario: PageCompletion) async throws {
        let pane = PaneId.generateUUIDv7()
        let initial = PaneContextPopoverShapingTests.detail(paneId: pane)
        let harness = PopoverOwnerHarness(detail: initial)
        do {
            let opening = try await harness.open()
            #expect(try await harness.completed(opening.initialExecution) == .published)
            let scope: PaneContextPopoverPageScope
            let expected: PaneContextPopoverOwnerFact.PageFinish
            switch scenario {
            case .loaded:
                scope = .messages(source: pane, rank: 0, position: 10)
                expected = .loaded
            case .unavailable:
                await harness.ports.enqueue(.unavailable(.databaseUnavailable))
                scope = .messages(source: pane, rank: 0, position: 10)
                expected = .unavailable(.databaseUnavailable)
            case .paneGone:
                await harness.ports.enqueue(.paneGone)
                scope = .messages(source: pane, rank: 0, position: 10)
                expected = .paneGone
            case .removedSource:
                // The fake Core reader must honor the real service's removed-source result.
                await harness.ports.enqueue(.detail(initial))
                await harness.ports.enqueue(.sourceNotInView)
                scope = .messages(source: .generateUUIDv7(), rank: 0, position: 10)
                expected = .sourceRemoved
            case .closed:
                await harness.owner.close(harness.key, opening: opening.epoch)
                scope = .messages(source: pane, rank: 0, position: 10)
                expected = .cancelled
            }
            let result = await harness.owner.loadPage(scope, for: harness.key, opening: opening.epoch)
            #expect(result == expected, "The action caller must receive its own correlated page outcome")
            if case .loaded = scenario {
                let published = try #require(await harness.projections.requests.last)
                guard case .ready(.detail(let detail, _)) = published.state else {
                    Issue.record("Successful page completion did not publish its resulting detail")
                    throw PageProofFailure.missingPagePublication
                }
                #expect(detail.paneId == pane)
            }
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }
    private enum PageProofFailure: Error { case missingPagePublication }
}
