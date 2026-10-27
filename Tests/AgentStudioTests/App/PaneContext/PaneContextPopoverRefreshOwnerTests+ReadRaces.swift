import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

extension PaneContextPopoverRefreshOwnerTests {
    @Test("S3 a newer token supersedes a held read even before its stream event is drained")
    func tokenHandshakeRejectsDelayedNotification() async throws {
        let harness = try heldHarness()
        do {
            let opened = try await harness.open()
            try await harness.readStarted(0, producer: opened.initialExecution)
            await harness.invalidations.bump(harness.key.paneId, emit: false)
            await harness.ports.release(0)
            #expect(try await harness.completed(opened.initialExecution) == .superseded)
            #expect(await harness.projections.requests.isEmpty)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await timer.task.value
            let next = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(next.id != opened.initialExecution.id)
            #expect(try await harness.completed(next) == .published)
            #expect(await harness.ports.requests.count == 2)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 current canonical facts are revalidated after a held read before family admission")
    func delayedCanonicalNotificationCannotAdmitOldCapture() async throws {
        let harness = try heldHarness()
        do {
            let opened = try await harness.open()
            try await harness.readStarted(0, producer: opened.initialExecution)
            harness.capture.setTitle("Current canonical title")
            // The source changed, but its asynchronous notification has not reached the owner.
            await harness.ports.release(0)
            #expect(try await harness.completed(opened.initialExecution) == .superseded)
            #expect(await harness.projections.requests.isEmpty)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await timer.task.value
            let next = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(next.id != opened.initialExecution.id)
            #expect(try await harness.completed(next) == .published)
            let admitted = try #require(await harness.projections.requests.last)
            #expect(admitted.capture.sources[harness.key.paneId]?.title == "Current canonical title")
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 closing and reopening the same key gets a new opening and producer")
    func closeAndReopenCannotReuseAnOldOpening() async throws {
        let harness = try heldHarness()
        do {
            let first = try await harness.open()
            try await harness.readStarted(0, producer: first.initialExecution)
            await harness.owner.close(harness.key)
            #expect(harness.clock.pendingSleepCount == 0)
            let second = try await harness.open()
            #expect(second.epoch != first.epoch)
            #expect(second.initialExecution.id != first.initialExecution.id)
            #expect(try await harness.completed(second.initialExecution) == .published)
            let admitted = try #require(await harness.projections.requests.last)
            #expect(admitted.identity.openingEpoch == second.epoch)
            #expect(await harness.projections.requests.count == 1)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 due ages respect background spacing and large jumps produce the current age", arguments: [false, true])
    func agesRespectSpacingAndLateWake(jump: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info,
            sentAt: jump ? 1_800_000_000 : 1_799_999_945)
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        do {
            let opened = try await harness.open()
            #expect(try await harness.completed(opened.initialExecution) == .published)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(jump ? 60 : 10)))
            harness.clock.advance(by: .seconds(jump ? 3600 : 10))
            await timer.task.value
            let next = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(next.id != opened.initialExecution.id)
            #expect(try await harness.completed(next) == .published)
            let shape = try #require(await harness.projections.shapes[harness.key])
            #expect(shape.messages.messageRows.first?.age.text == (jump ? "1 hr ago" : "1 min ago"))
            #expect(await harness.ports.requests.count == 1)
            #expect(await harness.projections.requests.count == 2)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    private func heldHarness() throws -> PopoverOwnerHarness {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        return PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]), heldReads: [0])
    }
}
