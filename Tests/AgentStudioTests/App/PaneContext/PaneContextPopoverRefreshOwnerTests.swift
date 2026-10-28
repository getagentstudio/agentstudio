import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@Suite("Off-main popover demand and deadlines")
struct PaneContextPopoverRefreshOwnerTests {
    @Test("S3 quiet ages use one useful deadline and perform no storage read at a minute tick")
    func ageOnlyTickReusesImmutableDetail() async throws {
        let harness = try makeHarness()
        do {
            let opened = try await harness.open()
            #expect(try await harness.completed(opened.initialExecution) == .published)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(60)))
            harness.clock.advance(by: .seconds(60))
            await timer.task.value
            let tick = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(tick.id != opened.initialExecution.id)
            #expect(tick.kind == .age)
            #expect(try await harness.completed(tick) == .published)
            #expect(await harness.ports.requests.count == 1)
            let shape = try #require(await harness.projections.shapes[harness.key])
            #expect(shape.messages.messageRows.first?.age.text == "1 min ago")
            let next = try await harness.timer()
            #expect(next.deadline == harness.clock.now.advanced(by: .seconds(60)))
            try await harness.finish()
            #expect(harness.clock.pendingSleepCount == 0)
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 empty demand and a closed consumer have no deadline or trailing work")
    func emptyAndClosedDemandDoNoWork() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            #expect(await harness.owner.scheduledWake() == nil)
            let quiet = await harness.bridge.facts.mark(.init(channel: .lifetime(harness.key, opened.epoch)))
            harness.clock.advance(by: .seconds(10_000))
            await harness.owner.close(harness.key)
            try await harness.bridge.facts.expectNone(
                of: isWork, "work for empty or closed demand", from: quiet,
                closedBy: { $0 == .owner(.retired) })
            #expect(await harness.ports.requests.count == 1)
            #expect(harness.clock.pendingSleepCount == 0)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 identical canonical captures do not admit a read or projection")
    func equalCanonicalCaptureIsSuppressedBeforeWork() async throws {
        let harness = try makeHarness()
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            let quiet = await harness.bridge.facts.mark(.init(channel: .lifetime(harness.key, opened.epoch)))
            harness.capture.setTitle("Owner")
            await harness.owner.receive(
                harness.capture.snapshot(for: [harness.key.paneId]), for: harness.key, opening: opened.epoch)
            let unchangedDeadline = try #require(await harness.owner.scheduledWake())
            #expect(unchangedDeadline.deadline == harness.clock.now.advanced(by: .seconds(60)))
            harness.clock.advance(by: .seconds(10))
            await harness.owner.close(harness.key)
            try await harness.bridge.facts.expectNone(
                of: isWork, "work from equal captures", from: quiet, closedBy: { $0 == .owner(.retired) })
            #expect(await harness.ports.requests.count == 1)
            #expect(harness.clock.pendingSleepCount == 0)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 A/B/A source captures coalesce to one trailing execution at the ten-second boundary")
    func burstKeepsOneTrailingRefresh() async throws {
        let harness = try makeHarness()
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            harness.capture.setTitle("B")
            await harness.owner.receive(
                harness.capture.snapshot(for: [harness.key.paneId]), for: harness.key, opening: opened.epoch)
            harness.capture.setTitle("Owner")
            await harness.owner.receive(
                harness.capture.snapshot(for: [harness.key.paneId]), for: harness.key, opening: opened.epoch)
            let timer = try await harness.timer()
            try #require(timer.deadline == harness.clock.now.advanced(by: .seconds(10)))
            harness.clock.advance(by: .seconds(10))
            await timer.task.value
            let trailing = try #require(await harness.owner.latestExecution(for: harness.key))
            try #require(trailing.id != opened.initialExecution.id)
            #expect(trailing.kind == .background)
            #expect(try await harness.completed(trailing) == .equal)
            #expect(await harness.ports.requests.count == 2)
            #expect(await harness.projections.requests.count == 2)
            let next = try await harness.timer()
            #expect(next.deadline == harness.clock.now.advanced(by: .seconds(50)))
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    @Test("S3 two hosts of one pane retain independent demand when one closes")
    func closingOneHostLeavesTheOtherClockAlive() async throws {
        let harness = try makeHarness()
        let second = PaneContextPopoverConsumerKey(
            hostId: UUIDv7.generate(), surface: .sidebarMessages, paneId: harness.key.paneId)
        do {
            let first = try await harness.open()
            _ = try await harness.completed(first.initialExecution)
            let opened = try await harness.open(second)
            _ = try await harness.completed(opened.initialExecution, for: second)
            let timer = try await harness.timer()
            await harness.owner.close(harness.key)
            try #require(await harness.owner.scheduledWake() != nil)
            harness.clock.advance(by: .seconds(60))
            await timer.task.value
            let tick = try #require(await harness.owner.latestExecution(for: second))
            try #require(tick.id != opened.initialExecution.id)
            #expect(try await harness.completed(tick, for: second) == .published)
            #expect(await harness.owner.latestExecution(for: harness.key) == nil)
            #expect(await harness.ports.requests.count == 2)
            try await harness.finish()
        } catch {
            try? await harness.finish()
            throw error
        }
    }

    private func makeHarness() throws -> PopoverOwnerHarness {
        let pane = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: pane, shape: .notice(.unread), importance: .info, sentAt: 1_800_000_000)
        return PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
    }

    private var isWork: @Sendable (PopoverOwnerProofFact) -> Bool {
        { fact in
            switch fact.ownerFact {
            case .admitted?, .readStarted?, .projected?, .published?: true
            default: false
            }
        }
    }
}
