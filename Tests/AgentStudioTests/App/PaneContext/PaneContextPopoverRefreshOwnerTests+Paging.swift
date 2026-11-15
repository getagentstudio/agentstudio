import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverRefreshOwnerTests {
    @Test("S3 distinct and duplicate pending cursors form one union retained across age and background refreshes")
    func pendingPageUnionSurvivesRefreshes() async throws {
        let pane = PaneId.generateUUIDv7()
        let rows = try (0..<3).map { number in
            try PaneContextPopoverShapingTests.message(
                paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000 - Double(number))
        }
        let pages = rows.map { PaneContextPopoverShapingTests.detail(paneId: pane, messages: [$0]) }
        let harness = PopoverOwnerHarness(detail: pages[0])
        let held = HeldStep<Void>("prior action read", cancellation: .holdThroughCancellation)
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            await harness.ports.holdRead(1, at: held)
            await harness.owner.refreshImmediately(harness.key, opening: opened.epoch)
            let action = try #require(await harness.owner.latestExecution(for: harness.key))
            _ = try await harness.arrived(at: held, producer: action)
            for page in pages { await harness.ports.enqueue(.detail(page)) }
            let first: PaneContextPopoverPageScope = .messages(source: pane, rank: 1, position: 42)
            let second: PaneContextPopoverPageScope = .messages(source: pane, rank: 1, position: 21)
            let a = await harness.owner.requestPage(first, for: harness.key, opening: opened.epoch)
            let duplicate = await harness.owner.requestPage(first, for: harness.key, opening: opened.epoch)
            let b = await harness.owner.requestPage(second, for: harness.key, opening: opened.epoch)
            held.release()
            #expect(try await harness.completed(action) == .superseded)
            let union = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(union.id != action.id)
            _ = try await harness.completed(union)
            for request in [a, duplicate, b] { try await harness.pageFinished(request, expected: .loaded) }
            #expect(
                await harness.ports.requests.map(\.page) == [.first, .first, .first, first.readPage, second.readPage])
            #expect(
                Set(await harness.projections.shapes[harness.key]?.messages.messageRows.map(\.id) ?? [])
                    == Set(rows.map { $0.id.uuid }))
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(58)))
            harness.clock.advance(by: .seconds(58))
            await timer.task.value
            let age = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(age.id != union.id)
            _ = try await harness.completed(age)
            #expect(await harness.ports.requests.count == 5)
            for page in pages { await harness.ports.enqueue(.detail(page)) }
            harness.capture.setTitle("Current title")
            await harness.owner.receive(harness.capture.snapshot(for: [pane]), for: harness.key, opening: opened.epoch)
            let changed = try await harness.timer()
            try #require(changed.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await changed.task.value
            let background = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(background.id != age.id)
            _ = try await harness.completed(background)
            #expect(await harness.ports.requests.suffix(3).map(\.page) == [.first, first.readPage, second.readPage])
            #expect(
                Set(await harness.projections.shapes[harness.key]?.messages.messageRows.map(\.id) ?? [])
                    == Set(rows.map { $0.id.uuid }))
            try await harness.finish()
        } catch {
            held.retire()
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 a background invalidation cannot defer an outstanding person page request")
    func pageRemainsImmediateWhenItsReadIsSuperseded() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        let held = HeldStep<Void>("page read across background change", cancellation: .holdThroughCancellation)
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            await harness.ports.holdRead(1, at: held)
            let request = await harness.owner.requestPage(
                .messages(source: pane, rank: 1, position: 42), for: harness.key, opening: opened.epoch)
            let first = try #require(await harness.owner.latestExecution(for: harness.key))
            _ = try await harness.arrived(at: held, producer: first)
            harness.capture.setTitle("Changed while paging")
            await harness.owner.receive(harness.capture.snapshot(for: [pane]), for: harness.key, opening: opened.epoch)
            held.release()
            #expect(try await harness.completed(first) == .superseded)
            let replacement = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(
                replacement.id != first.id, "An outstanding user page must not wait for the background interval")
            #expect(replacement.kind == .page)
            _ = try await harness.completed(replacement)
            try await harness.pageFinished(request, expected: .loaded)
            try await harness.finish()
        } catch {
            held.retire()
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 a page arriving during an age projection supersedes it and keeps its requested scope")
    func pageSupersedesHeldAgeProjection() async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        let held = HeldStep<PaneContextPopoverSnapshot>("old age projection", cancellation: .holdThroughCancellation)
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            await harness.projections.holdNext(harness.key, at: held)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(60)))
            harness.clock.advance(by: .seconds(60))
            await timer.task.value
            let age = try #require(await harness.owner.latestExecution(for: harness.key))
            _ = try await harness.arrived(at: held, producer: age)
            let scope: PaneContextPopoverPageScope = .messages(source: pane, rank: 1, position: 42)
            let request = await harness.owner.requestPage(scope, for: harness.key, opening: opened.epoch)
            held.release()
            #expect(try await harness.completed(age) == .superseded)
            let page = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(page.id != age.id)
            _ = try await harness.completed(page)
            try await harness.pageFinished(request, expected: .loaded)
            #expect(await harness.ports.requests.map(\.page) == [.first, .first, scope.readPage])
            #expect(await harness.projections.shapes[harness.key]?.messages.messageRows.first?.age.text == "1 min ago")
            try await harness.finish()
        } catch {
            held.retire()
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 compact-only demand validates canonical changes made while its token capture is held")
    func compactCaptureIsValidatedBeforeAdmission() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        let held = HeldStep<Void>("compact token capture", cancellation: .holdThroughCancellation)
        do {
            await harness.invalidations.holdNextTokenRead(at: held)
            let opened = try await harness.open(content: .toolbar)
            _ = try await harness.arrived(at: held, producer: opened.initialExecution)
            harness.capture.setTitle("Current compact title")
            held.release()
            #expect(try await harness.completed(opened.initialExecution) == .superseded)
            #expect(await harness.projections.requests.isEmpty)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await timer.task.value
            let current = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(current.id != opened.initialExecution.id)
            _ = try await harness.completed(current)
            #expect(await harness.projections.requests.last?.capture.sources[pane]?.title == "Current compact title")
            #expect(await harness.ports.requests.isEmpty)
            try await harness.finish()
        } catch {
            held.retire()
            try? await harness.finish()
            throw error
        }
    }
}
