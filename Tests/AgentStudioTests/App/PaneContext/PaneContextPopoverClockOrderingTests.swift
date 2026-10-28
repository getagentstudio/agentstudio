import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSharedComponents

/// Calibration stays on the mounted product path; G11/G12 separately cover the full age tables.
@MainActor
@Suite("Agent Line native label application ordering", .serialized)
struct PaneContextPopoverClockOrderingTests {
    @Test("The actual Agent Line has no container receipt that can stand for its dated leaf")
    func parentApplicationCannotStandForTheDatedLabel() async throws {
        let (fixture, host) = try await makeMountedLine()
        do {
            #expect(!hasParentReceipt(in: host.native.roots))
            try await host.advance(by: .seconds(60), registeredAt: host.clock.now.advanced(by: .seconds(60)))
            try host.appliedAgentLine(summary: "The dated line", age: "1 min ago")
            #expect(
                !hasParentReceipt(in: host.native.roots),
                "Only the real dated AX leaf may acknowledge Agent Line application")
            try await host.close()
            try await fixture.close()
        } catch {
            try? await host.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("Retiring the actual dated AX leaf rejects its cached age application")
    func nativeLabelRetirementEndsTheAgeWait() async throws {
        let (fixture, host) = try await makeMountedLine()
        do {
            let label = try #require(
                host.native.find(AgentLinePopover.datedLabelIdentifier) as? AccessibilityLabelBridgeView)
            label.retireLabelApplication()
            #expect(throws: (any Error).self) { try host.appliedAgentLine(summary: "The dated line", age: "Now") }
            try await host.close()
            try await fixture.close()
        } catch {
            try? await host.close()
            try? await fixture.close()
            throw error
        }
    }

    private func makeMountedLine() async throws -> (CompositionFactoryFixture, PaneContextPreparedNativeHost) {
        let fixture = try await CompositionFactoryFixture.make()
        var host: PaneContextPreparedNativeHost?
        do {
            let service = fixture.composition.paneContextService
            let writer = AgentMessageSender.pane(fixture.ownerId)
            guard
                case .claimed(let epoch) = await service.claimEpoch(
                    .init(
                        paneId: fixture.ownerId,
                        writer: writer, stream: .line, claimId: UUIDv7.generate()))
            else { throw FixtureFailure.noLine }
            try #require(
                await service.setLine(
                    .init(
                        paneId: fixture.ownerId, writer: writer,
                        line: .init(summary: "The dated line", refs: []), writeNumber: .init(epoch: epoch, counter: 1)))
                    == .applied)
            guard case .detail(let detail) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first)),
                let line = detail.agentLine
            else { throw FixtureFailure.noLine }
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let mounted = PaneContextPreparedNativeHost(
                fixture: fixture, entry: .agentLine(.agent(line, now: fixture.now)),
                clock: clock, wallNow: { time.now }, bridge: bridge)
            host = mounted
            try await mounted.open()
            try mounted.appliedAgentLine(summary: "The dated line", age: "Now")
            return (fixture, mounted)
        } catch {
            try? await host?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func hasParentReceipt(in roots: [NSView]) -> Bool {
        for root in roots where hasParentReceipt(in: root) { return true }
        return false
    }
    private func hasParentReceipt(in view: NSView) -> Bool {
        if view is NativePresentationApplicationView<PaneContextPopoverApplication> { return true }
        for child in view.subviews where hasParentReceipt(in: child) { return true }
        return false
    }
    private enum FixtureFailure: Error { case noLine }
}
