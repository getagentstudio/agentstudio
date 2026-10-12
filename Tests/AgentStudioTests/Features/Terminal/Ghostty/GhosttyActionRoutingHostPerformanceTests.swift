import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal

@MainActor
@Suite("Exact callback host performance records", .serialized)
struct GhosttyActionRoutingHostPerformanceTests {
    @Test("exact title barrier and ordered command preserve their proof records", arguments: [true, false])
    func exactBarrierPreservesProofRecords(registerRuntime: Bool) async throws {
        let sink = ExactCallbackPerformanceTraceSink()
        let runtime = makeTraceRuntime(sink: sink)
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
        _ = recorder.beginSidebarPerformanceWorkloadProof()
        var configuration = GhosttyActionRouterTestFixtureConfiguration(registerRuntime: registerRuntime)
        configuration.performanceTraceRecorder = recorder

        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            let barrier = TerminalPrecedingTitleBarrier(
                metadata: .init(runtimeTitle: .titleChanged("Before command"), surfaceTitle: "Before command"),
                metrics: .init(offeredCount: 2, replacedCount: 1, scheduledDrainCount: 1),
                firstOfferedAtNanoseconds: .max
            )
            let result = await fixture.handler.host.applyExactFactOrControl(
                precedingTitle: barrier, actionTag: GhosttyActionTag.commandFinished.rawValue,
                payload: .commandFinished(exitCode: 0, duration: 42, sourceInstant: ContinuousClock.now),
                surfaceID: fixture.surfaceID, viewObjectID: fixture.surfaceViewObjectID,
                accumulator: fixture.handler.localActionAccumulator
            )
            #expect(result == (registerRuntime ? .applied : .dropped(.runtimeNotFound)))
            try await recorder.drain()
            let records = await sink.recordedRecords()
            let drain = try #require(records.first { $0.body == "performance.terminal.accumulator_drain" })
            #expect(
                drain.attributes["agentstudio.performance.terminal.accumulator.drain.class"] == .string("exact_barrier")
            )
            #expect(
                drain.attributes["agentstudio.performance.terminal.accumulator.apply.outcome"]
                    == .string(registerRuntime ? "changed" : "equal"))
            #expect(drain.attributes["agentstudio.performance.terminal.accumulator.offered.count"] == .int(2))
            #expect(drain.attributes["agentstudio.performance.terminal.accumulator.replaced.count"] == .int(1))
            #expect(drain.attributes["agentstudio.performance.terminal.accumulator.mainactor_task.count"] == .int(0))
            #expect(drain.attributes["agentstudio.performance.elapsed_ms"] == .double(0))
            #expect(recorder.sidebarPerformanceTerminalWorkloadSnapshot().orderedCommandCount == 1)
            let ordered = try #require(
                records.first {
                    $0.attributes["agentstudio.performance.sidebar.proof.workload.kind"] == .string("ordered_command")
                })
            #expect(ordered.attributes["agentstudio.performance.sidebar.proof.ordered_command.count"] == .int(1))
        }
    }

    @Test("an already applied barrier remains observable when ordered control retires its lifetime")
    func appliedBarrierRecordsAfterLifetimeRetiresDuringControl() async throws {
        let sink = ExactCallbackPerformanceTraceSink()
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: makeTraceRuntime(sink: sink))
        var invalidateLifetime: @MainActor () -> Void = {}
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.performanceTraceRecorder = recorder
        configuration.activityInputObserved = { _ in invalidateLifetime() }
        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            invalidateLifetime = { fixture.routingLookup.mapSurface(nil, for: fixture.surfaceViewObjectID) }
            defer { invalidateLifetime = {} }
            let barrier = TerminalPrecedingTitleBarrier(
                metadata: .init(runtimeTitle: .titleChanged("Accepted before retirement"), surfaceTitle: nil),
                metrics: .init(offeredCount: 1, scheduledDrainCount: 1), firstOfferedAtNanoseconds: .max)
            let result = await fixture.handler.host.applyExactFactOrControl(
                precedingTitle: barrier, actionTag: GhosttyActionTag.commandFinished.rawValue,
                payload: .commandFinished(exitCode: 0, duration: 42, sourceInstant: ContinuousClock.now),
                surfaceID: fixture.surfaceID, viewObjectID: fixture.surfaceViewObjectID,
                accumulator: fixture.handler.localActionAccumulator)
            #expect(result == .dropped(.staleSurface))
            try await recorder.drain()
            let records = await sink.recordedRecords()
            let drain = try #require(records.first { $0.body == "performance.terminal.accumulator_drain" })
            #expect(
                drain.attributes["agentstudio.performance.terminal.accumulator.drain.class"] == .string("exact_barrier")
            )
            #expect(
                drain.attributes["agentstudio.performance.terminal.accumulator.apply.outcome"] == .string("changed"))
            #expect(recorder.sidebarPerformanceTerminalWorkloadSnapshot().orderedCommandCount == 1)
        }
    }

    @Test("an exact command without preceding title emits no barrier drain")
    func commandWithoutTitleDoesNotInventBarrierDrain() async throws {
        let sink = ExactCallbackPerformanceTraceSink()
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: makeTraceRuntime(sink: sink))
        var configuration = GhosttyActionRouterTestFixtureConfiguration()
        configuration.performanceTraceRecorder = recorder
        try await withGhosttyActionRouterTestFixture(configuration: configuration) { fixture in
            _ = await fixture.handler.host.applyExactFactOrControl(
                precedingTitle: nil, actionTag: GhosttyActionTag.commandFinished.rawValue,
                payload: .commandFinished(exitCode: 0, duration: 42, sourceInstant: ContinuousClock.now),
                surfaceID: fixture.surfaceID, viewObjectID: fixture.surfaceViewObjectID,
                accumulator: fixture.handler.localActionAccumulator
            )
            try await recorder.drain()
            let records = await sink.recordedRecords()
            #expect(!records.contains { $0.body == "performance.terminal.accumulator_drain" })
            #expect(recorder.sidebarPerformanceTerminalWorkloadSnapshot().orderedCommandCount == 1)
        }
    }

    private func makeTraceRuntime(sink: ExactCallbackPerformanceTraceSink) -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": "/tmp/exact-callback-performance",
                "AGENTSTUDIO_TRACE_NAME": "exact-callback", "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 927,
            sinkFactory: AgentStudioTraceSinkFactory(makeJSONLSink: { _ in sink }, makeOTLPSink: { _ in sink }),
            timeUnixNano: { 121 }
        )
    }
}

private actor ExactCallbackPerformanceTraceSink: AgentStudioTraceSink {
    private var records: [AgentStudioTraceRecord] = []
    func record(_ record: AgentStudioTraceRecord) { records.append(record) }
    func flush() {}
    func shutdown() {}
    func diagnostics() -> AgentStudioTraceWriterDiagnostics { .empty }
    func recordedRecords() -> [AgentStudioTraceRecord] { records }
}
