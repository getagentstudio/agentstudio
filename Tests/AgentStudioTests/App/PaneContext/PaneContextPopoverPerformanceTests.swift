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
        "S6 an unchanged minute tick has one projection/publication, no TextKit layout or SQL, and bounded height writes",
        arguments: [false, true]
    )
    func unchangedMinuteTickHasOneProjectionAndNoTextLayout(finishOpeningBeforeNextWidth: Bool) async throws {
        let trace = PaneContextPopoverTraceFixture()
        let layouts = PaneContextBodyLayoutRecorder()
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
            let host = makeHost(
                fixture: fixture, trace: trace, clock: clock, time: time, bridge: bridge,
                layouts: layouts, finishOpeningBeforeNextWidth: finishOpeningBeforeNextWidth,
                onHeightWrite: { writes.append($0) })
            mounted = host
            try await host.open()
            #expect(host.interactions.selectedFilter == 15, "The mixed 13-body proof opens all message types")
            try await finishOpeningLayouts(host)
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
            print("POPOVER_OPENING_HEIGHTS", writes.map { "\($0.region)=\($0.height)" })
            let openingWrites = writes.count
            let openingRecords = try await trace.records()
            let handle = try #require(host.handle)
            let openingLayouts = layouts.snapshot
            openingLayouts.assertExactlyOnce()
            #expect(host.value?.bodyMeasurements.count == 13, "All retained bodies need their final native geometry")
            #expect(Set(openingLayouts.completed.map(\.body)) == Set(detail.messages.map(\.body)))
            assertOpeningAccounting(
                openingRecords, bridge: bridge, handle: handle,
                requestedLayoutCount: openingLayouts.distinctRequests.count)
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
            let minuteRecords = Array(try await trace.records().dropFirst(openingRecords.count))
            for (stage, expected) in [
                ("projection", 1), ("publication", 1), ("family_admission", 1),
                ("input_publication", 0), ("text_layout", 0),
            ] {
                #expect(
                    PaneContextPopoverTraceFixture.count(stage, in: minuteRecords) == expected,
                    "Unchanged body/width/font minute work regressed at \(stage)")
            }
            try await host.close()
            mounted = nil
            #expect(writes.count <= 6, "Height writes remain bounded through actual native retirement and owner drain")
            let records = try await trace.records()
            for (stage, expected) in [
                ("admission", 2), ("execution", 2), ("storage_read", 1), ("wake", 1),
                ("empty_wake", 0), ("retired", 1), ("equal", 0),
            ] { #expect(PaneContextPopoverTraceFixture.count(stage, in: records) == expected) }
            #expect(
                layouts.snapshot.completed.count == openingLayouts.completed.count,
                "The unchanged tick and native retirement must add no TextKit work")
            layouts.snapshot.assertExactlyOnce()
            #expect(
                layouts.snapshot.distinctRequests.count == openingLayouts.distinctRequests.count,
                "The unchanged tick and retirement must request no new body/width/font keys")
            try assertSynchronousSpansAndSafety(
                records, pane: fixture.ownerId, openingLayoutCount: openingLayouts.distinctRequests.count)
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

    private func finishOpeningLayouts(_ host: PaneContextPreparedNativeHost) async throws {
        try await host.bodyLayoutsPrepared()
        let handle = try #require(host.handle)
        // Applying the prepared body frame can announce the scroller's narrower geometry.
        // Join those actual producers and require their owner's closing facts before the tick.
        let appliedFrameInputs = host.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
        for producer in appliedFrameInputs { await producer.value }
        for operation in host.bridge.receivedInputs {
            try #require(
                host.bridge.didFinish(.input(operation)), "Opening geometry producer ended without inputFinished")
        }
    }

    private func assertOpeningAccounting(
        _ records: [[String: Any]], bridge: PopoverOwnerFactBridge, handle: PaneContextPopoverConsumerHandle,
        requestedLayoutCount: Int
    ) {
        let count = { (stage: String) in PaneContextPopoverTraceFixture.count(stage, in: records) }
        #expect(
            count("text_layout") == requestedLayoutCount,
            "Opening TextKit work must equal the distinct requested body/width/font keys")
        let facts = bridge.observations
        let execution = PaneContextPopoverOwnerScope.execution(handle.key, handle.opening.initialExecution.id)
        #expect(facts.filter { $0.scope == execution && $0.fact == .admitted(.opening) }.count == 1)
        #expect(facts.filter { $0.scope == execution && $0.fact == .finished(.published) }.count == 1)
        let inputPublications = facts.filter {
            if case .input = $0.scope { return $0.fact == .published }
            return false
        }.count
        #expect(
            count("input_publication") == inputPublications,
            "Every input publication must have its correlated owner outcome")
        for operation in bridge.receivedInputs {
            #expect(bridge.didFinish(.input(operation)), "Opening input producer must finish before the minute phase")
        }
        let canonicalPublications = count("publication")
        let geometryBeforeFinish = facts.prefix { !($0.scope == execution && $0.fact == .finished(.published)) }
            .filter {
                if case .input = $0.scope { return $0.fact == .observed }
                return false
            }.count
        #expect(canonicalPublications >= 1)
        #expect(
            canonicalPublications <= 1 + geometryBeforeFinish,
            "Only a distinct first-width geometry revision can retry the canonical projection")
        let completed =
            canonicalPublications + inputPublications + count("validation_publication")
            + count("equal") + count("superseded") + count("cancelled")
        #expect(count("family_admission") == completed, "Every admitted opening attempt has an accounted outcome")
        #expect(count("projection") <= count("family_admission"), "Superseded pending admissions may skip worker work")
        print(
            "POPOVER_OPENING_ACCOUNT", "projection", count("projection"), "canonicalPublication", canonicalPublications,
            "inputPublication", inputPublications, "familyAdmission", count("family_admission"),
            "superseded", count("superseded"), "geometryBeforeFinish", geometryBeforeFinish,
            "textLayout", count("text_layout"))
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
        layouts: PaneContextBodyLayoutRecorder? = nil, finishOpeningBeforeNextWidth: Bool = false,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil
    ) -> PaneContextPreparedNativeHost {
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        var owners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        owners.performanceTraceRecorder = trace.recorder
        if let layouts { owners.bodyLayoutObserver = layouts.observe }
        let host = PaneContextPreparedNativeHost(
            paneId: fixture.ownerId, sourceOwners: owners,
            entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
            clock: clock, wallNow: { time.now }, bridge: bridge, location: .sidebar,
            onPanelHeightWrite: onHeightWrite)
        if finishOpeningBeforeNextWidth {
            let owner = host.bindings.owner
            host.bindings.inputs.connectGeometry { key, opening, row, capture, operation in
                if capture.sequence > 1, let execution = await owner.latestExecution(for: key) {
                    await execution.task.value
                }
                await owner.receiveBodyGeometry(capture, row: row, for: key, opening: opening, operation: operation)
            }
        }
        return host
    }

    private func assertSynchronousSpansAndSafety(
        _ records: [[String: Any]], pane: PaneId, openingLayoutCount: Int
    ) throws {
        let spans = records.filter { $0["body"] as? String == "performance.pane_context.popover.main_actor_held" }
        let stages = Set(
            spans.compactMap {
                ($0["attributes"] as? [String: Any])?["agentstudio.performance.pane_context.popover.stage"] as? String
            })
        #expect(stages == ["capture", "materialize", "admit", "classify", "apply", "complete"])
        let apply = spans.filter {
            ($0["attributes"] as? [String: Any])?["agentstudio.performance.pane_context.popover.stage"] as? String
                == "apply"
        }
        #expect(!apply.isEmpty)
        #expect(
            apply.allSatisfy {
                (($0["attributes"] as? [String: Any])?[
                    "agentstudio.performance.pane_context.popover.apply_commit_elapsed_ms"] as? Double).map { $0 >= 0 }
                    == true
            })
        let workers = records.filter {
            ($0["attributes"] as? [String: Any])?["agentstudio.performance.pane_context.popover.projection_elapsed_ms"]
                != nil
        }
        #expect(workers.count == PaneContextPopoverTraceFixture.count("projection", in: records))
        #expect(
            workers.allSatisfy {
                let attributes = $0["attributes"] as? [String: Any]
                return attributes?["agentstudio.performance.pane_context.popover.off_main"] as? Bool == true
                    && (attributes?["agentstudio.performance.pane_context.popover.projection_elapsed_ms"] as? Double)
                        .map { $0 >= 0 } == true
            })
        let layouts = records.compactMap {
            ($0["attributes"] as? [String: Any])?["agentstudio.performance.pane_context.popover.text_layout.count"]
                as? Int
        }
        #expect(layouts.count == openingLayoutCount && layouts.allSatisfy { $0 == 1 })
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
