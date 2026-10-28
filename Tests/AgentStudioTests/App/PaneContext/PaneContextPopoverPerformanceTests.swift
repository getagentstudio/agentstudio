import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Popover Performance Lane emitter and mounted height proof", .serialized)
struct PaneContextPopoverPerformanceTests {
    @Test(
        "S6 archived 13 retained / 12 unread Info scene crosses a mounted minute with bounded height writes and no SQL")
    func recordedInfoSceneHasBoundedMinuteHeightWrites() async throws {
        let trace = PaneContextPopoverTraceFixture()
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let initial = try await PaneContextF10Scene.install(in: fixture)
            let service = fixture.composition.paneContextService
            guard case .detail(let detail) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else { throw PerformanceProofFailure.missingDetail }
            #expect(detail.messages.count == 13)
            #expect(detail.messages.filter { if case .notice(.unread) = $0.shape { true } else { false } }.count == 11)
            #expect(
                detail.messages.filter { if case .ask(_, _, _, .open) = $0.shape { true } else { false } }.count == 1)
            #expect(detail.messages.first { $0.importance == .failure }?.body.split(separator: "\n").count == 33)
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            var writes: [PaneContextPopoverHeightWrite] = []
            let host = makeHost(fixture: fixture, trace: trace, clock: clock, time: time, bridge: bridge) {
                writes.append($0)
            }
            mounted = host
            try await host.open()
            let row = MessageRowModel.Key(sourcePaneId: fixture.ownerId.uuid, messageId: initial.uuid)
            _ = try host.appliedMessage(
                row, expectedLabel: PaneContextF10Scene.initialNotice + " Now", age: "Now", isRead: false)
            try await host.rendered()
            let panel = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            #expect(panel.bounds.height == 480)
            #expect(panel.bounds.width == 560)
            #expect(writes.contains { $0.region == .header && $0.height > 0 })
            #expect(writes.contains { $0.region == .footer && $0.height > 0 })
            #expect(writes.contains { $0.region == .rows && $0.height > 480 })
            let openingWrites = writes.count
            fixture.statements.begin()
            try await host.advance(by: .seconds(60), registeredAt: clock.now.advanced(by: .seconds(60)))
            _ = try host.appliedMessage(
                row, expectedLabel: PaneContextF10Scene.initialNotice + " 1 min ago", age: "1 min ago", isRead: false)
            try await host.rendered()
            #expect(fixture.statements.end().isEmpty, "The real mounted minute update must perform no SQL")
            #expect(writes.count - openingWrites <= 3, "A minute label may cause at most one write per height region")
            #expect(
                writes.count <= 6,
                "One-directional initial sizing plus one minute update is bounded by the three regions")
            #expect(panel.bounds.height == 480)
            try await host.close()
            mounted = nil
            #expect(writes.count <= 6, "Height writes remain bounded through actual native retirement and owner drain")
            let records = try await trace.records()
            for (stage, expected) in [
                ("admission", 2), ("execution", 2), ("projection", 2), ("publication", 2),
                ("storage_read", 1), ("wake", 1), ("empty_wake", 0), ("input_publication", 0),
                ("family_admission", 2), ("retired", 1), ("equal", 0),
            ] { #expect(PaneContextPopoverTraceFixture.count(stage, in: records) == expected) }
            try assertSynchronousSpansAndSafety(records, pane: fixture.ownerId)
            try await fixture.close()
            try await trace.close()
        } catch {
            _ = fixture.statements.end()
            try? await mounted?.close()
            try? await fixture.close()
            try? await trace.close()
            throw error
        }
    }

    @Test("S6 empty and closed native lifetimes have no deadlines, reads, projections or publications")
    func emptyAndClosedLifetimesHaveNoWork() async throws {
        let trace = PaneContextPopoverTraceFixture()
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            // Establish the empty steady-state before measuring it: ensureOpen starts compact publication.
            let display = await fixture.composition.paneContextService.readDisplay(paneId: fixture.ownerId)
            try #require(display != nil)
            await fixture.composition.presentationLane.publishPending()
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let host = makeHost(fixture: fixture, trace: trace, clock: clock, time: time, bridge: bridge)
            mounted = host
            try await host.open()
            try await host.rendered()
            #expect(await host.bindings.owner.scheduledWakeProducer() == nil)
            #expect(clock.pendingSleepCount == 0)
            let openingRecords = try await trace.records()
            fixture.statements.begin()
            clock.advance(by: .seconds(180))
            try await host.close()
            mounted = nil
            let retiredRecords = try await trace.records()
            #expect(PaneContextPopoverTraceFixture.count("retired", in: retiredRecords) == 1)
            #expect(retiredRecords.count == openingRecords.count + 1, "Only the completed retirement barrier is new")
            clock.advance(by: .seconds(180))
            #expect(clock.pendingSleepCount == 0)
            #expect(try await trace.records().count == retiredRecords.count)
            #expect(fixture.statements.end().isEmpty)
            for stage in ["wake", "empty_wake", "input_publication"] {
                #expect(PaneContextPopoverTraceFixture.count(stage, in: retiredRecords) == 0)
            }
            #expect(PaneContextPopoverTraceFixture.count("admission", in: retiredRecords) == 1)
            #expect(PaneContextPopoverTraceFixture.count("storage_read", in: retiredRecords) == 1)
            try await fixture.close()
            try await trace.close()
        } catch {
            _ = fixture.statements.end()
            try? await mounted?.close()
            try? await fixture.close()
            try? await trace.close()
            throw error
        }
    }

    private func makeHost(
        fixture: CompositionFactoryFixture, trace: PaneContextPopoverTraceFixture, clock: TestPushClock,
        time: PaneContextTestTime, bridge: PopoverOwnerFactBridge,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil
    ) -> PaneContextPreparedNativeHost {
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        var owners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        owners.performanceTraceRecorder = trace.recorder
        return .init(
            paneId: fixture.ownerId, sourceOwners: owners, entry: .kind(.init(kind: .info, count: 10)),
            clock: clock, wallNow: { time.now }, bridge: bridge, location: .sidebar,
            onPanelHeightWrite: onHeightWrite)
    }

    private func assertSynchronousSpansAndSafety(_ records: [[String: Any]], pane: PaneId) throws {
        let spans = records.filter { $0["body"] as? String == "performance.pane_context.popover.main_actor_held" }
        let stages = Set(
            spans.compactMap {
                ($0["attributes"] as? [String: Any])?["agentstudio.performance.pane_context.popover.stage"] as? String
            })
        #expect(stages == ["capture", "materialize", "admit", "classify", "complete"])
        #expect(
            spans.allSatisfy {
                (($0["attributes"] as? [String: Any])?["agentstudio.performance.elapsed_ms"] as? Double).map { $0 >= 0 }
                    == true
            })
        let bytes = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        let serialized = try #require(String(data: bytes, encoding: .utf8))
        for privateValue in [
            pane.uuid.uuidString, PaneContextF10Scene.question, PaneContextF10Scene.initialNotice, "diagnostic 32:",
        ] {
            #expect(!serialized.contains(privateValue), "Message text and pane identity must never be recorded")
        }
    }
}

private enum PerformanceProofFailure: Error { case missingDetail }
