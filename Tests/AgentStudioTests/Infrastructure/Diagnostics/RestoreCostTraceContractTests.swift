import Foundation
import Testing

@testable import AgentStudioInfrastructure

enum RestoreCostTraceTestPhase: String, CaseIterable, Sendable {
    case gathering = "performance.restore.foreground.gather"
    case scheduling = "performance.restore.foreground.schedule"
    case probing = "performance.restore.foreground.probe"
    case watching = "performance.restore.foreground.watch"
    case importing = "performance.restore.outbox.import"
    case quitForward = "performance.restore.allowance.quit_forward"
    case activationForward = "performance.restore.allowance.activation_forward"
    case mountApply = "performance.restore.allowance.mount_apply"
    case resumedStartEnd = "performance.restore.allowance.resumed_start_end"
    case deciding = "performance.restore.resume.decide"
}

extension AgentStudioPerformanceTraceRecorderTests {
    @Test(
        "each restore phase records its fixed event through recordDuration",
        arguments: RestoreCostTraceTestPhase.allCases)
    func restorePhaseUsesDurationRecorder(phase: RestoreCostTraceTestPhase) async throws {
        let event = try #require(AgentStudioPerformanceTraceRecorder.Event(rawValue: phase.rawValue))
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "restore-cost-trace-\(UUIDv7.generate().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": directory.path,
                "AGENTSTUDIO_TRACE_NAME": "restore-cost-contract", "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]), processIdentifier: 909, timeUnixNano: { 117 })
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
        recorder.recordRestorePhaseDuration(
            event, duration: .milliseconds(2), executedOnMainThread: phase.rawValue.contains(".allowance."))
        try await recorder.drain()
        let output = try #require(runtime.outputFileURL)
        let contents = try String(contentsOf: output, encoding: .utf8)
        #expect(contents.contains("\"body\":\"\(phase.rawValue)\""))
        #expect(contents.contains("\"agentstudio.performance.elapsed_ms\":2"))
        #expect(contents.contains("\"agentstudio.performance.restore.execution.count\":1"))
        let expectedMainCount = phase.rawValue.contains(".allowance.") ? 1 : 0
        let expectedMainMilliseconds = expectedMainCount == 1 ? 2 : 0
        #expect(
            contents.contains("\"agentstudio.performance.restore.main_thread.execution.count\":\(expectedMainCount)"))
        #expect(
            contents.contains("\"agentstudio.performance.restore.main_thread.elapsed_ms\":\(expectedMainMilliseconds)"))
    }
}

extension AgentStudioOTLPTraceProjectionTests {
    @Test(
        "restore projection preserves log attributes and admits only classified numeric measurements",
        arguments: RestoreCostTraceTestPhase.allCases)
    func restorePhaseProjectionPreservesAttributesAndMeasuresScalars(phase: RestoreCostTraceTestPhase) throws {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 90, severityText: .info, body: phase.rawValue,
            traceID: nil, spanID: nil, parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio", "dev.runtime.flavor": "debug",
                "agent.proof.marker": "restore-cost-contract", "agent.proof.launch": "restore-cost-launch",
            ],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(2),
                "agentstudio.performance.restore.execution.count": .int(1),
                "agentstudio.performance.restore.main_thread.execution.count": .int(1),
                "agentstudio.performance.restore.main_thread.elapsed_ms": .double(0.5),
                "agentstudio.performance.restore.pane_id": .string("019be3be-7c00-7000-8000-000000000099"),
                "agentstudio.performance.restore.argv": .string("claude --resume private-session"),
                "agentstudio.performance.restore.prompt": .string("private restore prompt"),
                "agentstudio.performance.restore.raw_path": .string("/private/restore-store"),
                // Synthetic log-only identities and flags must never become metrics.
                "agentstudio.performance.restore.generation": .int(7),
                "agentstudio.performance.restore.is_restoring": .bool(true),
            ])
        let projection = AgentStudioOTLPTraceProjection.project(record)
        #expect(projection.body == phase.rawValue)
        #expect(projection.resource["agent.proof.marker"] == "restore-cost-contract")
        #expect(projection.resource["agent.proof.launch"] == "restore-cost-launch")
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(2))
        #expect(projection.attributes["agentstudio.performance.restore.execution.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.restore.main_thread.execution.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.restore.main_thread.elapsed_ms"] == .double(0.5))
        for (key, value) in record.attributes {
            #expect(projection.attributes[key] == value)
        }
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))
        #expect(metricEvent.elapsedMilliseconds == 2)
        #expect(metricEvent.measurements.count == 4)
        #expect(
            Set(metricEvent.samples.map(\.label)) == [
                "agentstudio_performance_restore_execution_count",
                "agentstudio_performance_restore_main_thread_execution_count",
                "agentstudio_performance_restore_main_thread_elapsed_ms",
            ])
    }
}

extension AgentStudioPerformanceTraceRecorderTests {
    @Test("synchronous restore slices preserve values and measure the throwing exit too")
    func restoreSliceMeasuresActualSynchronousWorkAndFailure() async throws {
        struct ExpectedFailure: Error {}
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "restore-slice-\(UUIDv7.generate().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentStudioTraceRuntime(
            configuration: .from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": directory.path,
                "AGENTSTUDIO_TRACE_NAME": "restore-slice", "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]))
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
        let observed = AgentStudioPerformanceTraceRecorder.measureRestoreSlice(.restoreOutboxImport, recorder: recorder)
        {
            (value: 42, onMainThread: Thread.isMainThread)
        }
        do {
            try AgentStudioPerformanceTraceRecorder.measureRestoreSlice(.restoreOutboxImport, recorder: recorder) {
                throw ExpectedFailure()
            }
            Issue.record("the measured closure must preserve the error")
        } catch is ExpectedFailure {}
        try await recorder.drain()
        let output = try #require(runtime.outputFileURL)
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").filter {
            $0.contains("\"body\":\"performance.restore.outbox.import\"")
        }
        #expect(observed.value == 42)
        #expect(lines.count == 2)
        for line in lines {
            #expect(line.contains("\"agentstudio.performance.restore.execution.count\":1"))
            #expect(
                line.contains(
                    "\"agentstudio.performance.restore.main_thread.execution.count\":\(observed.onMainThread ? 1 : 0)"))
            #expect(line.contains("\"agentstudio.performance.elapsed_ms\":"))
            #expect(line.contains("\"agentstudio.performance.restore.main_thread.elapsed_ms\":"))
        }

    }
}
