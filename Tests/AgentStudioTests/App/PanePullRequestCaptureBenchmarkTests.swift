import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("Pane PR capture: sized-state performance receipt", .serialized)
struct PanePullRequestCaptureBenchmarkTests {
    @Test("Capture and equality span covers 60 panes, 120 worktrees and 60 PR facts")
    func sizedCaptureReceipt() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let sink = PullRequestCaptureTraceSink()
            let runtime = AgentStudioTraceRuntime(
                configuration: .from(environment: [
                    "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_TAGS": "performance",
                    "AGENTSTUDIO_TRACE_DIR": FileManager.default.temporaryDirectory.path,
                    "AGENTSTUDIO_TRACE_NAME": "pr-context-capture",
                ]),
                sinkFactory: .init(makeJSONLSink: { _ in sink }, makeOTLPSink: { _ in sink }),
                timeUnixNano: { 120 })
            let recorder = AgentStudioPerformanceTraceRecorder(
                traceRuntime: runtime, processMemorySampleWait: { false })
            let fixture = makeWorkspaceSurfaceCoordinatorViewFactoryHarness(
                paneEventBus: EventBus<RuntimeEnvelope>(), performanceTraceRecorder: recorder)
            try seedPanePullRequestCaptureState(fixture)
            var previous: PanePullRequestContextSnapshot?
            let began = ContinuousClock.now
            for _ in 0..<300 {
                previous = fixture.coordinator.capturePanePullRequestContext(previous: previous).snapshot
            }
            let elapsed = AgentStudioPerformanceTraceRecorder.milliseconds(
                from: began.duration(to: ContinuousClock.now))
            await fixture.coordinator.shutdown()
            try await recorder.drain()
            let durations = await sink.captureDurations()
            #expect(durations.count == 300)
            #expect(previous?.paneFactsByPaneId.count == 60)
            #expect(previous?.enrichmentBranchByWorktreeId.count == 120)
            #expect(previous?.pullRequestURLByBranchKey.count == 60)
            let p50 = try #require(durations.dropFirst(durations.count / 2).first)
            let p95 = try #require(durations.dropFirst(durations.count * 95 / 100).first)
            print(
                "PR_CAPTURE_RECEIPT samples=\(durations.count) panes=60 worktrees=120 pr_facts=60 p50_ms=\(p50) p95_ms=\(p95) driven_fires_per_second=\(Double(durations.count) * 1000 / elapsed)"
            )
            // Timing is a delivery measurement, never this test's correctness verdict.
        }
    }
}

private actor PullRequestCaptureTraceSink: AgentStudioTraceSink {
    private var records: [AgentStudioTraceRecord] = []
    func record(_ record: AgentStudioTraceRecord) { records.append(record) }
    func flush() {}
    func shutdown() {}
    func diagnostics() -> AgentStudioTraceWriterDiagnostics { .empty }
    func captureDurations() -> [Double] {
        records.filter { $0.body == "performance.pane_context.pull_request_capture" }.compactMap { record in
            if case .double(let value)? = record.attributes["agentstudio.performance.elapsed_ms"] { return value }
            return nil
        }.sorted()
    }
}
