import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioInfrastructure

/// JSONL is the emitter test's explicit sink, never the live Performance Lane's fallback.
@MainActor
struct PaneContextPopoverTraceFixture {
    let directory: URL
    let runtime: AgentStudioTraceRuntime
    let recorder: AgentStudioPerformanceTraceRecorder

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "as-popover-trace-\(UUIDv7.generate())")
        runtime = .init(
            configuration: .from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": directory.path,
                "AGENTSTUDIO_TRACE_NAME": "popover-emitter-test", "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]), sessionID: UUIDv7.generate().uuidString, timeUnixNano: { 117 })
        recorder = .init(traceRuntime: runtime)
    }

    func records() async throws -> [[String: Any]] {
        try await recorder.flush()
        #expect(
            runtime.queueStatistics.snapshot().droppedRecordCount == 0,
            "Emitter evidence requires zero trace queue loss")
        let file = try #require(runtime.outputFileURL)
        let output = try String(contentsOf: file, encoding: .utf8)
        return try output.split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }.filter { ($0["body"] as? String)?.hasPrefix("performance.pane_context.popover") == true }
    }

    static func count(_ stage: String, in records: [[String: Any]]) -> Int {
        records.filter {
            ($0["body"] as? String) == "performance.pane_context.popover"
                && ($0["attributes"] as? [String: Any])?["agentstudio.performance.pane_context.popover.stage"]
                    as? String == stage
        }.count
    }

    func close() async throws {
        try await recorder.drain()
        let drained = runtime.queueStatistics.snapshot()
        #expect(drained.droppedRecordCount == 0)
        #expect(drained.pendingRequestCount == 0, "The actual stopped recorder must drain before evidence retirement")
        try await runtime.shutdown()
        try FileManager.default.removeItem(at: directory)
    }
}
