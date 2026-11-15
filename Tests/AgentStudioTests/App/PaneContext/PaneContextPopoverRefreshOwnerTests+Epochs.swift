import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverRefreshOwnerTests {
    @Test("S3 replacing a service refuses its old cursor baseline before reading the new service")
    func serviceReplacementRefusesOldCursorBaseline() async throws {
        let pane = PaneId.generateUUIDv7()
        let detail = PaneContextPopoverShapingTests.detail(paneId: pane)
        let harness = PopoverOwnerHarness(detail: detail)
        let replacement = PaneContextPopoverTestPorts(detail)
        let invalidations = PopoverOwnerInvalidationPorts()
        let epoch = UUIDv7.generate()
        let held = HeldStep<Void>("old service page", cancellation: .holdThroughCancellation)
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            let a = await harness.owner.requestPage(
                .messages(source: pane, rank: 1, position: 42), for: harness.key, opening: opened.epoch)
            let loaded = try #require(await harness.owner.latestExecution(for: harness.key))
            _ = try await harness.completed(loaded)
            try await harness.pageFinished(a, expected: .loaded)
            await harness.ports.holdRead(3, at: held)
            let b = await harness.owner.requestPage(
                .messages(source: pane, rank: 1, position: 21), for: harness.key, opening: opened.epoch)
            let old = try #require(await harness.owner.latestExecution(for: harness.key))
            _ = try await harness.arrived(at: held, producer: old)
            harness.capture.setServiceEpoch(epoch)
            await harness.owner.replaceService(
                .init(epoch: epoch, reader: replacement, invalidations: invalidations, person: replacement))
            held.release()
            #expect(try await harness.completed(old) == .superseded)
            let current = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(current.id != old.id)
            _ = try await harness.completed(current)
            #expect(await replacement.requests.map(\.page) == [.first])
            #expect(await harness.projections.requests.last?.identity.serviceEpoch == epoch)
            try await harness.pageFinished(b, expected: .restartedOnRevision)
            try await harness.finish()
            await invalidations.finish()
            try await replacement.finish()
        } catch {
            held.retire()
            try? await harness.finish()
            await invalidations.finish()
            try? await replacement.finish()
            throw error
        }
    }

    @Test("S3 new service canonical captures do not inherit the retired producer's observation sequence")
    func serviceReplacementAcceptsItsOwnCaptureSequence() async throws {
        let pane = PaneId.generateUUIDv7()
        let detail = PaneContextPopoverShapingTests.detail(paneId: pane)
        let harness = PopoverOwnerHarness(detail: detail)
        let replacement = PaneContextPopoverTestPorts(detail)
        let invalidations = PopoverOwnerInvalidationPorts()
        let epoch = UUIDv7.generate()
        do {
            for number in 0..<4 { harness.capture.setTitle("Old \(number)") }
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            harness.capture.restartRegistration(serviceEpoch: epoch)
            await harness.owner.replaceService(
                .init(epoch: epoch, reader: replacement, invalidations: invalidations, person: replacement))
            let current = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(current.id != opened.initialExecution.id)
            _ = try await harness.completed(current)
            #expect(await harness.projections.requests.last?.identity.serviceEpoch == epoch)
            #expect(await harness.projections.requests.last?.capture.sources[pane]?.title == "Replacement")
            #expect(await replacement.requests.map(\.page) == [.first])
            try await harness.finish()
            await invalidations.finish()
            try await replacement.finish()
        } catch {
            try? await harness.finish()
            await invalidations.finish()
            try? await replacement.finish()
            throw error
        }
    }

    @Test("S3 a revision change during paging rejects the cursor and publishes only the fresh first page")
    func revisionChangeRestartsWithoutMixingRows() async throws {
        let pane = PaneId.generateUUIDv7()
        let old = try PaneContextPopoverShapingTests.message(paneId: pane, shape: .notice(.unread), importance: .info)
        let next = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .attention)
        let first = PaneContextPopoverShapingTests.detail(paneId: pane, messages: [old])
        let fresh = PaneContextDetail(
            paneId: pane, revision: .init(2), agentTitle: "Fresh", agentLine: nil,
            scopedSessions: [.init(sourcePaneId: pane, session: nil)], hasDismissibleNotices: true,
            messages: [next], drawerMessages: [], links: .unknown, pullRequests: .notApplicable, truncation: nil)
        let harness = PopoverOwnerHarness(detail: first)
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            for page in [first, fresh, fresh] { await harness.ports.enqueue(.detail(page)) }
            let request = await harness.owner.requestPage(
                .messages(source: pane, rank: 1, position: 42), for: harness.key, opening: opened.epoch)
            let page = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(page.id != opened.initialExecution.id)
            _ = try await harness.completed(page)
            try await harness.pageFinished(request, expected: .restartedOnRevision)
            #expect(await harness.projections.shapes[harness.key]?.revision == .init(2))
            #expect(await harness.projections.shapes[harness.key]?.messages.messageRows.map(\.id) == [next.id.uuid])
            #expect(await harness.ports.requests.count == 4)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 continuous changes have one execution per interval and keep the trailing refresh")
    func continuousChangesKeepBoundedTrailingWork() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        let held = HeldStep<Void>("first background read", cancellation: .holdThroughCancellation)
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            harness.capture.setTitle("A")
            await harness.owner.receive(harness.capture.snapshot(for: [pane]), for: harness.key, opening: opened.epoch)
            await harness.ports.holdRead(1, at: held)
            let firstTimer = try await harness.timer()
            try #require(firstTimer.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await firstTimer.task.value
            let first = try #require(await harness.owner.latestExecution(for: harness.key))
            _ = try await harness.arrived(at: held, producer: first)
            for title in ["B", "C", "B"] {
                harness.capture.setTitle(title)
                await harness.owner.receive(
                    harness.capture.snapshot(for: [pane]), for: harness.key, opening: opened.epoch)
            }
            held.release()
            #expect(try await harness.completed(first) == .superseded)
            var prior = first.id
            for expectedTitle in ["B", "D"] {
                let timer = try await harness.timer()
                try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
                harness.clock.advance(by: .seconds(10))
                await timer.task.value
                let execution = try #require(await harness.owner.latestExecution(for: harness.key))
                try #require(execution.id != prior)
                _ = try await harness.completed(execution)
                #expect(await harness.projections.requests.last?.capture.sources[pane]?.title == expectedTitle)
                prior = execution.id
                if expectedTitle == "B" {
                    for title in ["D", "E", "D"] {
                        harness.capture.setTitle(title)
                        await harness.owner.receive(
                            harness.capture.snapshot(for: [pane]), for: harness.key, opening: opened.epoch)
                    }
                }
            }
            #expect(await harness.ports.requests.count == 4)
            #expect(await harness.projections.requests.count == 3)
            #expect(await harness.owner.scheduledWake() == nil)
            try await harness.finish()
        } catch {
            held.retire()
            try? await harness.finish()
            throw error
        }
    }
}
