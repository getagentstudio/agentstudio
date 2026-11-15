import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverRefreshOwnerTests {
    @Test("S3 an age-only tick preserves failed-refresh feedback alongside retained rows")
    func retainedFailureSurvivesAgeOnlyTick() async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            await harness.ports.enqueue(.unavailable(.databaseUnavailable))
            await harness.owner.refreshImmediately(harness.key, opening: opened.epoch)
            let failed = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(failed.id != opened.initialExecution.id)
            _ = try await harness.completed(failed)
            #expect(await harness.projections.failures[harness.key] == .databaseUnavailable)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(60)))
            harness.clock.advance(by: .seconds(60))
            await timer.task.value
            let tick = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(tick.id != failed.id)
            _ = try await harness.completed(tick)
            #expect(await harness.projections.failures[harness.key] == .databaseUnavailable)
            #expect(await harness.projections.shapes[harness.key]?.messages.messageRows.first?.age.text == "1 min ago")
            #expect(await harness.ports.requests.count == 2)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 an initial error does not freeze the first-ready multiline opening width")
    func errorDoesNotChooseFirstReadyWidth() async throws {
        let pane = PaneId.generateUUIDv7()
        let message = AgentMessageDetail(
            id: .generateUUIDv7(), sourcePaneId: pane, sender: .pane(pane),
            sentAt: Date(timeIntervalSince1970: 1_800_000_000), sourceOccurredAt: nil,
            importance: .info, body: "First line\nSecond line", why: nil, actions: [], shape: .notice(.unread))
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        do {
            await harness.ports.enqueue(.unavailable(.databaseUnavailable))
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            #expect(await harness.projections.requests.last?.frozenWidth == 480)
            await harness.owner.refreshImmediately(harness.key, opening: opened.epoch)
            let ready = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(ready.id != opened.initialExecution.id)
            _ = try await harness.completed(ready)
            #expect(await harness.projections.requests.last?.frozenWidth == 560)
            await harness.ports.setDetail(PaneContextPopoverShapingTests.detail(paneId: pane))
            await harness.owner.refreshImmediately(harness.key, opening: opened.epoch)
            let shorter = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(shorter.id != ready.id)
            _ = try await harness.completed(shorter)
            #expect(await harness.projections.requests.last?.frozenWidth == 560)
            await harness.owner.close(harness.key)
            let reopened = try await harness.open()
            _ = try await harness.completed(reopened.initialExecution)
            #expect(await harness.projections.requests.last?.frozenWidth == 480)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 a final page read failure completes each requested cursor with its failure")
    func pageFailureClosesItsOwnRequests() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            await harness.ports.enqueue(.unavailable(.databaseUnavailable))
            let request = await harness.owner.requestPage(
                .messages(source: pane, rank: 1, position: 42), for: harness.key, opening: opened.epoch)
            let page = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(page.id != opened.initialExecution.id)
            _ = try await harness.completed(page)
            try await harness.pageFinished(request, expected: .unavailable(.databaseUnavailable))
            #expect(await harness.owner.scheduledWake() == nil)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }
}
